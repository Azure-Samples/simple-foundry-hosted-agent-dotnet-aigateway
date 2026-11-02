# Foundry project and hosted-agent runtime

Run the commands in this README from the `infra/foundry-agents/` directory.

[`main.bicep`](main.bicep) creates a project-enabled Azure AI Services account
(`allowProjectManagement: true`), a Foundry project, and its hosted-agent
dependencies:

- Storage Account and project storage connection.
- Premium Azure Container Registry (ACR) and project registry connection.
- Log Analytics workspace and Application Insights component/connection.
- Project and optional developer RBAC assignments, including the permissions
  needed for the project to use its account, storage, and registry.

Deploy this resource-group-scoped module independently by supplying names for
its required resources:

```bash
az group create --name rg-foundry-agents --location eastus2

az deployment group create \
  --resource-group rg-foundry-agents \
  --template-file ./main.bicep \
  --parameters location=eastus2 \
               aiServicesName=aiagents-example \
               aiProjectName=repo-digest \
               aiProjectFriendlyName="Daily Repo Digest" \
               aiProjectDescription="Foundry Hosted Agent sample." \
               storageName=stexample001 \
               containerRegistryName=acrexample123 \
               appInsightsName=aiagents-example-insights \
               logAnalyticsWorkspaceName=aiagents-example-logs \
               principalId="$(az ad signed-in-user show --query id -o tsv)"
```

Resource names must meet the naming rules for their Azure resource types and be
available. Omit `principalId` if the deploying developer does not need optional
user-level role assignments.

Useful deployment outputs:

- `projectEndpoint`: Foundry project endpoint for clients and Toolbox setup.
- `containerRegistryEndpoint`: ACR login server for hosted-agent images.
- `aiProjectResourceId`: resource ID of the Foundry project.
