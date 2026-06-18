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

@description('Object IDs (Entra ID) of users/groups to grant Desktop Virtualization User on the app group.')
param desktopUserObjectIds array = []

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

// ---------- Outputs ----------
output spokeVnetResourceId string = network.outputs.vnetResourceId
output storageAccountName string = storage.outputs.name
output hostPoolName string = hostPool.outputs.name
output workspaceResourceId string = hostPool.outputs.workspaceResourceId
