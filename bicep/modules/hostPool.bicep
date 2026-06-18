// Host pool + session hosts — Entra ID joined (no domain services).
// Composes AVM host-pool, application-group, workspace, and VM modules.
// Imaging is intentionally a marketplace image — golden imaging is out of scope.

param name string
param location string
param tags object
param sessionHostCount int
param sessionHostVmSize string
param sessionHostSubnetResourceId string
param desktopUserObjectIds array
param adminUsername string
@secure()
param adminPassword string

@description('Marketplace image for session hosts. Replace with your golden image in a real build.')
param imageReference object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-23h2-avd'
  version: 'latest'
}

// --- Host pool ---
module hostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.6.0' = {
  name: 'deploy-hostpool'
  params: {
    name: name
    location: location
    tags: tags
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: 8
    // Tokens for session host registration are generated; the config script consumes them.
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1'   // Entra ID auth
  }
}

// --- Application group ---
module appGroup 'br/public:avm/res/desktop-virtualization/application-group:0.4.0' = {
  name: 'deploy-appgroup'
  params: {
    name: '${name}-dag'
    location: location
    tags: tags
    applicationGroupType: 'Desktop'
    hostpoolResourceId: hostPool.outputs.resourceId
    // Grant Desktop Virtualization User to the supplied object IDs.
    roleAssignments: [for id in desktopUserObjectIds: {
      principalId: id
      roleDefinitionIdOrName: 'Desktop Virtualization User'
      principalType: 'Group'
    }]
  }
}

// --- Workspace ---
module workspace 'br/public:avm/res/desktop-virtualization/workspace:0.10.0' = {
  name: 'deploy-workspace'
  params: {
    name: '${name}-ws'
    location: location
    tags: tags
    applicationGroupResourceIds: [appGroup.outputs.resourceId]
  }
}

// --- Session host VMs (Entra ID joined via the AADLoginForWindows extension) ---
module sessionHosts 'br/public:avm/res/compute/virtual-machine:0.12.0' = [for i in range(0, sessionHostCount): {
  name: 'deploy-sh-${i}'
  params: {
    name: '${name}-sh-${i}'
    location: location
    tags: tags
    vmSize: sessionHostVmSize
    osType: 'Windows'
    adminUsername: adminUsername
    adminPassword: adminPassword
    imageReference: imageReference
    osDisk: {
      managedDisk: { storageAccountType: 'Premium_LRS' }
    }
    nicConfigurations: [
      {
        ipConfigurations: [
          { name: 'ipconfig1', subnetResourceId: sessionHostSubnetResourceId }
        ]
      }
    ]
    // Entra ID join — this is the no-domain-services path.
    extensionAadJoinConfig: {
      enabled: true
    }
  }
}]

output resourceId string = hostPool.outputs.resourceId
output name string = hostPool.outputs.name
output workspaceResourceId string = workspace.outputs.resourceId
