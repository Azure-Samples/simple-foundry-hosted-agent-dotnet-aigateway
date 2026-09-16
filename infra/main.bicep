targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name. Used for deterministic uniqueness and resource tagging.')
param environmentName string = 'dailydigest'

@metadata({
  azd: {
    type: 'location'
    default: 'eastus2'
  }
})
@allowed([
  'eastus'
  'eastus2'
  'westus'
  'northcentralus'
  'swedencentral'
  'japaneast'
])
@description('Routines-supported Azure region for Foundry, storage, ACR, and monitoring resources.')
param location string

@allowed([
  'westus2'
  'westus3'
  'eastus'
  'westcentralus'
  'swedencentral'
  'eastus2'
])
@description('Azure region for the release-gated Microsoft.ApiManagement/service AIGateway resource.')
param aiGatewayLocation string = 'eastus2'

@description('Optional Microsoft Entra user object ID for development access.')
param principalId string = ''

@description('Optional AI Gateway resource group name.')
param gatewayResourceGroupName string = ''

@description('Optional Foundry model resource group name.')
param foundryModelsResourceGroupName string = ''

@description('Optional Foundry hosted-agent resource group name.')
param foundryAgentsResourceGroupName string = ''

@description('Friendly display name for the Foundry project.')
param aiProjectFriendlyName string = 'Daily Repo Digest'

@description('Description for the Foundry project.')
param aiProjectDescription string = 'Foundry Hosted Agent sample for a daily GitHub repo digest through AI Gateway.'

@description('Azure AI Services account for the Foundry hosted-agent project.')
param aiServicesName string = ''

@description('Azure AI Services account that owns only model deployments.')
param modelServicesName string = ''

@description('Foundry project name. Defaults to a deterministic name.')
param aiProjectName string = ''

@description('Storage account name for Foundry project artifacts. Defaults to a deterministic name.')
param aiStorageName string = ''

@description('Azure Container Registry name for hosted-agent images. Defaults to a deterministic globally unique name.')
param containerRegistryName string = ''

@description('Application Insights component name for AI Gateway monitoring. Defaults to a deterministic name.')
param appInsightsName string = ''

@description('Log Analytics workspace name for Application Insights. Defaults to a deterministic name in the application resource group.')
param logAnalyticsWorkspaceName string = ''

@description('Application Insights component for Foundry hosted-agent tracing.')
param agentAppInsightsName string = ''

@description('Log Analytics workspace for Foundry hosted-agent tracing.')
param agentLogAnalyticsWorkspaceName string = ''

@description('AI Gateway resource name. Defaults to a deterministic name.')
param aiGatewayName string = ''

@description('Default GitHub repository for the daily digest automation.')
param githubRepository string = 'microsoft/agent-framework'

@description('Backing Foundry model name for the efficient mini deployment.')
param miniModelName string = 'gpt-5.4-mini'

@description('Foundry version for the mini model deployment.')
param miniModelVersion string = '2026-03-17'

@description('ARM-safe deployment and Gateway catalog name for the mini model.')
param miniModelDeploymentName string = 'gpt-mini-latest'

@description('Model format for the Foundry deployment.')
param modelFormat string = 'OpenAI'

@description('Model deployment SKU name.')
param modelSkuName string = 'GlobalStandard'

@description('Global Standard capacity assigned to the full model deployment.')
param modelCapacity int = 20

@description('Global Standard capacity assigned to the mini model deployment. Capacity 200 supports ghapp requests that include large built-in tool schemas.')
param miniModelCapacity int = 200

@description('ARM-safe deployment and Gateway catalog name for the full model.')
param modelDeploymentName string = 'gpt-latest'

@description('Backing Foundry model name for the full deployment. Use gpt-5.5 only when gpt-5.6-sol is unavailable.')
param modelName string = 'gpt-5.6-sol'

@description('Foundry version for the full model deployment.')
param modelVersion string = '2026-07-09'

