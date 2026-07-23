# Coding agent instructions

## Repository shape

Keep the repository root limited to cross-project files such as `README.md`, `AGENTS.md`, `azure.yaml`, `global.json`, and the solution.

- `agent/` contains the hosted agent project, Dockerfile, deployment manifest, agent construction, and tool middleware.
- `chat/` contains the console chat client project.
- `tests/` contains .NET and deployment-script tests.
- `infra/` contains Bicep, toolbox configuration, and deployment hooks.
- `scripts/` contains local developer helpers.
- `docs/` contains implementation details.

Do not split small agent concerns into root-level files. Keep agent instructions, defaults, AI Gateway client setup, and agent construction together in `agent/DailyRepoDigestAgent.cs`. Keep GitHub result normalization and compaction in `agent/GitHubMcpMiddleware.cs`.

## Public sample behavior

Keep environment variable names, routes, tool arguments, defaults, security boundaries, and failure behavior consistent across the agent, deployment scripts, infrastructure, documentation, and tests. Update the implementation and its tests together.

## Coding conventions

- Target .NET 10 and use ASP.NET Core minimal APIs.
- Keep `agent/Program.cs` as a top-level Minimal API host. Read settings from `builder.Configuration`, register dependencies through `builder.Services`, and let MAF map the Foundry Responses and readiness endpoints.
- Do not add controllers, app-owned route groups, OpenAPI, Problem Details, authentication, HTTPS redirection, CORS, or request timeouts unless the hosted-agent protocol and deployment environment explicitly require them.
- Keep nullable reference types and implicit usings enabled.
- Prefer small private methods over new files when the concern belongs only to `DailyRepoDigestAgent`.
- Keep middleware external to the agent class.
- Preserve type safety and explicit error handling.
- Do not log or persist GitHub tokens or AI Gateway keys.
- Keep GitHub MCP read-only, allowlisted, and fail-closed.
- Use managed identity for Azure resources that support it.
- Do not add em dashes.

## Validation

Run the smallest relevant commands, then run the full set before finishing a parity or deployment change:

```bash
dotnet build FoundryHostedAgent.AIGateway.slnx --configuration Release
dotnet test tests/FoundryHostedAgent.AIGateway.Tests/FoundryHostedAgent.AIGateway.Tests.csproj --configuration Release
bash tests/test-apim-lifecycle.sh
bash tests/test-ai-gateway-model-registration.sh
find infra -name '*.bicep' -print0 | xargs -0 -n1 az bicep build --stdout --file >/dev/null
bash -n scripts/create-dev-env.sh
bash -n infra/scripts/configure-ai-gateway.sh
bash -n infra/scripts/manage-ai-gateway-lifecycle.sh
docker build agent
```

Do not run `azd up` or `azd down` unless the task explicitly includes changing Azure resources.
