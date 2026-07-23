# Implementation notes

## Architecture

The sample has four runtime boundaries:

1. The .NET 10 ASP.NET Core process hosts one Agent Framework agent and exposes the Foundry Responses protocol at `/responses`.
2. The agent sends OpenAI-compatible chat completion requests to the AI Gateway model route at `/default/models/openai/v1/`.
3. Foundry Toolbox discovers the `repo-digest-tools` toolbox from the Foundry project and supplies its tools to the agent at request time.
4. The toolbox connection sends MCP calls to the AI Gateway GitHub ToolServer at `/default/toolservers/github/mcp`.

The hosted process does not call GitHub directly. The GitHub credential remains in the AI Gateway ToolServer configuration.

## Minimal API host

[`agent/Program.cs`](../agent/Program.cs) uses `WebApplication.CreateBuilder`, `AddFoundryResponses`, `AddFoundryToolboxes`, and `MapFoundryResponses`. The Foundry hosting package maps `/responses` and `/readiness`.

`WebApplicationBuilder.Configuration` reads the existing environment variable names and supports the standard ASP.NET Core configuration providers. `WebApplicationBuilder.Services` remains the composition root for the agent and toolbox dependencies.

The host follows the [.NET 10 Minimal API guidance](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis?view=aspnetcore-10.0) where it applies to a framework-mapped protocol. MAF owns the route handlers, response types, endpoint metadata, health checks, and streaming behavior. The application therefore does not add controllers, app-owned route groups, typed results, OpenAPI, Problem Details, authentication, HTTPS redirection, CORS, or request timeouts around those endpoints. Foundry provides authenticated HTTPS ingress, while the container listens on HTTP behind that ingress. Adding generic API middleware would change protocol errors, streaming, or readiness behavior without adding an application-owned route.

The agent is named `daily-repo-digest`. The hosted service and deployment resource are named `simple-foundry-hosted-agent-dotnet-aigateway`.

## AI Gateway model client

`DailyRepoDigestAgent` requires:

- `AZURE_AI_GATEWAY_ENDPOINT`
- `AZURE_AI_GATEWAY_API_KEY`

It defaults `AZURE_AI_GATEWAY_MODEL` to `gpt-latest`, `GITHUB_REPOSITORY` to `microsoft/agent-framework`, and `TOOLBOX_NAME` to `repo-digest-tools`.

The OpenAI SDK requires an API key credential even when a gateway uses a different header. The client therefore receives the non-secret placeholder `workload-identity-auth`. The built-in `ApiKeyAuthenticationPolicy` adds the real AI Gateway key as `Api-Key` on every request. Do not replace the placeholder with the gateway key because that would also send the secret in the OpenAI `Authorization` header.

The model route is:

```text
{AZURE_AI_GATEWAY_ENDPOINT}/default/models/openai/v1/
```

The agent limits output to 2,048 tokens. OpenAI chat completions do not store response state.

The GitHub Copilot app custom model provider uses the same base route and model deployment name. Configure its credential as an explicit `Api-Key` custom header. The AI Gateway runtime does not accept a Gateway key wrapped as `Authorization: Bearer`.

## Foundry Toolbox authentication

The hosted runtime injects `FOUNDRY_PROJECT_ENDPOINT`. `AddFoundryToolboxes` derives the toolbox MCP proxy endpoint from that project endpoint.

`DefaultAzureCredential` excludes managed identity during local development. In Foundry hosting, `FOUNDRY_HOSTING_ENVIRONMENT` is present and managed identity is enabled. The deployed app therefore uses managed identity for Foundry Toolbox and does not require a Foundry API key.

## GitHub MCP credential and read-only guardrails

The deployment hook obtains the active GitHub CLI token without printing it or saving it to the azd environment. A dedicated fine-grained token is the safest option. Restrict it to the repository configured by `GITHUB_REPOSITORY`, grant read-only Metadata, Actions, Issues, and Pull requests permissions, and grant no organization or account permissions. Contents access is not required by the allowlisted tools.