var resourceToken = take(toLower(uniqueString(subscription().id, environmentName, location)), 8)
var environmentLabel = toLower(environmentName)
var tags = { 'azd-env-name': environmentName }
var effectiveGatewayResourceGroupName = !empty(gatewayResourceGroupName) ? gatewayResourceGroupName : 'rg-${environmentLabel}-${resourceToken}-gateway'
var effectiveFoundryModelsResourceGroupName = !empty(foundryModelsResourceGroupName) ? foundryModelsResourceGroupName : 'rg-${environmentLabel}-${resourceToken}-foundrymodels'
var effectiveFoundryAgentsResourceGroupName = !empty(foundryAgentsResourceGroupName) ? foundryAgentsResourceGroupName : 'rg-${environmentLabel}-${resourceToken}-foundryagents'
var effectiveAiServicesName = !empty(aiServicesName) ? aiServicesName : 'aiagents-${resourceToken}'
var effectiveModelServicesName = !empty(modelServicesName) ? modelServicesName : 'aimodels-${resourceToken}'
var effectiveAiProjectName = !empty(aiProjectName) ? aiProjectName : 'proj-${resourceToken}'
var effectiveAiStorageName = !empty(aiStorageName) ? aiStorageName : 'st${resourceToken}'
var effectiveContainerRegistryName = !empty(containerRegistryName) ? containerRegistryName : 'acr${resourceToken}'
var effectiveAiGatewayName = !empty(aiGatewayName) ? aiGatewayName : 'aigw-${resourceToken}'
var effectiveAppInsightsName = !empty(appInsightsName) ? appInsightsName : take('${effectiveAiGatewayName}-insights', 64)
var effectiveLogAnalyticsWorkspaceName = !empty(logAnalyticsWorkspaceName) ? logAnalyticsWorkspaceName : take('${effectiveAiGatewayName}-logs', 63)
var effectiveAgentAppInsightsName = !empty(agentAppInsightsName) ? agentAppInsightsName : take('${effectiveAiServicesName}-appinsights', 64)
var effectiveAgentLogAnalyticsWorkspaceName = !empty(agentLogAnalyticsWorkspaceName) ? agentLogAnalyticsWorkspaceName : take('${effectiveAiServicesName}-logs', 63)
var gatewayModelDeployments = [
  {
    deploymentName: miniModelDeploymentName
    modelName: miniModelName
    modelFormat: modelFormat
    modelVersion: miniModelVersion
    skuName: modelSkuName
    capacity: miniModelCapacity
    description: 'Default model registration for AI Gateway using the latest supported GPT mini model.'
  }
  {
    deploymentName: modelDeploymentName
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    skuName: modelSkuName
    capacity: modelCapacity
    description: 'Gateway registration for the latest supported full GPT model.'
  }
]

resource gatewayRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: effectiveGatewayResourceGroupName
  location: location
  tags: tags
}

resource foundryModelsRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: effectiveFoundryModelsResourceGroupName
  location: location
  tags: tags
}

resource foundryAgentsRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: effectiveFoundryAgentsResourceGroupName
  location: location
  tags: tags
}

module foundryModels './foundry-models/main.bicep' = {
  name: 'foundry-models-${resourceToken}'
  scope: foundryModelsRg
  params: {
    location: location
    tags: tags
    aiServicesName: effectiveModelServicesName
    principalId: principalId
    modelDeployments: gatewayModelDeployments
  }
}

module foundryAgents './foundry-agents/main.bicep' = {
  name: 'foundry-agents-${resourceToken}'
  scope: foundryAgentsRg
  params: {
    location: location
    tags: tags
    aiServicesName: effectiveAiServicesName
    aiProjectName: effectiveAiProjectName
    aiProjectFriendlyName: aiProjectFriendlyName
    aiProjectDescription: aiProjectDescription
    storageName: effectiveAiStorageName
    containerRegistryName: effectiveContainerRegistryName
    appInsightsName: effectiveAgentAppInsightsName
    logAnalyticsWorkspaceName: effectiveAgentLogAnalyticsWorkspaceName
    principalId: principalId
  }
}

