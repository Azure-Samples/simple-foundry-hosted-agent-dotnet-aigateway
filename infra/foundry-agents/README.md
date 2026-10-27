# Foundry agents module

[`main.bicep`](main.bicep) provisions the hosted-agent environment independently of the model account:

- AI Services account with project management enabled and a managed-identity Foundry project.
- Storage account for artifacts, with shared-key access disabled.
- Premium Container Registry with admin credentials disabled.
- Project storage and registry connections and required identity role assignments.
- Application Insights and Log Analytics for hosted-agent tracing.

Outputs expose the project endpoint, registry, monitoring resources, and connection names to azd. The hosted runtime uses managed identity for Foundry Toolbox. Model calls use AI Gateway and its runtime key, not this account's model endpoint.

The .NET 10 agent remains in [`agent/`](../../agent/); this module does not implement application routes or tool middleware. The Foundry hosting package maps `/responses` and `/readiness`.

Public networking is enabled for this quickstart. Review networking and access requirements before using sensitive data.

## Deploy independently

From the repository root:

```bash
az group create --name rg-digest-agents --location eastus2
az deployment group create --resource-group rg-digest-agents \
  --template-file infra/foundry-agents/main.bicep \
  --parameters aiServicesName=your-unique-agent-account \
  aiProjectName=digest aiProjectDescription='Daily repo digest' \
  storageName=youruniquestorage containerRegistryName=youruniqueregistry \
  appInsightsName=digest-agent-insights logAnalyticsWorkspaceName=digest-agent-logs
```

The command supplies all required parameters. `location` defaults to the resource group, `aiProjectFriendlyName` defaults to the project name, and `principalId` is optional development access. Use globally unique account, storage, and registry names.

This creates infrastructure only. ARM outputs do not run hooks, populate azd configuration, deploy the hosted agent, or create the Toolbox. Use the root `azd up` flow for those steps.
