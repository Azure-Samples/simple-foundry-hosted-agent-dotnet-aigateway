using System.Text.Json.Nodes;
using Microsoft.Extensions.AI;
using Xunit;

using RepoDigestAgent;

namespace FoundryHostedAgent.AIGateway.Tests;

public sealed class GitHubMcpMiddlewareTests
{
    private static readonly DateTimeOffset Cutoff =
        new(2026, 7, 19, 16, 0, 0, TimeSpan.Zero);

    [Fact]
    public void NormalizesToolArguments()
    {
        var cases = new[]
        {
            (
                "github_search_repositories",
                new Dictionary<string, object?>
                {
                    ["minimal_output"] = false,
                    ["perPage"] = 100,
                    ["page"] = 8
                },
                new Dictionary<string, object?>
                {
                    ["query"] = "microsoft/agent-framework",
                    ["minimal_output"] = true,
                    ["perPage"] = 1,
                    ["page"] = 1
                }),
            (
                "github_list_pull_requests",
                new Dictionary<string, object?> { ["state"] = "open", ["page"] = 8 },
                new Dictionary<string, object?>
                {
                    ["owner"] = "microsoft",
                    ["repo"] = "agent-framework",
                    ["state"] = "all",
                    ["sort"] = "updated",
                    ["direction"] = "desc",
                    ["perPage"] = 100,
                    ["page"] = 1
                }),
            (
                "github_search_issues",
                new Dictionary<string, object?> { ["query"] = "wrong", ["page"] = 8 },
                new Dictionary<string, object?>
                {
                    ["owner"] = "microsoft",
                    ["repo"] = "agent-framework",
                    ["query"] = "is:issue updated:>=2026-07-19T16:00:00Z",
                    ["sort"] = "updated",
                    ["order"] = "desc",
                    ["page"] = 1
                })
        };

        foreach (var (toolName, arguments, expected) in cases)
        {
            GitHubMcpMiddleware.NormalizeArguments(
                toolName,
                arguments,
                "microsoft/agent-framework",
                Cutoff);
            Assert.Equal(expected, arguments);
        }
    }

    [Fact]
    public void NormalizesWorkflowArgumentsAndPreservesBranch()
    {
        var arguments = new Dictionary<string, object?>
        {
            ["method"] = "get_workflow_run",
            ["workflow_runs_filter"] = new Dictionary<string, object?> { ["branch"] = "main" }
        };

        GitHubMcpMiddleware.NormalizeArguments(
            "github_actions_list",
            arguments,
            "microsoft/agent-framework",
            Cutoff);

        Assert.Equal("list_workflow_runs", arguments["method"]);
        Assert.Equal("microsoft", arguments["owner"]);
        Assert.Equal("agent-framework", arguments["repo"]);
        Assert.Equal(100, arguments["per_page"]);
        Assert.Equal(1, arguments["page"]);
        var filter = Assert.IsType<Dictionary<string, object?>>(arguments["workflow_runs_filter"]);
        Assert.Equal("main", filter["branch"]);
        Assert.Equal("completed", filter["status"]);
    }

    [Fact]
    public void CompactsRepositoryFields()
    {
        var payload = JsonNode.Parse(
            """
            {
              "total_count": 1,
              "incomplete_results": false,
              "items": [{
                "full_name": "microsoft/agent-framework",
                "description": "Agents",
                "html_url": "https://github.com/microsoft/agent-framework",
                "stargazers_count": 100,
                "default_branch": "main",
                "owner": {"login": "microsoft"}
              }]
            }
            """)!;

        var compact = GitHubMcpMiddleware.CompactPayload(
            "github_search_repositories",
            payload,
            Cutoff);

        var item = compact["items"]![0]!.AsObject();
        Assert.Equal("microsoft/agent-framework", item["full_name"]!.GetValue<string>());
        Assert.False(item.ContainsKey("owner"));
    }

