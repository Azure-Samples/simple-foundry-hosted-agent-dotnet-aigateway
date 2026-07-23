using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RepoDigestAgent;

internal static class GitHubMcpMiddleware
{
    private static readonly HashSet<string> GitHubMcpTools =
    [
        "github_actions_list",
        "github_list_pull_requests",
        "github_search_issues",
        "github_search_repositories"
    ];

    private static readonly JsonSerializerOptions CompactJsonOptions = new(JsonSerializerDefaults.Web);

    internal static async ValueTask<object?> InvokeAsync(
        AIAgent agent,
        FunctionInvocationContext context,
        Func<FunctionInvocationContext, CancellationToken, ValueTask<object?>> next,
        string repository,
        CancellationToken cancellationToken)
    {
        _ = agent;
        var toolName = SourceToolName(context.Function.Name);
        if (!GitHubMcpTools.Contains(toolName))
        {
            return await next(context, cancellationToken).ConfigureAwait(false);
        }

        var cutoff = DateTimeOffset.UtcNow.AddDays(-1);
        NormalizeArguments(toolName, context.Arguments, repository, cutoff);

        var result = await next(context, cancellationToken).ConfigureAwait(false);
        return CompactResult(toolName, result, cutoff);
    }

    internal static string SourceToolName(string toolName)
    {
        var separator = toolName.LastIndexOf("___", StringComparison.Ordinal);
        return separator < 0 ? toolName : toolName[(separator + 3)..];
    }

    internal static void NormalizeArguments(
        string toolName,
        IDictionary<string, object?> arguments,
        string repository,
        DateTimeOffset cutoff)
    {
        var separator = repository.IndexOf('/');
        var owner = repository[..separator];
        var name = repository[(separator + 1)..];
        if (toolName != "github_search_repositories")
        {
            arguments["owner"] = owner;
            arguments["repo"] = name;
        }

        switch (toolName)
        {
            case "github_search_repositories":
                arguments["query"] = repository;
                arguments["minimal_output"] = true;
                arguments["perPage"] = 1;
                arguments["page"] = 1;
                break;
            case "github_list_pull_requests":
                arguments["state"] = "all";
                arguments["sort"] = "updated";
                arguments["direction"] = "desc";
                arguments["perPage"] = 100;
                arguments["page"] = 1;
                break;
            case "github_search_issues":
                arguments["query"] = $"is:issue updated:>={cutoff.UtcDateTime:yyyy-MM-ddTHH:mm:ssZ}";
                arguments["sort"] = "updated";
                arguments["order"] = "desc";
                arguments["page"] = 1;
                break;
            case "github_actions_list":
                arguments.TryGetValue("workflow_runs_filter", out var workflowRunsFilter);
                var filter = ToMutableDictionary(workflowRunsFilter);
                filter["status"] = "completed";
                arguments["method"] = "list_workflow_runs";
                arguments["workflow_runs_filter"] = filter;
                arguments["per_page"] = 100;
                arguments["page"] = 1;
                break;
        }
    }

    internal static JsonObject CompactPayload(
        string toolName,
        JsonNode payload,
        DateTimeOffset cutoff) =>
        toolName switch
        {
            "github_search_repositories" => CompactSearch(
                payload,
                CompactRepository),
            "github_list_pull_requests" => CompactPullRequests(payload, cutoff),
            "github_search_issues" => CompactSearch(payload, CompactIssue),
            "github_actions_list" => CompactWorkflowRuns(payload, cutoff),
            _ => throw new ArgumentOutOfRangeException(nameof(toolName), toolName, "Unsupported GitHub MCP tool.")
        };

    internal static string CompactText(string toolName, string text, DateTimeOffset cutoff)
    {
        JsonNode? payload;
        try
        {
            payload = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return text;
        }

        if (payload is null)
        {
            return text;
        }

        try
        {
            return CompactPayload(toolName, payload, cutoff).ToJsonString(CompactJsonOptions);
        }
        catch (InvalidOperationException)
        {
            return text;
        }
    }

    internal static object? CompactResult(string toolName, object? result, DateTimeOffset cutoff) =>
        result switch
        {
            string text => CompactText(toolName, text, cutoff),
            TextContent content => new TextContent(CompactText(toolName, content.Text, cutoff))
            {
                AdditionalProperties = content.AdditionalProperties
            },
            JsonElement json => CompactJsonElement(toolName, json, cutoff),
            _ => result
        };

    private static JsonElement CompactJsonElement(
        string toolName,
        JsonElement json,
        DateTimeOffset cutoff)
    {
        var compact = CompactText(toolName, json.GetRawText(), cutoff);
        return JsonSerializer.Deserialize<JsonElement>(compact);
    }

