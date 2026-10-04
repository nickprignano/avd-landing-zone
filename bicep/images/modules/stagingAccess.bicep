// Golden image pipeline: access to Azure Image Builder's staging resource group.

param aibPrincipalId string
param buildPrincipalId string
param contributorRoleId string
param storageBlobDataReaderRoleId string

resource aibContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aibPrincipalId, contributorRoleId)
  properties: {
    principalId: aibPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}

// The workflow saves AIB's customization log from the staging storage account.
resource buildLogReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, buildPrincipalId, storageBlobDataReaderRoleId)
  properties: {
    principalId: buildPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}
