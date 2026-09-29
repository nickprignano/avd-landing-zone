// Roles for the auto-shutdown runbook's managed identity in one resource group (decision 0011).
param principalId string

@description('Built-in role definition IDs to assign on this resource group.')
param roleDefinitionIds string[]

resource assignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in roleDefinitionIds: {
    name: guid(resourceGroup().id, principalId, roleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]
