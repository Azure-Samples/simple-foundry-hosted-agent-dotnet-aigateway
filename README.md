# Daily Repo Digest with AI Gateway

This .NET 10 sample runs a Microsoft Agent Framework repo digest agent in Foundry Hosted Agents. Its model calls use AI Gateway, and Foundry Toolbox routes read-only GitHub MCP calls through AI Gateway.

## Prerequisites

- [.NET SDK 10.0.302+](https://dotnet.microsoft.com/download/dotnet/10.0)
- [Azure Developer CLI 1.27.0+](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [GitHub CLI](https://cli.github.com/) signed in to `github.com`
- [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) on Windows or when using the PowerShell helper scripts
- An Azure subscription with Foundry models and permissions to create resources

Install the Foundry azd extension:

```powershell
azd ext install microsoft.foundry
```

## Set up

```powershell
gh auth status --hostname github.com
azd up
dotnet restore
```

`azd up` uses your active `gh` login. You do not need to copy a GitHub token.

If GitHub CLI is not signed in:

```powershell
gh auth login --hostname github.com
```

If you have more than one GitHub account, select one without copying its token:

```powershell
$env:GITHUB_MCP_GH_USER = "your-github-login"
azd up
```

On macOS or Linux:

```bash
GITHUB_MCP_GH_USER="your-github-login" azd up
```

### GitHub credential permissions

AI Gateway stores the selected GitHub credential in the ToolServer so it can call the four allowlisted GitHub MCP tools. For least privilege, use a dedicated fine-grained personal access token with:

- Repository access limited to the repository configured by `GITHUB_REPOSITORY`.
- Read-only repository permissions for Metadata, Actions, Issues, and Pull requests.
- No organization or account permissions.

The allowlisted tools do not require repository Contents access. GitHub enables Metadata read access automatically for fine-grained tokens.

Set the token only for the provisioning command instead of saving it in this repository or the azd environment:

```powershell
$env:GH_TOKEN = "<fine-grained-token>"
azd up
Remove-Item Env:GH_TOKEN
```

```bash
GH_TOKEN="<fine-grained-token>" azd up
```

The provisioning hook verifies read access to the configured repository, pull requests, issues, and workflow runs before updating the ToolServer. It never prints the token, removes legacy token values from the azd environment, configures `failureMode: failClosed`, sends `X-MCP-Readonly: true`, and restricts the ToolServer to `search_repositories`, `list_pull_requests`, `search_issues`, and `actions_list`. Agent middleware overwrites repository arguments on every tool call so callers cannot use the stored credential against another repository. These controls restrict how the sample uses the credential, but they cannot remove permissions already granted to the token.

## Use the Gateway from the GitHub Copilot app

Configure the GitHub Copilot app custom model provider with:

- Base URL: `<AZURE_AI_GATEWAY_ENDPOINT with its trailing slash removed>/default/models/openai/v1`
- Model: the `AZURE_AI_GATEWAY_MODEL` deployment name, `gpt-latest` by default
- Custom header: `Api-Key: <AZURE_AI_GATEWAY_API_KEY>`

Pass the Gateway key through the explicit `Api-Key` custom header. Do not rely on an API key field that converts the value to `Authorization: Bearer`; the AI Gateway runtime does not accept bearer-wrapped Gateway API keys.

## Run locally

### Windows

Create `.env` from the selected azd environment and start the agent:

```powershell
pwsh ./scripts/create-dev-env.ps1
dotnet run --project agent/FoundryHostedAgent.AIGateway.csproj
```

In another terminal, request a digest:

```powershell
$body = @{
    input = "Create a concise daily repo digest for microsoft/agent-framework."
    stream = $false
} | ConvertTo-Json

Invoke-RestMethod `
    -Method Post `
    -Uri http://localhost:8088/responses `
    -ContentType "application/json" `
    -Body $body
```

Or use the console client:

```powershell
dotnet run --project chat/FoundryHostedAgent.AIGateway.Chat.csproj
```

### macOS or Linux

Create `.env` from the selected azd environment and start the agent:

```bash
./scripts/create-dev-env.sh
dotnet run --project agent/FoundryHostedAgent.AIGateway.csproj
```

In another terminal, request a digest:

```bash
curl -sS -X POST http://localhost:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"input": "Create a concise daily repo digest for microsoft/agent-framework.", "stream": false}'
```

Or use the console client:

```bash
dotnet run --project chat/FoundryHostedAgent.AIGateway.Chat.csproj
```

## Deploy

```powershell
azd up
azd ai agent invoke "Create a concise daily repo digest for microsoft/agent-framework."
```

If Azure leaves a failed AI Gateway after an activation or managed identity conflict, rerun `azd up`. The preprovision hook deletes only the terminal `Failed` AIGateway tagged for the current azd environment, purges its APIM soft-delete record, and waits for identity cleanup. `azd down` performs the same bounded purge and settle process in its postdown hook.

Run the scheduled digest immediately:

```powershell
azd ai routine dispatch daily-repo-digest
```

## Change the agent repository

```powershell
azd env set GITHUB_REPOSITORY "owner/repo"
azd provision
```

The default is `microsoft/agent-framework`. The agent enforces this setting for every GitHub tool call. The included scheduled routine keeps its explicit `microsoft/agent-framework` prompt.

## How it works

Start with [`agent/DailyRepoDigestAgent.cs`](agent/DailyRepoDigestAgent.cs). It contains the instructions, AI Gateway model configuration, and Agent Framework construction in one place, matching the role of the Python agent module.

[`agent/GitHubMcpMiddleware.cs`](agent/GitHubMcpMiddleware.cs) normalizes GitHub tool arguments before invocation and compacts results after invocation. [`agent/Program.cs`](agent/Program.cs) is the minimal API host.

The OpenAI SDK requires a credential, but AI Gateway authenticates model requests with an `Api-Key` header. `DailyRepoDigestAgent` uses the built-in `ApiKeyAuthenticationPolicy` to add that header without creating a separate application concern.

See [`docs/implementation-notes.md`](docs/implementation-notes.md) for architecture, authentication, AI Gateway contracts, security boundaries, configuration, monitoring, and deployment details.
