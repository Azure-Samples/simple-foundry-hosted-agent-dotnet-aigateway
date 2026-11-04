targetScope = 'resourceGroup'

param location string
param gatewayLocation string = location
param gatewayName string
param tags object = {}
param enableMonitoring bool = false
param deployApimGatewayViaBicep bool = true
param appInsightsName string = '${gatewayName}-insights'
param logAnalyticsWorkspaceName string = take('${gatewayName}-logs', 63)
param deployFoundryProvider bool = false
param foundryProviderName string = 'foundry'
param foundryProviderDisplayName string = 'Foundry'
param foundryProviderDescription string = ''
param foundryEndpoint string = ''
param foundryResourceIds array = []
param foundryManagedIdentityResource string = 'https://cognitiveservices.azure.com/'
param foundryModels array = []
param modelAliasesConfig array = []
param foundryAgentsResourceGroupName string = resourceGroup().name
param foundryAgentsAccountName string = ''
param foundryAgentsProjectName string = ''
param foundryAgentsAccountPrincipalId string = ''
param foundryAgentsProjectPrincipalId string = ''
param principalId string = ''
param useManagedIdentityForFoundryConnections bool = true
param aiGatewayAudience string = 'https://azure-api.net/aigateway'
@description('Optional resource ID of an existing subnet in the same subscription and region, delegated to Microsoft.App/environments, for outbound VNet integration.')
param backendSubnetResourceId string = ''
@description('Optional CIDR ranges allowed to call registered models via an inline ipFilter policy. Leave empty to allow all caller IPs.')
param allowedCallerCidrRanges array = []
@secure()
param toolServerConfigs object = {}

var aiGatewayApiVersion = '2025-09-01-preview'
var appInsightsApiVersion = '2020-02-02'
var logAnalyticsApiVersion = '2023-09-01'
var telemetryWorkspaceName = 'default'
var aiGatewayUserRoleDefinitionId = 'caad7a21-134e-43f4-a550-c5ffc17e051c'
var normalizedFoundryEndpoint = endsWith(foundryEndpoint, '/') ? foundryEndpoint : '${foundryEndpoint}/'
var optionalIpFilterPolicies = empty(allowedCallerCidrRanges)
  ? []
  : [
      {
        type: 'ipFilter'
        action: 'Allow'
        cidrRanges: allowedCallerCidrRanges
      }
    ]
#disable-next-line BCP081
resource aiGateway 'Microsoft.ApiManagement/aigateways@2025-09-01-preview' = if (deployApimGatewayViaBicep) {
  name: gatewayName
  location: gatewayLocation
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: empty(backendSubnetResourceId)
    ? {}
    : {
        backend: {
          subnet: {
            id: backendSubnetResourceId
          }
        }
      }
}

#disable-next-line BCP081
resource defaultWorkspace 'Microsoft.ApiManagement/aigateways/workspaces@2025-09-01-preview' existing = if (deployApimGatewayViaBicep) {
  parent: aiGateway
  name: telemetryWorkspaceName
}

module foundryUserRoleAssignments './foundry-user-role.bicep' = [for (foundryResourceId, i) in foundryResourceIds: if (deployFoundryProvider && deployApimGatewayViaBicep) {
  name: 'foundry-rbac-${i}-${uniqueString(foundryResourceId, gatewayName)}'
  scope: resourceGroup(split(foundryResourceId, '/')[2], split(foundryResourceId, '/')[4])
  params: {
    foundryAccountName: last(split(foundryResourceId, '/'))
    gatewayPrincipalId: aiGateway!.identity.principalId
    gatewayResourceId: aiGateway!.id
  }
}]

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (enableMonitoring) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource gatewayAppInsights 'Microsoft.Insights/components@2020-02-02' = if (enableMonitoring) {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    #disable-next-line BCP037
    AzureMonitorWorkspaceIngestionMode: 'Enabled'
  }
}

#disable-next-line BCP081
resource foundryProvider 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2025-09-01-preview' = if (deployFoundryProvider && deployApimGatewayViaBicep) {
  parent: defaultWorkspace
  name: foundryProviderName
  dependsOn: [
    foundryUserRoleAssignments
  ]
  properties: {
    kind: 'Foundry'
    displayName: foundryProviderDisplayName
    description: empty(foundryProviderDescription) ? null : foundryProviderDescription
    foundry: {
      endpoint: normalizedFoundryEndpoint
      resourceIds: foundryResourceIds
      authentication: {
        kind: 'ManagedIdentity'
        managedIdentity: {
          resource: foundryManagedIdentityResource
        }
      }
    }
  }
}

#disable-next-line BCP081
resource foundryCatalogModels 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2025-09-01-preview' = [for model in foundryModels: if (deployFoundryProvider && deployApimGatewayViaBicep) {
  parent: foundryProvider
  name: model.armName
  properties: {
    description: model.?description ?? null
    displayName: model.modelName
    apiFormat: model.apiFormat
    supportedEndpoints: model.supportedEndpoints
    deployment: {
      resourceId: model.resourceId
      modelName: last(split(model.resourceId, '/'))
      modelVersion: model.?modelVersion ?? null
    }
    policies: model.?policies ?? concat(
      [
        {
          type: 'tokenLimit'
          period: 'minute'
          count: model.?tokenLimit ?? 10000
          counterKey: [
            'identity'
          ]
        }
        {
          id: 'monthly-caller-budget'
          type: 'costLimit'
          period: 'month'
          amount: model.?costLimit ?? 10
          counterKey: [
            'identity'
          ]
        }
        {
          type: 'contentSafety'
          hateSeverity: model.?contentSafetySeverity ?? 'Medium'
          selfHarmSeverity: model.?contentSafetySeverity ?? 'Medium'
          sexualSeverity: model.?contentSafetySeverity ?? 'Medium'
          violenceSeverity: model.?contentSafetySeverity ?? 'Medium'
        }
      ],
      optionalIpFilterPolicies
    )
  }
}]