module aiGateway './ai-gateway/main.bicep' = {
  name: 'ai-gateway-${resourceToken}'
  scope: gatewayRg
  params: {
    location: location
    gatewayLocation: aiGatewayLocation
    gatewayName: effectiveAiGatewayName
    tags: tags
    enableMonitoring: true
    deployApimGatewayViaBicep: true
    appInsightsName: effectiveAppInsightsName
    logAnalyticsWorkspaceName: effectiveLogAnalyticsWorkspaceName
    deployFoundryProvider: true
    foundryProviderName: 'foundry'
    foundryProviderDisplayName: 'Foundry'
    foundryProviderDescription: 'Managed-identity Foundry provider for the deployments behind this sample.'
    foundryEndpoint: foundryModels.outputs.aiServicesEndpoint
    foundryResourceIds: [
      foundryModels.outputs.aiServicesId
    ]
    foundryModels: [for (deployment, i) in gatewayModelDeployments: {
      armName: deployment.deploymentName
      description: deployment.description
      resourceId: foundryModels.outputs.modelDeploymentIds[i]
      modelName: deployment.modelName
      modelVersion: deployment.modelVersion
      tokenLimit: deployment.capacity * 1000
      apiFormat: 'OpenAIChatCompletions'
      supportedEndpoints: [
        '/openai/v1/chat/completions'
        '/openai/v1/responses'
      ]
    }]
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output RESOURCE_GROUP string = foundryAgentsRg.name
output AZURE_RESOURCE_GROUP string = foundryAgentsRg.name
output AI_GATEWAY_RESOURCE_GROUP string = gatewayRg.name
output FOUNDRY_MODELS_RESOURCE_GROUP string = foundryModelsRg.name
output FOUNDRY_AGENTS_RESOURCE_GROUP string = foundryAgentsRg.name
output FOUNDRY_MODELS_RESOURCE_ID string = foundryModels.outputs.aiServicesId
output FOUNDRY_MODELS_NAME string = foundryModels.outputs.aiServicesName
output AI_SERVICES_NAME string = foundryAgents.outputs.aiServicesName
output PROJECT_ENDPOINT string = foundryAgents.outputs.projectEndpoint
output FOUNDRY_PROJECT_ENDPOINT string = foundryAgents.outputs.projectEndpoint
output AZURE_AI_PROJECT_ENDPOINT string = foundryAgents.outputs.projectEndpoint
output AZURE_AI_PROJECT_ID string = foundryAgents.outputs.aiProjectResourceId
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = foundryAgents.outputs.containerRegistryEndpoint
output AZURE_CONTAINER_REGISTRY_RESOURCE_ID string = foundryAgents.outputs.containerRegistryId
output AZURE_CONTAINER_REGISTRY_NAME string = foundryAgents.outputs.containerRegistryName
output AZURE_AI_PROJECT_ACR_CONNECTION_NAME string = foundryAgents.outputs.containerRegistryConnectionName
output FOUNDRY_APPLICATION_INSIGHTS_ID string = foundryAgents.outputs.appInsightsId
output FOUNDRY_APPLICATION_INSIGHTS_NAME string = foundryAgents.outputs.appInsightsName
output FOUNDRY_LOG_ANALYTICS_WORKSPACE_ID string = foundryAgents.outputs.logAnalyticsWorkspaceId
output FOUNDRY_LOG_ANALYTICS_WORKSPACE_NAME string = foundryAgents.outputs.logAnalyticsWorkspaceName
output FOUNDRY_APPLICATION_INSIGHTS_CONNECTION_NAME string = foundryAgents.outputs.appInsightsConnectionName
output GITHUB_REPOSITORY string = githubRepository
output TOOLBOX_NAME string = 'repo-digest-tools'
output ENABLE_AI_GATEWAY bool = true
output AI_GATEWAY_NAME string = effectiveAiGatewayName
output AI_GATEWAY_LOCATION string = aiGatewayLocation
output AI_GATEWAY_RESOURCE_ID string = aiGateway.outputs.apimGatewayId
output AI_GATEWAY_CONNECTOR_NAMESPACE_RESOURCE_ID string = aiGateway.outputs.connectorNamespaceId
output AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_NAME string = aiGateway.outputs.foundryUserRoleAssignmentName
output AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_PRINCIPAL_ID string = aiGateway.outputs.gatewayPrincipalId
output APPLICATION_INSIGHTS_NAME string = aiGateway.outputs.appInsightsName
output LOG_ANALYTICS_WORKSPACE_ID string = aiGateway.outputs.logAnalyticsWorkspaceId
output LOG_ANALYTICS_WORKSPACE_NAME string = aiGateway.outputs.logAnalyticsWorkspaceName
output AZURE_AI_GATEWAY_ENDPOINT string = 'https://${aiGateway.outputs.runtimeHostname}/'
output AZURE_AI_GATEWAY_MODEL string = modelDeploymentName
output AZURE_AI_GATEWAY_MINI_MODEL string = miniModelDeploymentName
