// RBAC — the role assignments an Entra-ID-joined AVD deployment needs but that
// no single resource module owns, because they apply across the resource group.
//
// Two of them, both easy to miss and both silent when absent:
//
//   1. Virtual Machine User Login — an Entra-joined session host is a VM you
//      sign in to with an Entra identity. "Desktop Virtualization User" on the
//      app group only gets the desktop to appear in the client; without this
//      role the connection is accepted and then the sign-in fails.
//
//   2. Desktop Virtualization Power On Off Contributor — the scaling plan runs
//      as the Azure Virtual Desktop service principal. Without this, the plan
//      deploys clean, reports healthy, and never starts or stops a host.
//
// Assigned at resource group scope so they cover every session host in the
// deployment, including ones added later by raising sessionHostCount.
// Microsoft documents the power on/off role at SUBSCRIPTION scope; this
// template is resource-group scoped, so if you run more than one host pool
// across a subscription, hoist that assignment up yourself.

targetScope = 'resourceGroup'

@description('Object IDs (Entra ID) of the users/groups that will sign in to session hosts.')
param desktopUserObjectIds array = []

@description('Principal type for desktopUserObjectIds.')
@allowed(['User', 'Group', 'ServicePrincipal'])
param desktopUserPrincipalType string = 'Group'

@description('Object ID of the "Azure Virtual Desktop" service principal in YOUR tenant (app ID 9cdead84-a844-4324-93f2-b2e6bb768d07). Empty = skip the scaling-plan role assignment. The deploy script resolves this for you.')
param avdServicePrincipalObjectId string = ''

// Built-in role definition IDs. Pinned as GUIDs rather than display names so
// they cannot be silently re-resolved.
var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'          // Virtual Machine User Login
var powerOnOffRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'           // Desktop Virtualization Power On Off Contributor

resource vmUserLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for id in desktopUserObjectIds: {
  name: guid(resourceGroup().id, id, vmUserLoginRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
    principalId: id
    principalType: desktopUserPrincipalType
  }
}]

resource scalingPlanPowerOnOff 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdServicePrincipalObjectId)) {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, powerOnOffRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnOffRoleId)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}
