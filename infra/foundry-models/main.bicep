targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}
param aiServicesName string
param principalId string = ''
param modelDeployments array

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
    allowProjectManagement: false
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

@batchSize(1)
resource modelDeploymentResources 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = [for deployment in modelDeployments: {
  parent: aiServices
  name: deployment.deploymentName
  sku: {
    capacity: deployment.capacity
    name: deployment.skuName
  }
  properties: {
    model: union({
      name: deployment.modelName
      format: deployment.modelFormat
    }, !empty(deployment.modelVersion) ? { version: deployment.modelVersion } : {})
  }
}]

var cognitiveServicesContributorRoleDefinitionId = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
var cognitiveServicesOpenAIUserRoleDefinitionId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesUserRoleDefinitionId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

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

output aiServicesName string = aiServices.name
output aiServicesId string = aiServices.id
output aiServicesEndpoint string = aiServices.properties.endpoint
output modelDeploymentNames array = [for deployment in modelDeployments: deployment.deploymentName]
output modelDeploymentIds array = [for (deployment, i) in modelDeployments: modelDeploymentResources[i].id]
