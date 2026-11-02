# Infrastructure

Run the commands in this README from the `infra/` directory.

The subscription-scoped [`main.bicep`](main.bicep) template creates three
resource groups and deploys one module into each:

- [`foundry-models/`](foundry-models/README.md) creates a model-only Azure AI
  Services account and the GPT deployments.
- [`foundry-agents/`](foundry-agents/README.md) creates the Foundry project and
  hosted-agent runtime dependencies.
- [`ai-gateway/`](ai-gateway/README.md) creates AI Gateway, model registrations,
  and aliases.

The [`scripts/`](scripts/README.md) directory contains the preprovision,
postprovision, and postdown lifecycle hooks. `azd provision` runs the
preprovision and postprovision hooks from `azure.yaml`; postprovision configures
the GitHub MCP ToolServer and Foundry Toolbox after Bicep creates the Azure
resources.

## AI Gateway policies

By default, each model has a `tokenLimit` of 1,000 tokens per minute per unit
of deployment capacity (20,000 for `gpt-latest` and `gpt-6-sol`; 200,000 for
`gpt-mini-latest`), a `$10.00/month` `costLimit` per caller identity
(`monthly-caller-budget`), and `Medium` `contentSafety` thresholds for Hate,
Self-Harm, Sexual, and Violence. The same content-safety thresholds are applied
to the `toolServers/github` MCP server. The `gpt-latest` alias fails over across
`gpt-6.1-sol` (priority 0), `gpt-6-sol` (priority 1), and `gpt-5.4-mini`
(priority 2). See the [AI Gateway module README](ai-gateway/README.md) for
module usage and configuration.

## Deploy the full stack

`azd provision` also works from `infra/`: azd walks up to find
[`../azure.yaml`](../azure.yaml), then provisions the full stack and runs its
preprovision and postprovision hooks:

```bash
azd provision
```

Alternatively, deploy the subscription-scoped Bicep template directly:

```bash
az deployment sub create \
  --location eastus2 \
  --template-file ./main.bicep \
  --parameters environmentName=dailydigest \
               location=eastus2 \
               principalId="$(az ad signed-in-user show --query id -o tsv)"
```

The direct deployment creates the Azure resources but does not run azd hooks.
For GitHub MCP and Toolbox setup after a direct deployment, see
[`scripts/README.md`](scripts/README.md) and provide the deployment outputs to
the configuration script.

## Deploy individual modules

Each resource-group-scoped template can also be deployed independently. Create
its resource group first, then follow the module-specific parameters and
examples:

- [Foundry model account and deployments](foundry-models/README.md)
- [Foundry project and hosted-agent runtime](foundry-agents/README.md)
- [AI Gateway and model routing](ai-gateway/README.md)
- [Lifecycle and postprovision scripts](scripts/README.md)
