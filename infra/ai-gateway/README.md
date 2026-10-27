# AI Gateway module

[`main.bicep`](main.bicep) deploys `Microsoft.ApiManagement/aigateways@2025-09-01-preview` with `Consumption` SKU, system-assigned identity, and empty `properties: {}`. It does not deploy a legacy APIM `service`.

The existing `workspaces/default` resource parents:

- Application Insights telemetry exporters with payload capture disabled.
- Managed-identity Foundry model providers and their catalog model entries.
- Model aliases and read-only GitHub ToolServers.

Runtime `apiKeys` are direct gateway children. The module also provisions the connector namespace and uses [`foundry-user-role.bicep`](foundry-user-role.bicep) for model-account access.

## Model routing

| Public alias | Router | Catalog backends in priority order |
| --- | --- | --- |
| `gpt-latest` | `primary-router` | `gpt-6-1-sol` (0), `gpt-6-sol` (1), `gpt-5-4-mini` (2) |
| `gpt-mini-latest` | `mini-router` | `gpt-5-4-mini` (0) |

Each backend has weight 100. The subscription entry point's `modelAliasBackends` overrides the primary chain; this module accepts the resulting `modelAliasesConfig`. Backend references are Gateway catalog model IDs, not Cognitive Services deployment IDs. Catalog `deployment.modelName` matches the Foundry deployment name.

Inline model policies are unsupported; this module does not configure a token-limit policy.

## Runtime endpoint

Use `properties.frontend.defaultHostname`, falling back to `properties.gatewayUrl`. The exported endpoint feeds the existing routes:

- `/default/models/openai/v1/`
- `/default/toolservers/github/mcp`

Runtime requests authenticate with `Api-Key`, not a bearer-wrapped Gateway key. [Postprovision scripts](../scripts/README.md) configure the GitHub credential and verify route readiness.

## Deploy independently or attach an existing model account

The only required module parameters are `location` and `gatewayName`. To register existing deployments, also set `deployFoundryProvider`, `foundryEndpoint`, `foundryResourceIds`, `foundryModels`, and `modelAliasesConfig`. The deploying identity needs permission to assign roles on the model account.

For example, save this as `gateway.bicepparam` at the repository root and replace the account ID and endpoint:

```bicep
using './infra/ai-gateway/main.bicep'

param location = 'eastus2'
param gatewayName = 'your-unique-digest-gateway'
param tags = { 'azd-env-name': 'dailydigest' }
param enableMonitoring = true
param deployFoundryProvider = true
var accountId = '/subscriptions/<subscription>/resourceGroups/<models-rg>/providers/Microsoft.CognitiveServices/accounts/<account>'
param foundryEndpoint = 'https://<account>.services.ai.azure.com/'
param foundryResourceIds = [accountId]
param foundryModels = [
  {
    armName: 'gpt-5-4-mini'
    modelName: 'gpt-5.4-mini'
    modelVersion: '2026-03-17'
    resourceId: '${accountId}/deployments/gpt-5-4-mini'
    apiFormat: 'OpenAIChatCompletions'
    supportedEndpoints: [
      '/openai/v1/chat/completions'
      '/openai/v1/responses'
    ]
  }
]
param modelAliasesConfig = [
  {
    armName: 'mini-router'
    aliasName: 'gpt-mini-latest'
    backendModels: [
      {
        modelArmName: 'gpt-5-4-mini'
        priority: 0
        weight: 100
      }
    ]
  }
]
```

Deploy to an existing resource group:

```bash
az group create --name rg-digest-gateway --location eastus2
az deployment group create --resource-group rg-digest-gateway \
  --parameters gateway.bicepparam
```

The example attaches one existing deployment without creating a model account. Add catalog entries and alias backends to compose the full chain. `toolServerConfigs` is optional secure configuration; do not save GitHub credentials in parameter files.

Module-only outputs include the runtime hostname, gateway ID, identity, and key resource ID. They do not retrieve the key, update azd configuration, run hooks, or create the Foundry Toolbox. Use `azd up` for the integrated .NET sample.
