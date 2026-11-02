# Foundry model account

Run the commands in this README from the `infra/foundry-models/` directory.

[`main.bicep`](main.bicep) deploys a model-serving Azure AI Services account
with `allowProjectManagement: false` and `disableLocalAuth: true`. It creates
the model deployments passed through the required `modelDeployments` array and
can optionally grant the supplied `principalId` developer roles on the
account.

The sample's default deployment set is:

| Deployment name | Model | Version | SKU | Capacity |
| --- | --- | --- | --- | --- |
| `gpt-latest` | `gpt-6.1-sol` | `2026-09-29` | `GlobalStandard` | 20 |
| `gpt-6-sol` | `gpt-6-sol` | `2026-09-22` | `GlobalStandard` | 20 |
| `gpt-mini-latest` | `gpt-5.4-mini` | `2026-03-17` | `GlobalStandard` | 200 |

The subscription-scoped [`../main.bicep`](../main.bicep) provides this array
automatically. For an independent deployment, create a resource group and pass
the model definitions explicitly:

```bash
az group create --name rg-foundry-models --location eastus2

az deployment group create \
  --resource-group rg-foundry-models \
  --template-file ./main.bicep \
  --parameters location=eastus2 \
               aiServicesName=aimodels-example \
               principalId="$(az ad signed-in-user show --query id -o tsv)" \
               modelDeployments='[
                 {"deploymentName":"gpt-latest","modelName":"gpt-6.1-sol","modelFormat":"OpenAI","modelVersion":"2026-09-29","skuName":"GlobalStandard","capacity":20},
                 {"deploymentName":"gpt-6-sol","modelName":"gpt-6-sol","modelFormat":"OpenAI","modelVersion":"2026-09-22","skuName":"GlobalStandard","capacity":20},
                 {"deploymentName":"gpt-mini-latest","modelName":"gpt-5.4-mini","modelFormat":"OpenAI","modelVersion":"2026-03-17","skuName":"GlobalStandard","capacity":200}
               ]'
```

`aiServicesName` must be globally unique and valid for an Azure AI Services
account. Set `principalId` to an authorized developer's object ID, or omit it
for no optional user role assignments.

Useful deployment outputs:

- `aiServicesId`: resource ID of the model account.
- `aiServicesEndpoint`: endpoint used by the Gateway Foundry provider.
- `modelDeploymentIds`: resource IDs for the deployments, in the same order as
  the `modelDeployments` input.
