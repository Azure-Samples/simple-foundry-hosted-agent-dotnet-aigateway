targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}
param aiServicesName string
param aiProjectName string
param aiProjectFriendlyName string = aiProjectName
param aiProjectDescription string
param storageName string
param containerRegistryName string
param appInsightsName string
param logAnalyticsWorkspaceName string
param principalId string = ''

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiServicesName
  location: location
  tags: tags
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: toLower(aiServicesName)
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: []
    }
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
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

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    IngestionMode: 'LogAnalytics'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsightsConnection 'Microsoft.CognitiveServices/accounts/connections@2025-06-01' = {
  parent: aiServices
  name: appInsights.name
  properties: {
    category: 'AppInsights'
    authType: 'ApiKey'
    isSharedToAll: false
    target: appInsights.id
    credentials: {
      key: appInsights.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
      displayName: appInsights.name
    }
  }
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: aiServices
  name: aiProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: aiProjectDescription
    displayName: aiProjectFriendlyName
  }

  resource projectStorageConnection 'connections@2025-04-01-preview' = {
    name: storage.name
    properties: {
      category: 'AzureStorageAccount'
      target: storage.properties.primaryEndpoints.blob
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: storage.id
        location: storage.location
      }
    }
  }

  resource projectContainerRegistryConnection 'connections@2025-04-01-preview' = {
    name: '${containerRegistry.name}-conn'
    properties: {
      category: 'ContainerRegistry'
      target: containerRegistry.properties.loginServer
      authType: 'ManagedIdentity'
      credentials: {
        clientId: aiProject.identity.principalId
        resourceId: containerRegistry.id
      }
      isSharedToAll: true
      metadata: {
        ResourceId: containerRegistry.id
      }
    }
    dependsOn: [
      containerRegistryPullAssignmentProject
    ]
  }
}

var cognitiveServicesContributorRoleDefinitionId = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
var cognitiveServicesOpenAIUserRoleDefinitionId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesUserRoleDefinitionId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var storageBlobDataContributorRoleDefinitionId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource cognitiveServicesContributorAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesContributorRoleDefinitionId, aiProject.id)
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesContributorRoleDefinitionId)
  }
}

resource cognitiveServicesOpenAIUserAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesOpenAIUserRoleDefinitionId, aiProject.id)
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleDefinitionId)
  }
}

resource cognitiveServicesUserAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesUserRoleDefinitionId, aiProject.id)
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleDefinitionId)
  }
}

resource storageBlobDataContributorAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, storageBlobDataContributorRoleDefinitionId, aiProject.id)
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefinitionId)
  }
}

resource containerRegistryPullAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: containerRegistry
  name: guid(containerRegistry.id, aiProject.id, acrPullRoleDefinitionId)
  properties: {
    principalId: aiProject.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
  }
}

resource cognitiveServicesContributorAssignmentUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesContributorRoleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesContributorRoleDefinitionId)
  }
}

resource cognitiveServicesOpenAIUserAssignmentUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesOpenAIUserRoleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleDefinitionId)
  }
}

resource cognitiveServicesUserAssignmentUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiServices
  name: guid(aiServices.id, cognitiveServicesUserRoleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleDefinitionId)
  }
}

resource storageBlobDataContributorAssignmentUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: storage
  name: guid(storage.id, storageBlobDataContributorRoleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefinitionId)
  }
}

output aiServicesName string = aiServices.name
output aiServicesId string = aiServices.id
output aiServicesEndpoint string = aiServices.properties.endpoint
output aiProjectName string = aiProject.name
output aiProjectResourceId string = aiProject.id
output aiProjectPrincipalId string = aiProject.identity.principalId
output projectEndpoint string = 'https://${aiServices.name}.services.ai.azure.com/api/projects/${aiProject.name}'
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output containerRegistryName string = containerRegistry.name
output containerRegistryEndpoint string = containerRegistry.properties.loginServer
output containerRegistryId string = containerRegistry.id
output containerRegistryConnectionName string = aiProject::projectContainerRegistryConnection.name
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output appInsightsConnectionName string = appInsightsConnection.name
