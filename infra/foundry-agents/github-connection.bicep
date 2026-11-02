targetScope = 'resourceGroup'

param aiServicesName string
param aiProjectName string
param gatewayUrl string
param useManagedIdentity bool = true
param gatewayAudience string = 'https://azure-api.net/aigateway'
@secure()
param gatewayApiKey string = ''

var normalizedGatewayUrl = endsWith(gatewayUrl, '/') ? take(gatewayUrl, length(gatewayUrl) - 1) : gatewayUrl

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiServicesName
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: aiServices
  name: aiProjectName
}

resource githubConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: aiProject
  name: 'aigw-github'
  #disable-next-line BCP036
  properties: useManagedIdentity ? {
    category: 'RemoteTool'
    authType: 'ProjectManagedIdentity'
    audience: gatewayAudience
    target: '${normalizedGatewayUrl}/default/toolservers/github/mcp'
    isSharedToAll: true
    metadata: {
      type: 'custom_MCP'
    }
  } : {
    category: 'RemoteTool'
    authType: 'CustomKeys'
    target: '${normalizedGatewayUrl}/default/toolservers/github/mcp'
    credentials: {
      keys: {
        'Api-Key': gatewayApiKey
      }
    }
    isSharedToAll: true
    metadata: {
      type: 'custom_MCP'
    }
  }
}
