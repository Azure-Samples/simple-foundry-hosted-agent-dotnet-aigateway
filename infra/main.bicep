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
@description('Azure region for the Microsoft.ApiManagement/aigateways resource.')
param aiGatewayLocation string = 'eastus2'

@description('Optional Azure AD user or service principal object ID for development access.')
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

@description('Whether to configure monitoring for the AI Gateway.')
param enableMonitoring bool = true

@description('Log Analytics workspace name for Application Insights. Defaults to a deterministic name in the application resource group.')
param logAnalyticsWorkspaceName string = ''

@description('Application Insights component for Foundry hosted-agent tracing.')
param agentAppInsightsName string = ''

@description('Log Analytics workspace for Foundry hosted-agent tracing.')
param agentLogAnalyticsWorkspaceName string = ''

@description('AI Gateway resource name. Defaults to a deterministic name.')
param aiGatewayName string = ''

@description('Optional resource ID of an existing subnet in the same subscription and region, delegated to Microsoft.App/environments, for AI Gateway outbound VNet integration.')
param backendSubnetResourceId string = ''

@description('Optional CIDR ranges allowed to call registered models and MCP tool servers via an inline ipFilter policy. Leave empty to allow all caller IPs.')
param allowedCallerCidrRanges array = []

@description('Default GitHub repository for the daily digest automation.')
param githubRepository string = 'microsoft/agent-framework'

@secure()
@description('Optional GitHub MCP Authorization header value (for example, Bearer <token>) for declarative Bicep toolServer provisioning.')
param githubMcpAuthorization string = ''

@description('GitHub MCP server URL.')
param githubMcpServerUrl string = 'https://api.githubcopilot.com/mcp/'

@description('Comma-separated read-only GitHub MCP tools exposed by the gateway.')
param githubMcpTools string = 'list_pull_requests,list_issues,actions_list'

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

@description('Global Standard capacity assigned to the secondary full model deployment.')
param secondaryModelCapacity int = 20

@description('Global Standard capacity assigned to the mini model deployment. Capacity 200 supports ghapp requests that include large built-in tool schemas.')
param miniModelCapacity int = 200

@description('ARM-safe deployment and Gateway catalog name for the full model.')
param modelDeploymentName string = 'gpt-latest'

@description('ARM-safe deployment and Gateway catalog name for the secondary full model.')
param secondaryModelDeploymentName string = 'gpt-6-sol'

@description('Client-facing alias name for the primary model, with secondary and mini-model failover.')
param modelAliasName string = 'gpt-latest'

@description('Optional primary alias routes. Use unique modelArmName values, priority 0-100, and weight 1-100; same-priority weights split traffic.')
param modelAliasBackends array = []

@description('Client-facing alias name for the mini model.')
param miniModelAliasName string = 'gpt-mini-latest'

@description('Backing Foundry model name for the full deployment.')
param modelName string = 'gpt-6.1-sol'

@description('Foundry version for the full model deployment.')
param modelVersion string = '2026-09-29'

@description('Backing Foundry model name for the secondary full deployment.')
param secondaryModelName string = 'gpt-6-sol'

