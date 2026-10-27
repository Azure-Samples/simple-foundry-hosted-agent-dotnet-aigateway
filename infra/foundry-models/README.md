# Foundry models module

[`main.bicep`](main.bicep) creates a dedicated AI Services account with local authentication disabled and deploys the models supplied by the parent template. Model deployments are serialized.

Default deployments from [`../main.bicep`](../main.bicep):

| Deployment | Model | Version | GlobalStandard capacity |
| --- | --- | --- | --- |
| `gpt-6-1-sol` | `gpt-6.1-sol` | `2026-09-29` | 20 |
| `gpt-6-sol` | `gpt-6-sol` | `2026-09-22` | 20 |
| `gpt-5-4-mini` | `gpt-5.4-mini` | `2026-03-17` | 200 |

Outputs provide the account endpoint, account resource ID, and deployment names and IDs to [AI Gateway](../ai-gateway/README.md). The gateway's managed identity receives Foundry User access through the gateway module.

`gpt-latest` and `gpt-mini-latest` are Gateway aliases, not these deployment names. The primary alias falls back across all three deployments; the mini alias selects only the mini deployment.

Adjust deployment parameters to match regional model availability and subscription quota. Deployment capacity does not configure a Gateway token-limit policy.

## Deploy independently

From the repository root, create a resource group and supply the required `aiServicesName` and `modelDeployments` parameters. `location` defaults to the resource group's location; `principalId` optionally grants development access.

```bash
az group create --name rg-digest-models --location eastus2
az deployment group create --resource-group rg-digest-models \
  --template-file infra/foundry-models/main.bicep \
  --parameters aiServicesName=your-unique-model-account \
  modelDeployments='[{"deploymentName":"gpt-5-4-mini","modelName":"gpt-5.4-mini","modelVersion":"2026-03-17","modelFormat":"OpenAI","skuName":"GlobalStandard","capacity":200}]'
```

This minimal example deploys only the mini model. Supply all three deployment objects for the default primary chain. Module outputs do not register Gateway models, run hooks, or configure azd; pass them to the [gateway module](../ai-gateway/README.md) when composing your own deployment.
