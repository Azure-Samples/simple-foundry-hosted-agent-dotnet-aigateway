targetScope = 'resourceGroup'

param location string
param gatewayLocation string = location
param gatewayName string
param tags object = {}
param enableMonitoring bool = false
param deployApimGatewayViaBicep bool = true
param appInsightsName string = '${gatewayName}-insights'
param logAnalyticsWorkspaceName string = take('${gatewayName}-logs', 63)
param publisherEmail string = 'noreply@example.com'
param publisherName string = 'AI Gateway'
param deployFoundryProvider bool = false
param foundryProviderName string = 'foundry'
param foundryProviderDisplayName string = 'Foundry'
param foundryProviderDescription string = ''
param foundryEndpoint string = ''
param foundryResourceIds array = []
param foundryManagedIdentityResource string = 'https://cognitiveservices.azure.com/'
param foundryModels array = []
@secure()
param toolServerConfigs object = {}

var aiGatewayApiVersion = '2025-09-01-preview'
var connectorGatewayApiVersion = '2026-05-01-preview'
var appInsightsApiVersion = '2020-02-02'
var logAnalyticsApiVersion = '2023-09-01'
var telemetryWorkspaceName = 'default'
var telemetryExporterName = 'appinsights'
var normalizedFoundryEndpoint = endsWith(foundryEndpoint, '/') ? foundryEndpoint : '${foundryEndpoint}/'
resource aiGateway 'Microsoft.ApiManagement/service@2025-09-01-preview' = if (deployApimGatewayViaBicep) {
  name: gatewayName
  location: gatewayLocation
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'AIGateway'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = if (deployApimGatewayViaBicep) {
  name: gatewayName
  location: gatewayLocation
  properties: {}
  dependsOn: [
    aiGateway
  ]
}

resource defaultWorkspace 'Microsoft.ApiManagement/service/workspaces@2025-09-01-preview' existing = if (deployApimGatewayViaBicep) {
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

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (enableMonitoring) {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource telemetryExporter 'Microsoft.ApiManagement/service/workspaces/telemetryExporters@2025-09-01-preview' = if (enableMonitoring && deployApimGatewayViaBicep) {
  parent: defaultWorkspace
  name: telemetryExporterName
  properties: {
    kind: 'applicationInsights'
    payloadCapture: false
    applicationInsights: {
      connectionString: appInsights!.properties.ConnectionString
      resourceId: appInsights!.id
    }
  }
}

resource foundryProvider 'Microsoft.ApiManagement/service/workspaces/modelProviders@2025-09-01-preview' = if (deployFoundryProvider && deployApimGatewayViaBicep) {
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

resource foundryCatalogModels 'Microsoft.ApiManagement/service/workspaces/modelProviders/models@2025-09-01-preview' = [for model in foundryModels: if (deployFoundryProvider && deployApimGatewayViaBicep) {
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
    policies: model.?policies ?? [
      {
        type: 'tokenLimit'
        period: 'minute'
        count: model.?tokenLimit ?? 10000
        counterKey: 'Identity'
      }
    ]
  }
}]

resource toolServers 'Microsoft.ApiManagement/service/workspaces/toolServers@2025-09-01-preview' = [for config in items(toolServerConfigs): if (deployApimGatewayViaBicep) {
  parent: defaultWorkspace
  name: config.key
  properties: config.value
}]

resource runtimeApiKey 'Microsoft.ApiManagement/service/apiKeys@2025-09-01-preview' = if (deployApimGatewayViaBicep) {
  parent: aiGateway
  name: 'default'
  properties: {
    displayName: 'Default hosted agent key'
  }
}

output apimGatewayId string = resourceId('Microsoft.ApiManagement/service', gatewayName)
output connectorNamespaceId string = deployApimGatewayViaBicep ? connectorNamespace.id : ''
output appInsightsId string = enableMonitoring ? appInsights.id : ''
output appInsightsName string = enableMonitoring ? appInsights.name : ''
output logAnalyticsWorkspaceId string = enableMonitoring ? logAnalyticsWorkspace.id : ''
output logAnalyticsWorkspaceName string = enableMonitoring ? logAnalyticsWorkspace.name : ''
output telemetryExporterId string = enableMonitoring && deployApimGatewayViaBicep ? telemetryExporter.id : ''
output runtimeHostname string = deployApimGatewayViaBicep ? replace(aiGateway!.properties.gatewayUrl, 'https://', '') : ''
output runtimeApiKeyId string = deployApimGatewayViaBicep ? runtimeApiKey.id : ''
output gatewayPrincipalId string = deployApimGatewayViaBicep ? aiGateway!.identity.principalId : ''
output foundryUserRoleAssignmentName string = deployFoundryProvider && deployApimGatewayViaBicep && !empty(foundryResourceIds) ? foundryUserRoleAssignments[0]!.outputs.roleAssignmentName : ''
output gatewayLocation string = gatewayLocation
output apiVersions object = {
  aiGateway: aiGatewayApiVersion
  connectorGateway: connectorGatewayApiVersion
  appInsights: appInsightsApiVersion
  logAnalytics: logAnalyticsApiVersion
}