@description('Foundry version for the secondary full model deployment.')
param secondaryModelVersion string = '2026-09-22'

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
var effectiveModelAliasBackends = empty(modelAliasBackends) ? [
  {
    modelArmName: modelDeploymentName
    priority: 0
    weight: 100
  }
  {
    modelArmName: secondaryModelDeploymentName
    priority: 1
    weight: 100
  }
  {
    modelArmName: miniModelDeploymentName
    priority: 2
    weight: 100
  }
] : modelAliasBackends
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
    description: 'Primary Gateway registration for the latest supported full GPT model.'
  }
  {
    deploymentName: secondaryModelDeploymentName
    modelName: secondaryModelName
    modelFormat: modelFormat
    modelVersion: secondaryModelVersion
    skuName: modelSkuName
    capacity: secondaryModelCapacity
    description: 'Secondary Gateway registration for full-model failover in a separate quota pool.'
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
    foundryAgentsResourceGroupName: foundryAgentsRg.name
    foundryAgentsAccountName: foundryAgents.outputs.aiServicesName
    foundryAgentsProjectName: foundryAgents.outputs.aiProjectName
    foundryAgentsAccountPrincipalId: foundryAgents.outputs.aiServicesPrincipalId
    foundryAgentsProjectPrincipalId: foundryAgents.outputs.aiProjectPrincipalId
    principalId: principalId
    backendSubnetResourceId: backendSubnetResourceId
    allowedCallerCidrRanges: allowedCallerCidrRanges
    tags: tags
    enableMonitoring: enableMonitoring
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
      apiFormat: 'OpenAIChatCompletions'
      tokenLimit: deployment.capacity * 1000
      costLimit: 10
      contentSafetySeverity: 'Medium'
      supportedEndpoints: [
        '/openai/v1/chat/completions'
        '/openai/v1/responses'
      ]
    }]
    modelAliasesConfig: [
      {
        armName: 'primary-router'
        aliasName: modelAliasName
        description: 'Primary model with automatic failover to the secondary full model and mini deployment.'
        backendModels: effectiveModelAliasBackends
      }
      {
        armName: 'mini-router'
        aliasName: miniModelAliasName
        description: 'Direct alias for the mini deployment.'
        backendModels: [
          {
            modelArmName: miniModelDeploymentName
            priority: 0
            weight: 100
          }
        ]
      }
    ]
    toolServerConfigs: empty(githubMcpAuthorization) ? {} : {
      github: {
        displayName: 'GitHub repository digest'
        description: 'Read-only GitHub tools for repository digests.'
        type: 'mcp'
        failureMode: 'failClosed'
        policies: concat(
          [
            {
              type: 'contentSafety'
              hateSeverity: 'Medium'
              selfHarmSeverity: 'Medium'
              sexualSeverity: 'Medium'
              violenceSeverity: 'Medium'
            }
          ],
          empty(allowedCallerCidrRanges)
            ? []
            : [
                {
                  type: 'ipFilter'
                  action: 'Allow'
                  cidrRanges: allowedCallerCidrRanges
                }
              ]
        )
        endpoints: [
          {
            namespace: 'github'
            kind: 'mcp'
            mcp: {
              url: githubMcpServerUrl
              transport: 'streamableHttp'
            }
            credentials: {
              type: 'header'
              headers: {
                Authorization: [
                  githubMcpAuthorization
                ]
                'X-MCP-Readonly': [
                  'true'
                ]
                'X-MCP-Tools': [
                  githubMcpTools
                ]
              }
            }
          }
        ]
      }
    }
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
output AI_GATEWAY_MODEL_ALIAS_IDS array = aiGateway.outputs.modelAliasIds
output AI_GATEWAY_DEFAULT_MODEL_ALIAS_NAME string = aiGateway.outputs.defaultModelAliasName
output AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_NAME string = aiGateway.outputs.foundryUserRoleAssignmentName
output AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_PRINCIPAL_ID string = aiGateway.outputs.gatewayPrincipalId
output AI_GATEWAY_APP_INSIGHTS_ID string = aiGateway.outputs.appInsightsId
output AI_GATEWAY_LOG_ANALYTICS_WORKSPACE_ID string = aiGateway.outputs.logAnalyticsWorkspaceId
output AI_GATEWAY_PRINCIPAL_ID string = aiGateway.outputs.gatewayPrincipalId
output APPLICATION_INSIGHTS_NAME string = aiGateway.outputs.appInsightsName
output LOG_ANALYTICS_WORKSPACE_ID string = aiGateway.outputs.logAnalyticsWorkspaceId
output LOG_ANALYTICS_WORKSPACE_NAME string = aiGateway.outputs.logAnalyticsWorkspaceName
output ENABLE_MONITORING bool = enableMonitoring
output AZURE_AI_GATEWAY_ENDPOINT string = 'https://${aiGateway.outputs.runtimeHostname}/'
output AZURE_AI_GATEWAY_MODEL string = modelAliasName
output AZURE_AI_GATEWAY_MINI_MODEL string = miniModelAliasName
output AI_GATEWAY_INTERNAL_MODEL_DEPLOYMENT string = modelDeploymentName
output AI_GATEWAY_INTERNAL_MODEL_NAME string = modelName
output AI_GATEWAY_INTERNAL_MODEL_VERSION string = modelVersion
output AI_GATEWAY_INTERNAL_SECONDARY_MODEL_DEPLOYMENT string = secondaryModelDeploymentName
output AI_GATEWAY_INTERNAL_SECONDARY_MODEL_NAME string = secondaryModelName
output AI_GATEWAY_INTERNAL_SECONDARY_MODEL_VERSION string = secondaryModelVersion
output AI_GATEWAY_INTERNAL_MINI_MODEL_DEPLOYMENT string = miniModelDeploymentName
output AI_GATEWAY_INTERNAL_MINI_MODEL_NAME string = miniModelName
output AI_GATEWAY_INTERNAL_MINI_MODEL_VERSION string = miniModelVersion
