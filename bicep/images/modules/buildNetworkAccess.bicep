// Golden image pipeline: Azure Image Builder may join the two build subnets, nothing more.

param vnetName string
param aibPrincipalId string
param buildNetworkRoleId string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource buildSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-image-build'
}

resource aciSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-image-aci'
}

resource joinBuildSubnet 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(buildSubnet.id, aibPrincipalId, buildNetworkRoleId)
  scope: buildSubnet
  properties: {
    principalId: aibPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: buildNetworkRoleId
  }
}

resource joinAciSubnet 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aciSubnet.id, aibPrincipalId, buildNetworkRoleId)
  scope: aciSubnet
  properties: {
    principalId: aibPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: buildNetworkRoleId
  }
}

output buildSubnetId string = buildSubnet.id
output aciSubnetId string = aciSubnet.id