#disable-next-line BCP081
resource modelAliases 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2025-09-01-preview' = [for alias in modelAliasesConfig: if (deployFoundryProvider && deployApimGatewayViaBicep) {
  parent: defaultWorkspace
  name: alias.armName
  dependsOn: [
    foundryCatalogModels
  ]
  properties: {
    aliasName: alias.aliasName
    description: alias.?description ?? null
    backendModels: [for target in alias.backendModels: {
      resourceId: resourceId(
        'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models',
        gatewayName,
        telemetryWorkspaceName,
        foundryProviderName,
        target.modelArmName
      )
      priority: target.priority
      weight: target.weight
    }]
  }
}]

#disable-next-line BCP081
resource toolServers 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2025-09-01-preview' = [for config in items(toolServerConfigs): if (deployApimGatewayViaBicep) {
  parent: defaultWorkspace
  name: config.key
  properties: config.value
}]

#disable-next-line BCP081
resource runtimeApiKey 'Microsoft.ApiManagement/aigateways/apiKeys@2025-09-01-preview' = if (deployApimGatewayViaBicep) {
  parent: aiGateway
  name: 'default'
  properties: {
    displayName: 'Default hosted agent key'
  }
}

resource aiGatewayProjectUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApimGatewayViaBicep && !empty(foundryAgentsProjectName) && !empty(foundryAgentsProjectPrincipalId)) {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRoleDefinitionId, foundryAgentsProjectName)
  properties: {
    principalId: foundryAgentsProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRoleDefinitionId)
  }
}

resource aiGatewayAccountUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApimGatewayViaBicep && !empty(foundryAgentsAccountName) && !empty(foundryAgentsAccountPrincipalId)) {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRoleDefinitionId, foundryAgentsAccountName)
  properties: {
    principalId: foundryAgentsAccountPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRoleDefinitionId)
  }
}

resource aiGatewayDeveloperUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApimGatewayViaBicep && !empty(principalId)) {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRoleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRoleDefinitionId)
  }
}

var runtimeHostname = deployApimGatewayViaBicep ? (aiGateway!.properties.?frontend.?defaultHostname ?? replace(aiGateway!.properties.?gatewayUrl ?? '', 'https://', '')) : ''

module githubConnection '../foundry-agents/github-connection.bicep' = if (deployApimGatewayViaBicep && !empty(foundryAgentsProjectName)) {
  name: 'github-connection-${uniqueString(gatewayName, foundryAgentsProjectName)}'
  scope: resourceGroup(foundryAgentsResourceGroupName)
  dependsOn: [
    aiGatewayProjectUserRoleAssignment
    aiGatewayAccountUserRoleAssignment
  ]
  params: {
    aiServicesName: foundryAgentsAccountName
    aiProjectName: foundryAgentsProjectName
    gatewayUrl: 'https://${runtimeHostname}'
    useManagedIdentity: useManagedIdentityForFoundryConnections
    gatewayAudience: aiGatewayAudience
    gatewayApiKey: useManagedIdentityForFoundryConnections ? '' : (runtimeApiKey!.listSecrets().?primaryKey ?? runtimeApiKey!.listSecrets().?key ?? '')
  }
}

var modelAliasResourceIds = [for alias in modelAliasesConfig: resourceId('Microsoft.ApiManagement/aigateways/workspaces/aliases', gatewayName, telemetryWorkspaceName, alias.armName)]

output apimGatewayId string = resourceId('Microsoft.ApiManagement/aigateways', gatewayName)
output appInsightsId string = enableMonitoring ? gatewayAppInsights.id : ''
output appInsightsName string = enableMonitoring ? gatewayAppInsights.name : ''
output logAnalyticsWorkspaceId string = enableMonitoring ? logAnalyticsWorkspace.id : ''
output logAnalyticsWorkspaceName string = enableMonitoring ? logAnalyticsWorkspace.name : ''
output runtimeHostname string = runtimeHostname
output runtimeApiKeyId string = deployApimGatewayViaBicep ? runtimeApiKey.id : ''
output gatewayPrincipalId string = deployApimGatewayViaBicep ? aiGateway!.identity.principalId : ''
output foundryUserRoleAssignmentName string = deployFoundryProvider && deployApimGatewayViaBicep && !empty(foundryResourceIds) ? foundryUserRoleAssignments[0]!.outputs.roleAssignmentName : ''
output modelAliasIds array = deployFoundryProvider && deployApimGatewayViaBicep ? modelAliasResourceIds : []
output defaultModelAliasName string = !empty(modelAliasesConfig) ? modelAliasesConfig[0].aliasName : ''
output gatewayLocation string = gatewayLocation
output apiVersions object = {
  aiGateway: aiGatewayApiVersion
  appInsights: appInsightsApiVersion
  logAnalytics: logAnalyticsApiVersion
}