Before updating the ToolServer, the hook validates the `owner/repository` format, then runs an **advisory, non-blocking** credential check: it warns (never fails) when the selected credential is broader than the recommended least-privilege token, and warns if a fine-grained token cannot read repository metadata, pull requests, issues, or workflow runs. This keeps the documented `gh auth status; azd up` flow working with any login while still nudging operators toward a read-only, repository-scoped token. Agent middleware overwrites repository arguments on every tool call with the configured owner and repository. The hook cannot determine whether the credential has extra permissions, so the person provisioning the sample remains responsible for limiting the token at issuance — see [Tighten the GitHub credential to least privilege](#tighten-the-github-credential-to-least-privilege).

The ToolServer sends these headers:

- `Authorization: Bearer <active gh token>`
- `X-MCP-Readonly: true`
- `X-MCP-Tools: list_pull_requests,list_issues,actions_list`

The ToolServer uses `failureMode: failClosed`. `infra/toolbox.yaml` also sets `require_approval: "never"` because the exposed tools are read-only and explicitly allowlisted.

The application does not accept a GitHub token environment variable. A local or hosted agent invocation reaches GitHub only through Foundry Toolbox and AI Gateway.

## Tighten the GitHub credential to least privilege

If `azd up` prints a warning that the GitHub credential is a broad, account-wide OAuth or classic token, provisioning still succeeds, but the postprovision hook stores that credential in the cloud AI Gateway ToolServer. Replace it with a fine-grained, repository-scoped, read-only token by following both parts below: create the token in the GitHub portal, then re-apply it from the command line.

> **Seeing `403 Forbidden` or empty MCP results for a public repo you do not own (for example `microsoft/agent-framework`)?** The token was applied, but it is being refused. Two common causes:
>
> - **Enterprise token-lifetime policy.** The repo owner's enterprise can cap fine-grained token lifetimes. The **Microsoft Open Source** enterprise forbids fine-grained tokens whose lifetime is **greater than 8 days** and returns `403` on every call (the body names the enterprise and links to your token's settings). Regenerate the token with an **expiration of 7 days or less** (step 3 below).
> - **Missing public-repo scope.** A fine-grained token cannot read a repository you do not own unless it is scoped with **Repository access → Public repositories (read-only)** (step 5 below). "Only select repositories" cannot include a repo you do not administer, so it yields no read access.
>
> Confirm the exact reason by reading the response body:
>
> ```bash
> curl -sS -H "Authorization: ******" \
>   -H "Accept: application/vnd.github+json" \
>   https://api.github.com/repos/microsoft/agent-framework
> ```

### 1. Create the token in the GitHub portal

1. Open <https://github.com/settings/personal-access-tokens/new>. This is **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. **Token name**: for example `foundry-ai-gateway-repo-digest`.
3. **Expiration**: choose the shortest window that fits your rotation policy. If the repository owner belongs to an enterprise that caps fine-grained token lifetimes, you must stay within that cap or every API call returns `403`. The **Microsoft Open Source** enterprise (which owns `microsoft/agent-framework`) forbids fine-grained tokens with a lifetime greater than **8 days**, so pick **7 days** for that and other Microsoft-owned public repositories.
4. **Resource owner**: select the account or organization that owns the repository being summarized. For a public repository you do not own, select your own account.
5. **Repository access**:
   - For a repository you own or administer, choose **Only select repositories** and pick that single repository.
   - For a public repository you do not own, choose **Public repositories (read-only)**. This grants the read-only `pull` permission with no repository-permission selection required; skip to step 7.
6. **Repository permissions** (only when you selected a specific repository) — set each of these to **Read-only** and leave everything else at **No access**:
   - Metadata (required; auto-selected)
   - Actions
   - Contents
   - Issues
   - Pull requests
7. Click **Generate token** and copy the `github_pat_...` value. You cannot view it again after leaving the page.

Avoid repository write, administration, organization administration, workflow write, or classic `repo` scope.

### 2. Apply the token from the command line

Re-run provisioning with the fine-grained token exported as `GH_TOKEN`. The hook prefers `GH_TOKEN` over the account-wide GitHub CLI login and writes the tighter credential into the ToolServer.

