using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using OpenAI;
using OpenAI.Chat;
using System.ClientModel;
using System.ClientModel.Primitives;

namespace RepoDigestAgent;

internal static class DailyRepoDigestAgent
{
    private const string DefaultRepository = "microsoft/agent-framework";
    private const string DefaultGatewayModel = "gpt-latest";
    private const string DefaultToolboxName = "repo-digest-tools";
    private const int DefaultMaxOutputTokens = 2_048;
    private const string OpenAiAuthPlaceholder = "workload-identity-auth";

    internal static string ToolboxName(IConfiguration configuration) =>
        configuration["TOOLBOX_NAME"] ?? DefaultToolboxName;

    internal static AIAgent Build(IConfiguration configuration)
    {
        var repository = ConfiguredRepository(configuration);
        return GatewayClient(configuration)
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
          even if the user requests another repository.
        - For a daily digest, call all four GitHub tools in the first tool round so they
          run in parallel. Use page 1 only and do not paginate. Report total counts from
          the tool results, then highlight the most relevant items from that first page.
        - Use aigw-github___github_search_repositories with minimal_output true and perPage 1 for
          repository summary information.
        - For pull requests, call aigw-github___github_list_pull_requests with state "all", sort
          "updated", direction "desc", perPage 100, and page 1. Tool middleware keeps
          only results updated in the last 24 hours and removes fields the digest does
          not use.
        - For issues, call aigw-github___github_search_issues with owner and repo as separate
          arguments and query `is:issue`. Set sort to "updated", order to "desc", and
          page to 1. Tool middleware adds the exact current UTC 24-hour cutoff.
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

    private static ChatClient GatewayClient(IConfiguration configuration)
    {
        var apiKey = RequiredValue(configuration, "AZURE_AI_GATEWAY_API_KEY");
        var options = new OpenAIClientOptions
        {
            Endpoint = new Uri(
                $"{RequiredValue(configuration, "AZURE_AI_GATEWAY_ENDPOINT").TrimEnd('/')}/default/models/openai/v1/")
        };

        // AI Gateway authenticates with Api-Key, while the OpenAI client requires a credential.
        options.AddPolicy(
            ApiKeyAuthenticationPolicy.CreateHeaderApiKeyPolicy(
                new ApiKeyCredential(apiKey),
                "Api-Key"),
            PipelinePosition.PerCall);

        return new OpenAIClient(
                new ApiKeyCredential(OpenAiAuthPlaceholder),
                options)
            .GetChatClient(configuration["AZURE_AI_GATEWAY_MODEL"] ?? DefaultGatewayModel);
    }

    private static string RequiredValue(IConfiguration configuration, string name) =>
        configuration[name] is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"Set {name}.");
}
