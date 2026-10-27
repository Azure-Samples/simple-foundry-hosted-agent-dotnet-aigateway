# Infrastructure

[`main.bicep`](main.bicep) is the subscription-scoped entry point. It creates three environment-tagged resource groups and composes:

| Module | Responsibility |
| --- | --- |
| [AI Gateway](ai-gateway/README.md) | Standalone Consumption gateway, model catalog and aliases, telemetry, ToolServers, and runtime key |
| [Foundry models](foundry-models/README.md) | Dedicated AI Services account and backing model deployments |
| [Foundry agents](foundry-agents/README.md) | Foundry project, storage, container registry, connections, and agent monitoring |
| [Deployment scripts](scripts/README.md) | Lifecycle safety, GitHub ToolServer configuration, route readiness, and Toolbox setup |

[`main.parameters.json`](main.parameters.json) supplies azd parameters. [`toolbox.yaml`](toolbox.yaml) defines the read-only `aigw-github` MCP connection.

The agent continues to request `gpt-latest`. Gateway routing provides the primary `gpt-6-1-sol` deployment with `gpt-6-sol` and `gpt-5-4-mini` fallbacks. `gpt-mini-latest` selects the mini deployment directly. Override `modelAliasBackends` to change the primary chain.

Provision with `azd up` from the repository root. Deployment outputs feed the hooks and existing .NET environment variables. Public networking is enabled for this quickstart; review private networking and credential scope before production use.

## Standalone deployment

Run examples from the repository root after signing in with `az login`. The entry point is subscription-scoped:

```bash
az deployment sub create --location eastus2 \
  --template-file infra/main.bicep \
  --parameters environmentName=dailydigest location=eastus2
```

Only `location` is required; other entry-point parameters have defaults. Choose regions with the required model availability and quota. To change the primary chain, pass `modelAliasBackends` as an array of `{modelArmName, priority, weight}` objects referencing registered catalog names.

Individual modules use `az deployment group create` against an existing resource group; see their examples. Direct Azure CLI deployments return ARM outputs but do not populate azd configuration, run lifecycle/configuration hooks, deploy the agent image, or create the Toolbox. Use `azd up` for the integrated sample.

## Live smoke check

With Azure CLI and azd authenticated and an azd environment selected:

```bash
bash tests/test-azd-smoke.sh          # Invoke the existing hosted agent
bash tests/test-azd-smoke.sh --deploy # Opt in to azd deploy, then invoke
bash tests/test-azd-smoke.sh --up     # Opt in to azd up --no-prompt, then invoke
```

These are live Azure operations, not offline tests. `--up` also needs the GitHub credential used by provisioning. The smoke check verifies a digest response, not actual backend failover.

See [implementation notes](../docs/implementation-notes.md) for runtime contracts and security boundaries.
