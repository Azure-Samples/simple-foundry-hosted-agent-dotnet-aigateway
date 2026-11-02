using Azure.Core;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using OpenAI;
using OpenAI.Chat;
using System.ClientModel;
using System.ClientModel.Primitives;

namespace RepoDigestAgent;

internal static class DailyRepoDigestAgent
{
    internal const string AiGatewayTokenScope = "https://azure-api.net/aigateway/.default";
    private const string DefaultRepository = "microsoft/agent-framework";
    private const string DefaultGatewayModel = "gpt-latest";
    private const string DefaultToolboxName = "repo-digest-tools";
    private const int DefaultMaxOutputTokens = 2_048;
    private const string OpenAiAuthPlaceholder = "workload-identity-auth";

    internal static string ToolboxName(IConfiguration configuration) =>
        configuration["TOOLBOX_NAME"] ?? DefaultToolboxName;

    internal static DefaultAzureCredential CreateAzureCredential(IConfiguration configuration) =>
        new(new DefaultAzureCredentialOptions
        {
            ExcludeManagedIdentityCredential =
                string.IsNullOrWhiteSpace(configuration["FOUNDRY_HOSTING_ENVIRONMENT"])
        });

    internal static AIAgent Build(
        IConfiguration configuration,
        TokenCredential? credential = null)
    {
        var repository = ConfiguredRepository(configuration);
        return GatewayClient(configuration, credential)
            .AsAIAgent(new ChatClientAgentOptions
            {
                Name = "daily-repo-digest",
                Description = "Creates daily GitHub repository digests through AI Gateway.",
                ChatOptions = new ChatOptions
                {
                    Instructions = Instructions(repository),
                    MaxOutputTokens = DefaultMaxOutputTokens
                }
            })
            .AsBuilder()
            .Use((agent, context, next, cancellationToken) =>
                GitHubMcpMiddleware.InvokeAsync(
                    agent,
                    context,
                    next,
                    repository,
                    cancellationToken))
            .Build();
    }

    private static string Instructions(string repository) =>
        $$"""
        You create concise daily GitHub repository digests from live repository data.

        - Always use the GitHub MCP tools before answering a repo digest request.
        - The configured repository is `{{repository}}`. Use only this repository,
          even if the user requests another repository. The repository full name is
          already known, so do not call any repository search tool to look it up.
        - For a daily digest, call the three GitHub tools below in the first tool
          round so they run in parallel. Report total counts from the tool results,
          then highlight the most relevant items.
        - For pull requests, call aigw-github___github_list_pull_requests with state "all", sort
          "updated", direction "desc", perPage 100, and page 1. Tool middleware keeps
          only results updated in the last 24 hours and removes fields the digest does
          not use.
        - For issues, call aigw-github___github_list_issues with owner and repo as separate
          arguments. Tool middleware sets orderBy "UPDATED_AT", direction "DESC", a
          since cutoff of the last 24 hours, and perPage 100. Do not pass a query
          string or a page number. This uses the core GitHub API, not the Search API.
        - For workflows, call aigw-github___github_actions_list with method
          "list_workflow_runs" and workflow_runs_filter status "completed", per_page 100,
          and page 1. Do not use "failure" as a status. Tool middleware keeps only failed
          runs from the last 24 hours and removes fields the digest does not use.
        - Focus on what changed, what needs attention, and useful next actions.
        - Return a one-line summary, PRs updated in the last 24 hours, issues updated
          in the last 24 hours, workflow failures, and suggested next actions.
        - If a section has no items, say "None found".
        - Do not invent activity that is not in the tool result.
        """;

    private static string ConfiguredRepository(IConfiguration configuration)
    {
        var repository = configuration["GITHUB_REPOSITORY"] ?? DefaultRepository;
        var parts = repository.Split('/');
        return parts is [{ Length: > 0 }, { Length: > 0 }]
            ? repository
            : throw new InvalidOperationException(
                "Set GITHUB_REPOSITORY in owner/repository format.");
    }

    internal static ChatClient GatewayClient(
        IConfiguration configuration,
        TokenCredential? credential = null,
        PipelineTransport? transport = null)
    {
        var apiKey = configuration["AZURE_AI_GATEWAY_API_KEY"];
        var options = new OpenAIClientOptions
        {
            Endpoint = new Uri(
                $"{RequiredValue(configuration, "AZURE_AI_GATEWAY_ENDPOINT").TrimEnd('/')}/default/models/openai/v1/")
        };
        if (transport is not null)
        {
            options.Transport = transport;
        }

        options.AddPolicy(
            !string.IsNullOrWhiteSpace(apiKey)
                ? new GatewayApiKeyPolicy(apiKey)
                : new GatewayBearerTokenPolicy(credential ?? CreateAzureCredential(configuration)),
            PipelinePosition.BeforeTransport);

        return new OpenAIClient(
                new ApiKeyCredential(OpenAiAuthPlaceholder),
                options)
            .GetChatClient(configuration["AZURE_AI_GATEWAY_MODEL"] ?? DefaultGatewayModel);
    }

    private static string RequiredValue(IConfiguration configuration, string name) =>
        configuration[name] is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"Set {name}.");

    private sealed class GatewayApiKeyPolicy(string apiKey) : PipelinePolicy
    {
        public override void Process(
            PipelineMessage message,
            IReadOnlyList<PipelinePolicy> pipeline,
            int currentIndex)
        {
            ApplyHeaders(message);
            ProcessNext(message, pipeline, currentIndex);
        }

        public override ValueTask ProcessAsync(
            PipelineMessage message,
            IReadOnlyList<PipelinePolicy> pipeline,
            int currentIndex)
        {
            ApplyHeaders(message);
            return ProcessNextAsync(message, pipeline, currentIndex);
        }

        private void ApplyHeaders(PipelineMessage message)
        {
            message.Request.Headers.Remove("Authorization");
            message.Request.Headers.Set("Api-Key", apiKey);
        }
    }

    private sealed class GatewayBearerTokenPolicy(TokenCredential credential) : PipelinePolicy
    {
        private static readonly TokenRequestContext ScopeContext = new([AiGatewayTokenScope]);

        public override void Process(
            PipelineMessage message,
            IReadOnlyList<PipelinePolicy> pipeline,
            int currentIndex)
        {
            var token = credential.GetToken(ScopeContext, message.CancellationToken);
            message.Request.Headers.Set("Authorization", $"Bearer {token.Token}");
            ProcessNext(message, pipeline, currentIndex);
        }

        public override async ValueTask ProcessAsync(
            PipelineMessage message,
            IReadOnlyList<PipelinePolicy> pipeline,
            int currentIndex)
        {
            var token = await credential
                .GetTokenAsync(ScopeContext, message.CancellationToken)
                .ConfigureAwait(false);
            message.Request.Headers.Set("Authorization", $"Bearer {token.Token}");
            await ProcessNextAsync(message, pipeline, currentIndex).ConfigureAwait(false);
        }
    }
}