    [Fact]
    public void FiltersAndCompactsPullRequests()
    {
        var payload = JsonNode.Parse(
            """
            [
              {
                "number": 2,
                "title": "Recent",
                "state": "open",
                "updated_at": "2026-07-20T12:00:00Z",
                "html_url": "https://github.com/microsoft/agent-framework/pull/2",
                "body": "large body",
                "user": {"login": "octocat"},
                "labels": [{"name": "bug"}]
              },
              {
                "number": 1,
                "title": "Old",
                "updated_at": "2026-07-18T12:00:00Z"
              }
            ]
            """)!;

        var compact = GitHubMcpMiddleware.CompactPayload(
            "github_list_pull_requests",
            payload,
            Cutoff);

        Assert.Equal(1, compact["returned_count"]!.GetValue<int>());
        var item = compact["pull_requests"]![0]!.AsObject();
        Assert.Equal("octocat", item["author"]!.GetValue<string>());
        Assert.Equal("bug", item["labels"]![0]!.GetValue<string>());
        Assert.False(item.ContainsKey("body"));
    }

    [Fact]
    public void CompactsIssueFields()
    {
        var payload = JsonNode.Parse(
            """
            {
              "total_count": 1,
              "incomplete_results": false,
              "items": [{
                "number": 3,
                "title": "Issue",
                "state": "open",
                "updated_at": "2026-07-20T12:00:00Z",
                "body": "large body",
                "user": {"login": "octocat"},
                "labels": [{"name": "help wanted"}]
              }]
            }
            """)!;

        var compact = GitHubMcpMiddleware.CompactPayload(
            "github_search_issues",
            payload,
            Cutoff);

        var item = compact["items"]![0]!.AsObject();
        Assert.Equal("octocat", item["author"]!.GetValue<string>());
        Assert.Equal("help wanted", item["labels"]![0]!.GetValue<string>());
        Assert.False(item.ContainsKey("body"));
    }

    [Fact]
    public void KeepsOnlyRecentFailedWorkflows()
    {
        var payload = JsonNode.Parse(
            """
            {
              "workflow_runs": [
                {
                  "id": 3,
                  "name": "CI",
                  "conclusion": "failure",
                  "updated_at": "2026-07-20T12:00:00Z",
                  "html_url": "https://github.com/example/actions/runs/3",
                  "actor": {"login": "octocat"},
                  "head_commit": {"message": "large nested object"}
                },
                {
                  "id": 2,
                  "name": "CI",
                  "conclusion": "success",
                  "updated_at": "2026-07-20T12:00:00Z"
                },
                {
                  "id": 1,
                  "name": "CI",
                  "conclusion": "failure",
                  "updated_at": "2026-07-18T12:00:00Z"
                }
              ]
            }
            """)!;

        var compact = GitHubMcpMiddleware.CompactPayload(
            "github_actions_list",
            payload,
            Cutoff);

        Assert.Equal(1, compact["returned_count"]!.GetValue<int>());
        var item = compact["workflow_runs"]![0]!.AsObject();
        Assert.Equal("octocat", item["actor"]!.GetValue<string>());
        Assert.False(item.ContainsKey("head_commit"));
    }

    [Fact]
    public void PreservesNonJsonToolErrors()
    {
        const string text = "GitHub MCP returned an error";
        Assert.Equal(
            text,
            GitHubMcpMiddleware.CompactText("github_search_issues", text, Cutoff));
    }

    [Fact]
    public void PreservesTextContentMetadata()
    {
        var content = new TextContent(
            """
            {
              "total_count": 1,
              "items": [{"number": 4, "title": "Issue", "body": "large body"}]
            }
            """)
        {
            AdditionalProperties = new AdditionalPropertiesDictionary
            {
                ["_meta"] = new Dictionary<string, object?> { ["ifc"] = "public" }
            }
        };

        var compact = Assert.IsType<TextContent>(
            GitHubMcpMiddleware.CompactResult("github_search_issues", content, Cutoff));

        Assert.Same(content.AdditionalProperties, compact.AdditionalProperties);
        Assert.DoesNotContain("large body", compact.Text, StringComparison.Ordinal);
    }
}