macOS or Linux (bash):

```bash
read -rsp "Fine-grained GitHub token: " GH_TOKEN && echo
export GH_TOKEN
azd provision
```

macOS (zsh — the default macOS shell). The `read` prompt syntax differs from bash: the prompt goes *inside* the variable spec as `VAR?prompt`, and `-p` must not be used (in zsh `-p` reads from a coprocess, so no prompt appears). Paste one line at a time so `read` does not consume the following lines as input:

```zsh
read -rs "GH_TOKEN?Fine-grained GitHub token: " && echo
export GH_TOKEN
azd provision
```

Shell-agnostic alternative (hidden entry, works in both bash and zsh):

```bash
export GH_TOKEN="$(python3 -c 'import getpass; print(getpass.getpass("Fine-grained GitHub token: "))')"
azd provision
```

Windows (PowerShell 7):

```powershell
$GH_TOKEN = Read-Host -Prompt "Fine-grained GitHub token" -AsSecureString
$env:GH_TOKEN = [System.Net.NetworkCredential]::new("", $GH_TOKEN).Password
azd provision
```

`azd up` also works in place of `azd provision`. A GitHub App installation access token (`ghs_...`) is an equally accepted least-privilege credential.

### 3. Confirm the warning is gone

Re-running provisioning with the fine-grained token should print `Using the active GitHub CLI login for GitHub MCP.` with no credential warning. The advisory check runs inside the postprovision hook (`Assert-GitHubAccess` in `configure-ai-gateway.ps1`, `verify_github_access` in `configure-ai-gateway.sh`). GitHub does not return the complete selected-repository boundary or every granular write permission through the coarse repository role flags, so the advisory check cannot certify least privilege on its own; scoping the token in the portal as above is what enforces it.

## Tool middleware

[`GitHubMcpMiddleware`](../agent/GitHubMcpMiddleware.cs) runs only for these source tool names:

- `github_list_pull_requests`
- `github_list_issues`
- `github_actions_list`

Toolbox prefixes are removed by taking the text after the final `___`.

Before invocation, middleware forces bounded arguments:

| Tool | Enforced arguments |
| --- | --- |
| Pull requests | `state=all`, `sort=updated`, `direction=desc`, `perPage=100`, `page=1` |
| Issues (`list_issues`) | `orderBy=UPDATED_AT`, `direction=DESC`, `since=<UTC cutoff>`, `perPage=100` (no `query`, no `page`) |
| Workflow runs | `method=list_workflow_runs`, `status=completed`, `per_page=100`, `page=1` |

`list_issues` uses the core GitHub API (not the Search API), which avoids the Search API's stricter rate limits and the `403`/empty results it returns for public repositories the credential does not own. The cutoff is exactly 24 hours before function invocation. Pull requests and issues are filtered locally by `updated_at`. Workflow results retain only failed runs updated or created since the cutoff.

The middleware removes large fields such as issue bodies, pull request bodies, commits, and workflow payloads. It keeps identifiers, titles, state, timestamps, URLs, labels, and actor information needed by the digest. Non-JSON tool errors and unexpected result shapes are returned unchanged.

## Infrastructure

The Bicep layout separates model, hosted-agent, and gateway resources:

- `infra/main.bicep` creates three resource groups and composes the deployment.
- `infra/foundry-models/main.bicep` owns model deployments in a separate AI Services account.
- `infra/foundry-agents/main.bicep` owns the Foundry project, storage, container registry, and monitoring resources.
- `infra/ai-gateway/main.bicep` owns AI Gateway, the connector namespace, Foundry provider, model catalog entries, telemetry, ToolServer resource surface, and runtime API key.
- `infra/ai-gateway/foundry-user-role.bicep` grants the gateway managed identity Foundry User access to the model account.

Storage shared key access, Cognitive Services local authentication, and Container Registry admin credentials are disabled. Project access uses Microsoft Entra ID and managed identities.

The templates currently allow public network access because this quickstart has no VNET inputs. For production data, add VNET integration and private endpoints before placing sensitive resources behind the gateway.

