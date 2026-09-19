// =====================================================================
// AVD Landing Zone — orchestration
// Composes thin module wrappers (which in turn use Azure Verified Modules).
// This file is intentionally readable: each block is one non-negotiable.
// =====================================================================

targetScope = 'resourceGroup'

// ---------- Core ----------
@description('Short naming prefix, e.g. "avdlz". Resource names derive from this.')
@minLength(2)
@maxLength(10)
param namePrefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment tag, e.g. dev / test / prod.')
param environment string = 'dev'

@description('Resource ID of an EXISTING hub VNet to peer to. LEAVE EMPTY for a standalone demo on a personal subscription (no hub, default internet egress).')
param hubVnetResourceId string = ''

// ---------- Networking ----------
@description('Address space for the spoke VNet.')
param spokeAddressPrefix string = '10.20.0.0/24'

@description('Session host subnet prefix (must sit inside the spoke).')
param sessionHostSubnetPrefix string = '10.20.0.0/25'

@description('Private endpoint subnet prefix (must sit inside the spoke).')
param privateEndpointSubnetPrefix string = '10.20.0.128/26'

// ---------- Host pool ----------
@description('Number of session hosts to deploy.')
@minValue(1)
@maxValue(50)
param sessionHostCount int = 2

@description('VM size for session hosts. Check vCPU quota in your region first.')
param sessionHostVmSize string = 'Standard_D4as_v5'

@description('Object IDs (Entra ID) of users/groups to grant desktop access. They get Desktop Virtualization User on the app group, Virtual Machine User Login on the session hosts, and SMB access to the profile share.')
param desktopUserObjectIds array = []

@description('Principal type for desktopUserObjectIds. The standalone path grants to the signed-in USER; a real deployment normally uses a Group.')
@allowed(['User', 'Group', 'ServicePrincipal'])
param desktopUserPrincipalType string = 'Group'

@description('Object ID of the "Azure Virtual Desktop" service principal in YOUR tenant. Required for the scaling plan to actually start/stop hosts. The deploy script resolves this automatically; leave empty to skip.')
param avdServicePrincipalObjectId string = ''

// ---------- Cost control ----------
// Azure has no hard spending cap on pay-as-you-go. These bound the damage; they
// do not prevent it. See docs/cost-controls.md.

@description('Daily auto-shutdown for session hosts. The only cost control here with no data lag. Leave on unless you have a reason.')
param enableAutoShutdown bool = true

@description('Auto-shutdown time, HHmm 24-hour, in autoShutdownTimeZone.')
param autoShutdownTime string = '1900'

@description('Time zone for autoShutdownTime and the scaling plan.')
param autoShutdownTimeZone string = 'Eastern Standard Time'

@description('Deploy the budget, alerts and automated kill switch. Needs at least one address in costAlertEmails.')
param enableCostGuard bool = true

@description('Monthly budget for this resource group, in the subscription billing currency.')
@minValue(1)
param monthlyBudgetAmount int = 50

@description('Where budget alerts go. Leave empty and the deploy script uses the signed-in user. If it stays empty the cost guard is SKIPPED.')
param costAlertEmails array = []

@description('First day of the month the budget starts tracking. Azure requires the 1st.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Admin username for session host VMs.')
param adminUsername string

@description('Admin password for session host VMs.')
@secure()
param adminPassword string

// ---------- Derived names ----------
var tags = {
  environment: environment
  workload: 'avd-landing-zone'
  managedBy: 'bicep'
}
var vnetName = '${namePrefix}-spoke-vnet'
var storageName = toLower(replace('${namePrefix}stfslogix', '-', ''))
var hostPoolName = '${namePrefix}-hp'

// =====================================================================
// 1. NETWORKING  — the boundary everything else sits inside
// =====================================================================
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefix: spokeAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    hubVnetResourceId: hubVnetResourceId
  }
}

// =====================================================================
// 2. STORAGE  — FSLogix profile share, reachable over a private endpoint only
// =====================================================================
module storage 'modules/storage.bicep' = {
  name: 'deploy-storage'
  params: {
    name: storageName
    location: location
    tags: tags
    smbShareContributorObjectIds: desktopUserObjectIds
    smbSharePrincipalType: desktopUserPrincipalType
  }
}

// =====================================================================
// 3. PRIVATE ENDPOINTS + DNS  — keep storage traffic off the public internet
// =====================================================================
module privateEndpoints 'modules/privateEndpoints.bicep' = {
  name: 'deploy-private-endpoints'
  params: {
    location: location
    tags: tags
    storageAccountResourceId: storage.outputs.resourceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    vnetResourceId: network.outputs.vnetResourceId
  }
}

// =====================================================================
// 4. HOST POOL + SESSION HOSTS  — Entra ID joined (no domain services)
// =====================================================================
module hostPool 'modules/hostPool.bicep' = {
  name: 'deploy-host-pool'
  params: {
    name: hostPoolName
    location: location
    tags: tags
    sessionHostCount: sessionHostCount
    sessionHostVmSize: sessionHostVmSize
    sessionHostSubnetResourceId: network.outputs.sessionHostSubnetResourceId
    desktopUserObjectIds: desktopUserObjectIds
    desktopUserPrincipalType: desktopUserPrincipalType
    enableAutoShutdown: enableAutoShutdown
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

// =====================================================================
// 5. SCALING PLAN  — keep the bill sane
// =====================================================================
module scalingPlan 'modules/scalingPlan.bicep' = {
  name: 'deploy-scaling-plan'
  params: {
    name: '${namePrefix}-sp'
    location: location
    tags: tags
    hostPoolResourceId: hostPool.outputs.resourceId
  }
}

// =====================================================================
// 6. RBAC  — the cross-cutting assignments no single module owns
// =====================================================================
module rbac 'modules/rbac.bicep' = {
  name: 'deploy-rbac'
  params: {
    desktopUserObjectIds: desktopUserObjectIds
    desktopUserPrincipalType: desktopUserPrincipalType
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
  // The session hosts must exist before we grant sign-in rights over them.
  dependsOn: [hostPool]
}

// =====================================================================
// 7. COST GUARD  — budget, alerts, and the automated stop
// A BACKSTOP, not a cap: budget data lags real usage by 8-24 hours.
// =====================================================================
module costGuard 'modules/costGuard.bicep' = if (enableCostGuard && !empty(costAlertEmails)) {
  name: 'deploy-cost-guard'
  params: {
    location: location
    tags: tags
    namePrefix: namePrefix
    budgetAmount: monthlyBudgetAmount
    alertEmails: costAlertEmails
    budgetStartDate: budgetStartDate
    scalingPlanResourceId: scalingPlan.outputs.resourceId
    hostPoolResourceId: hostPool.outputs.resourceId
  }
}

// ---------- Outputs ----------
output spokeVnetResourceId string = network.outputs.vnetResourceId
output storageAccountName string = storage.outputs.name
output hostPoolName string = hostPool.outputs.name
output workspaceResourceId string = hostPool.outputs.workspaceResourceId