    private static JsonObject CompactSearch(
        JsonNode payload,
        Func<JsonObject, JsonObject> compactItem)
    {
        var root = RequireObject(payload, "root");
        var items = RequireObjectArray(root["items"], "items");

        return new JsonObject
        {
            ["total_count"] = root["total_count"]?.DeepClone(),
            ["incomplete_results"] = root["incomplete_results"]?.DeepClone(),
            ["items"] = new JsonArray(items.Select(item => compactItem(item)).ToArray())
        };
    }

    private static JsonObject CompactPullRequests(JsonNode payload, DateTimeOffset cutoff)
    {
        var items = RequireObjectArray(payload, "root")
            .Where(item => IsRecent(item["updated_at"], cutoff))
            .Select(CompactPullRequest)
            .ToArray();

        return new JsonObject
        {
            ["returned_count"] = items.Length,
            ["pull_requests"] = new JsonArray(items)
        };
    }

    private static JsonObject CompactWorkflowRuns(JsonNode payload, DateTimeOffset cutoff)
    {
        var root = RequireObject(payload, "root");
        var items = RequireObjectArray(root["workflow_runs"], "workflow_runs")
            .Where(item =>
                string.Equals(item["conclusion"]?.GetValue<string>(), "failure", StringComparison.Ordinal) &&
                IsRecent(item["updated_at"] ?? item["created_at"], cutoff))
            .Select(CompactWorkflowRun)
            .ToArray();

        return new JsonObject
        {
            ["returned_count"] = items.Length,
            ["workflow_runs"] = new JsonArray(items)
        };
    }

    private static JsonObject CompactRepository(JsonObject item) =>
        SelectFields(
            item,
            "full_name",
            "description",
            "html_url",
            "language",
            "stargazers_count",
            "forks_count",
            "open_issues_count",
            "updated_at",
            "default_branch",
            "archived");

    private static JsonObject CompactPullRequest(JsonObject item)
    {
        var compact = SelectFields(
            item,
            "number",
            "title",
            "state",
            "draft",
            "merged",
            "created_at",
            "updated_at",
            "html_url");
        compact["author"] = Login(item["user"]);
        compact["labels"] = LabelNames(item["labels"]);
        return compact;
    }

    private static JsonObject CompactIssue(JsonObject item)
    {
        var compact = SelectFields(
            item,
            "number",
            "title",
            "state",
            "state_reason",
            "comments",
            "created_at",
            "updated_at",
            "closed_at",
            "html_url");
        compact["author"] = Login(item["user"]);
        compact["labels"] = LabelNames(item["labels"]);
        return compact;
    }

    private static JsonObject CompactWorkflowRun(JsonObject item)
    {
        var compact = SelectFields(
            item,
            "id",
            "name",
            "display_title",
            "event",
            "head_branch",
            "head_sha",
            "run_number",
            "run_attempt",
            "status",
            "conclusion",
            "created_at",
            "updated_at",
            "html_url");
        compact["actor"] = Login(item["actor"]);
        return compact;
    }

    private static JsonObject SelectFields(JsonObject source, params string[] fields)
    {
        var selected = new JsonObject();
        foreach (var field in fields)
        {
            if (source.TryGetPropertyValue(field, out var value))
            {
                selected[field] = value?.DeepClone();
            }
        }

        return selected;
    }

    private static string? Login(JsonNode? value) =>
        value is JsonObject user ? user["login"]?.GetValue<string>() : null;

    private static JsonArray LabelNames(JsonNode? value)
    {
        var names = new JsonArray();
        if (value is not JsonArray labels)
        {
            return names;
        }

        foreach (var label in labels.OfType<JsonObject>())
        {
            if (label["name"]?.GetValue<string>() is { } name)
            {
                names.Add(name);
            }
        }

        return names;
    }

    private static bool IsRecent(JsonNode? value, DateTimeOffset cutoff)
    {
        if (value is not JsonValue ||
            !DateTimeOffset.TryParse(value.GetValue<string>(), out var timestamp))
        {
            return true;
        }

        return timestamp >= cutoff;
    }

    private static JsonObject RequireObject(JsonNode? value, string location) =>
        value as JsonObject ??
        throw new InvalidOperationException($"Expected an object at {location}.");

    private static IReadOnlyList<JsonObject> RequireObjectArray(JsonNode? value, string location)
    {
        if (value is not JsonArray array || array.Any(item => item is not JsonObject))
        {
            throw new InvalidOperationException($"Expected a list of objects at {location}.");
        }

        return array.OfType<JsonObject>().ToArray();
    }

    private static Dictionary<string, object?> ToMutableDictionary(object? value)
    {
        if (value is IDictionary<string, object?> dictionary)
        {
            return new Dictionary<string, object?>(dictionary, StringComparer.Ordinal);
        }

        if (value is JsonElement { ValueKind: JsonValueKind.Object } json)
        {
            return json.EnumerateObject().ToDictionary(
                property => property.Name,
                property => (object?)property.Value.Clone(),
                StringComparer.Ordinal);
        }

        return new Dictionary<string, object?>(StringComparer.Ordinal);
    }
}