## Provisioning hooks

The preprovision hook:

1. Preserves a healthy, environment-owned AI Gateway.
2. Deletes only an environment-owned gateway in terminal `Failed` state.
3. Purges the matching APIM soft-delete record.
4. Waits for managed identity cleanup before Bicep retries creation.
5. Removes legacy script-owned Foundry User role assignments so Bicep can adopt the assignment.

The postprovision hook:

1. Verifies Bicep created the canonical `Microsoft.ApiManagement/service` resource with `AIGateway` SKU and system-assigned identity.
2. Verifies the Foundry provider uses managed identity.
3. Reads the active GitHub CLI token.
4. Configures the read-only GitHub ToolServer.
5. Reads the AI Gateway runtime API key.
6. Makes a bounded, minimal chat completions request with the explicit `Api-Key` header until the Bicep-provisioned model route is published.
7. Creates or updates the Foundry remote-tool connection.
8. Creates the Foundry Toolbox if it does not exist.
9. Saves only runtime configuration required by the hosted agent.

The postdown hook completes deletion, soft-delete purge, and the same identity settle wait.

The lifecycle implementation does not persist a lifecycle marker or discover a missing gateway by walking recent nested deployment failures. It uses the exact resource outputs when available, otherwise requires a unique environment-tagged AI Gateway, preserves healthy gateways during preprovision, deletes failed or explicitly cleaned-up gateways, validates the APIM soft-delete `serviceId`, purges it, and waits for identity cleanup. Only a confirmed 404 is treated as absence; authorization, throttling, and service errors fail closed.

## Model deployment

The default model catalog aliases are:

- `gpt-latest`, backed by `gpt-5.6-sol` version `2026-07-09`
- `gpt-mini-latest`, backed by `gpt-5.4-mini` version `2026-03-17`

The full model uses `GlobalStandard` capacity 20 by default. The mini model uses capacity 200 to accommodate GitHub Copilot app requests that include large built-in tool schemas. These are deployment defaults, not application constants. Change Bicep parameters when model availability or quota differs by subscription or region.

Each Gateway catalog registration sets `deployment.modelName` from the final segment of the Foundry deployment `resourceId`, not from the backing catalog model name. The Gateway token-limit policy is derived from the corresponding deployment capacity at 1,000 tokens per capacity unit. This keeps the registration aligned with the actual Foundry deployment name and prevents Gateway throttling below the backing deployment's tokens-per-minute quota.

AI Gateway model entries support:

- `/openai/v1/chat/completions`
- `/openai/v1/responses`

The .NET agent uses chat completions through the OpenAI-compatible AI Gateway route.

## Monitoring

The deployment creates separate Application Insights and Log Analytics resources for:

- AI Gateway telemetry
- Foundry hosted-agent tracing

The AI Gateway telemetry exporter disables payload capture. Do not enable payload capture without reviewing repository data, prompts, tool output, and credential handling requirements.

## Local development

After `azd provision`, run `scripts/create-dev-env.sh` or `scripts/create-dev-env.ps1`. The script creates `.env` with mode `0600` or an equivalent Windows ACL and refuses to overwrite an existing file unless forced.

`DotNetEnv` loads `.env` without replacing variables already present in the process environment.

## Deployment packaging

The Docker image uses a .NET 10 SDK build stage and a .NET 10 ASP.NET runtime stage. The service listens on port 8088 through `ASPNETCORE_URLS`.

`.agentignore` excludes tests, local state, and deployment metadata from the hosted-agent package. `.dockerignore` excludes the same development-only surfaces from the Docker build context.

## Testing

`tests/FoundryHostedAgent.AIGateway.Tests/GitHubMcpMiddlewareTests.cs` covers:

- argument normalization
- issue time filtering and field compaction
- pull request time filtering
- failed workflow filtering
- non-JSON error preservation

Run:

```bash
dotnet test tests/FoundryHostedAgent.AIGateway.Tests/FoundryHostedAgent.AIGateway.Tests.csproj
bash tests/test-apim-lifecycle.sh
bash tests/test-ai-gateway-model-registration.sh
```
