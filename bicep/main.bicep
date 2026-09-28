// =====================================================================
// Cloud-native AVD Landing Zone — orchestration
//
// One opinionated path: Entra ID-joined, Intune-enrolled session hosts,
// Entra Kerberos for FSLogix, private-by-default PaaS, and everything —
// including session host registration and FSLogix config — declared here.
// No domain controllers, no post-deploy scripts, no runtime downloads from
// GitHub. See docs/design-decisions.md for how this differs from the
// Microsoft AVD Landing Zone Accelerator.
//
// Deployed at SUBSCRIPTION scope into a dedicated AVD landing zone
// subscription (subscription-vending model).
// =====================================================================

targetScope = 'subscription'

metadata name = 'Cloud-native AVD landing zone'
metadata description = 'Entra ID-only, Intune-managed, private-by-default Azure Virtual Desktop landing zone for greenfield deployments.'

// ---------- Core ----------
@description('Short workload prefix (lowercase letters/digits, 2-8 chars). Resource names derive from this.')
@minLength(2)
@maxLength(8)
param namePrefix string

@description('Environment. Drives naming and a few safe-by-default toggles.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

@description('Azure region for all regional resources.')
param location string = deployment().location

@description('Extra tags merged onto every resource group and resource.')
param tags object = {}

// ---------- Identity (Entra ID) ----------
@description('Object ID of the Entra ID security group whose members get the desktop (Desktop Virtualization User, VM User Login, SMB Share Contributor).')
param avdUsersGroupObjectId string

@description('Object ID of the Entra ID security group of AVD operators (VM Administrator Login, SMB Share Elevated Contributor, Key Vault Secrets User).')
param avdAdminsGroupObjectId string

@description('Object ID of the Azure Virtual Desktop service principal in this tenant (app ID 9cdead84-a844-4324-93f2-b2e6bb768d07). Needed for autoscale and Start VM on Connect. deploy.sh looks it up for you.')
param avdServicePrincipalObjectId string

@description('Enroll session hosts in Microsoft Intune as part of the Entra join.')
param enrollInIntune bool = true

// ---------- Connectivity ----------
@description('Standalone = self-contained spoke with NAT Gateway egress and local private DNS zones. HubPeered = peer to an existing hub, force egress through its firewall, use its DNS.')
@allowed([
  'Standalone'
  'HubPeered'
])
param connectivityMode string = 'Standalone'

@description('Address space for the AVD spoke VNet.')
param spokeAddressPrefix string = '10.100.0.0/22'

@description('Session host subnet (inside the spoke). /23 = ~500 hosts.')
param sessionHostSubnetPrefix string = '10.100.0.0/23'

@description('Private endpoint subnet (inside the spoke).')
param privateEndpointSubnetPrefix string = '10.100.2.0/27'

@description('HubPeered only: resource ID of the hub VNet.')
param hubVnetResourceId string = ''

@description('HubPeered only: create the hub-to-spoke side of the peering too. Requires Network Contributor on the hub VNet for the deploying identity.')
param createHubToSpokePeering bool = true

@description('HubPeered only: private IP of the hub firewall/NVA. 0.0.0.0/0 from the session host subnet is routed here.')
param hubFirewallPrivateIp string = ''

@description('Custom DNS servers for the spoke (e.g. hub firewall DNS proxy or Private DNS Resolver inbound IP). Empty = Azure-provided DNS.')
param dnsServers array = []

@description('Resource IDs of EXISTING, centrally managed private DNS zones: { file: \'...\', keyVault: \'...\', avd: \'...\' }. Leave empty to create zones locally and link them to the spoke (Standalone).')
param centralPrivateDnsZoneResourceIds object = {}

@description('Use Private Link for the AVD host pool connection (session hosts reach the AVD service privately; clients still connect over the internet).')
param enableAvdPrivateLink bool = true

// ---------- Session hosts ----------
@description('Number of session hosts.')
@minValue(0)
@maxValue(200)
param sessionHostCount int = 2

@description('Session host VM size. Check vCPU quota and zonal availability first.')
param sessionHostVmSize string = 'Standard_D4as_v5'

@description('Session host name prefix (max 11 chars; a 3-digit index is appended to stay within the 15-char Windows limit).')
@maxLength(11)
param sessionHostNamePrefix string = take('${toLower(replace(namePrefix, '-', ''))}${take(environmentName, 1)}sh', 11)

@description('Availability zones to spread session hosts across. Empty array = regional (no zones).')
param availabilityZones int[] = [
  1
  2
  3
]

@description('Marketplace image for session hosts. Replace with an Azure Compute Gallery image when you have an image pipeline.')
param sessionHostImage object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}

@description('Maximum sessions per host (breadth-first). Size to your workload.')
param maxSessionLimit int = 8

@description('Enable encryption at host. Requires the Microsoft.Compute/EncryptionAtHost feature on the subscription (deploy.sh registers it).')
param encryptionAtHost bool = true

@description('Break-glass local administrator name. Day-to-day admin access is via Entra ID (VM Administrator Login).')
param localAdminUsername string = 'avdbreakglass'

@description('Break-glass local administrator password, applied when a host is created and stored in Key Vault. deploy.sh generates a random one unless AVD_LOCAL_ADMIN_PASSWORD is set; never commit it.')
@secure()
@minLength(14)
param localAdminPassword string

@description('RDP properties for the host pool. Defaults: Entra SSO on; drive, COM and USB redirection off.')
param rdpProperties string = 'enablerdsaadauth:i:1;targetisaadjoined:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:1;redirectprinters:i:1;redirectclipboard:i:1;redirectwebauthn:i:1;audiomode:i:0;audiocapturemode:i:1;camerastoredirect:s:*;use multimon:i:1'

@description('Mark the host pool as a validation pool (gets AVD service updates first). Recommended for non-prod.')
param validationEnvironment bool = environmentName != 'prod'

// ---------- Profiles (FSLogix on Azure Files) ----------
@description('Premium Azure Files redundancy. ZRS where the region supports it.')
@allowed([
  'Premium_LRS'
  'Premium_ZRS'
])
param profileStorageSku string = 'Premium_ZRS'

@description('Provisioned size of the profile share in GiB. On Premium, IOPS and throughput scale with this number.')
@minValue(100)
param profileShareQuotaGiB int = 1024

@description('Maximum size of each FSLogix profile container in MiB.')
param fslogixProfileSizeMiB int = 30720

@description('Back up the profile share with Azure Backup.')
param enableProfileBackup bool = true

@description('Daily backup retention for the profile share, in days.')
param profileBackupRetentionDays int = 30

// ---------- Scaling ----------
@description('Time zone for the autoscale schedule (Windows time zone ID).')
param scalingTimeZone string = 'UTC'

// ---------- Operations & governance ----------
@description('Log Analytics retention in days.')
param logRetentionDays int = 90

@description('Email addresses for alerts and budget notifications.')
param alertEmailAddresses string[] = []

@description('Monthly budget for the subscription in billing currency. 0 = no budget.')
param monthlyBudgetAmount int = 0

@description('Budget start date (first of a month, yyyy-MM-01). Required when monthlyBudgetAmount > 0. Keep it fixed across deployments.')
param budgetStartDate string = ''

@description('Enable Microsoft Defender for Cloud plans (Servers P2, Storage, Key Vault) on the subscription.')
param enableDefenderForCloud bool = true

@description('Assign the landing zone\'s Azure Policy guardrails (allowed locations, tag inheritance) to the subscription.')
param enablePolicyGuardrails bool = true

@description('Allowed regions for resources and resource groups when policy guardrails are on.')
param allowedLocations string[] = [
  location
]

// =====================================================================
// Derived values
// =====================================================================
var cleanPrefix = toLower(replace(namePrefix, '-', ''))
var baseName = '${cleanPrefix}-${environmentName}'
var uniq = uniqueString(subscription().id, cleanPrefix, environmentName, location)

var allTags = union(
  {
    workload: 'avd'
    environment: environmentName
    managedBy: 'bicep'
    landingZone: 'avd-cloud-native'
  },
  tags
)

var names = {
  rgNetwork: 'rg-${baseName}-network'
  rgManagement: 'rg-${baseName}-management'
  rgStorage: 'rg-${baseName}-storage'
  rgControlPlane: 'rg-${baseName}-avd'
  rgHosts: 'rg-${baseName}-hosts'
  vnet: 'vnet-${baseName}'
  logAnalytics: 'log-${baseName}'
  keyVault: take('kv${cleanPrefix}${environmentName}${uniq}', 24)
  storage: take('st${cleanPrefix}${environmentName}${uniq}', 24)
  recoveryVault: 'rsv-${baseName}'
  hostPool: 'vdpool-${baseName}'
  appGroup: 'vdag-${baseName}-desktop'
  workspace: 'vdws-${baseName}'
  scalingPlan: 'vdscaling-${baseName}'
}

var profileShareName = 'profiles'
var useCentralDns = !empty(centralPrivateDnsZoneResourceIds)

// =====================================================================
// 0. RESOURCE GROUPS — one per lifecycle
// =====================================================================
resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgNetwork
  location: location
  tags: allTags
}

resource rgManagement 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgManagement
  location: location
  tags: allTags
}

resource rgStorage 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgStorage
  location: location
  tags: allTags
}

resource rgControlPlane 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgControlPlane
  location: location
  tags: allTags
}

resource rgHosts 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgHosts
  location: location
  tags: allTags
}

// =====================================================================
// 1. GOVERNANCE — policy guardrails, Defender, budget, activity log
// =====================================================================
// Subscription-scope deployment names must be unique per subscription+region.
module governance 'modules/governance.bicep' = {
  name: take('avdlz-governance-${baseName}-${location}', 64)
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    enablePolicyGuardrails: enablePolicyGuardrails
    allowedLocations: allowedLocations
    enableDefenderForCloud: enableDefenderForCloud
    monthlyBudgetAmount: monthlyBudgetAmount
    budgetStartDate: budgetStartDate
    alertEmailAddresses: alertEmailAddresses
  }
}

// =====================================================================
// 2. MONITORING — Log Analytics, AVD Insights DCR, alerts
// =====================================================================
module monitoring 'modules/monitoring.bicep' = {
  name: 'avdlz-monitoring'
  scope: rgManagement
  params: {
    location: location
    tags: allTags
    baseName: baseName
    logAnalyticsName: names.logAnalytics
    retentionInDays: logRetentionDays
    alertEmailAddresses: alertEmailAddresses
  }
}

// =====================================================================
// 3. NETWORK — spoke, NSGs, explicit egress (NAT Gateway or hub firewall)
// =====================================================================
module network 'modules/network.bicep' = {
  name: 'avdlz-network'
  scope: rgNetwork
  params: {
    location: location
    tags: allTags
    vnetName: names.vnet
    addressPrefix: spokeAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    connectivityMode: connectivityMode
    hubVnetResourceId: hubVnetResourceId
    createHubToSpokePeering: createHubToSpokePeering
    hubFirewallPrivateIp: hubFirewallPrivateIp
    dnsServers: dnsServers
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    availabilityZones: availabilityZones
  }
}

module privateDns 'modules/privateDns.bicep' = if (!useCentralDns) {
  name: 'avdlz-private-dns'
  scope: rgNetwork
  params: {
    tags: allTags
    vnetResourceId: network.outputs.vnetResourceId
  }
}

var dnsZoneIds = {
  file: useCentralDns ? centralPrivateDnsZoneResourceIds.file : privateDns!.outputs.fileZoneResourceId
  keyVault: useCentralDns ? centralPrivateDnsZoneResourceIds.keyVault : privateDns!.outputs.keyVaultZoneResourceId
  avd: useCentralDns ? (centralPrivateDnsZoneResourceIds.?avd ?? '') : privateDns!.outputs.avdZoneResourceId
}

// =====================================================================
// 4. KEY VAULT — break-glass credential, private only
// =====================================================================
module keyVault 'modules/keyVault.bicep' = {
  name: 'avdlz-keyvault'
  scope: rgManagement
  params: {
    location: location
    tags: allTags
    name: names.keyVault
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: dnsZoneIds.keyVault
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    adminsGroupObjectId: avdAdminsGroupObjectId
    localAdminUsername: localAdminUsername
    localAdminPassword: localAdminPassword
  }
}

// =====================================================================
// 5. PROFILE STORAGE — Premium Azure Files, Entra Kerberos, private only
// =====================================================================
module storage 'modules/storage.bicep' = {
  name: 'avdlz-storage'
  scope: rgStorage
  params: {
    location: location
    tags: allTags
    name: names.storage
    skuName: profileStorageSku
    shareName: profileShareName
    shareQuotaGiB: profileShareQuotaGiB
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: dnsZoneIds.file
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    usersGroupObjectId: avdUsersGroupObjectId
    adminsGroupObjectId: avdAdminsGroupObjectId
  }
}

module backup 'modules/backup.bicep' = if (enableProfileBackup) {
  name: 'avdlz-backup'
  scope: rgStorage
  params: {
    location: location
    tags: allTags
    vaultName: names.recoveryVault
    storageAccountResourceId: storage.outputs.resourceId
    shareName: profileShareName
    retentionDays: profileBackupRetentionDays
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
  }
}

// =====================================================================
// 6. AVD CONTROL PLANE — host pool, app group, workspace, autoscale
// =====================================================================
module controlPlane 'modules/controlPlane.bicep' = {
  name: 'avdlz-control-plane'
  scope: rgControlPlane
  params: {
    location: location
    tags: allTags
    hostPoolName: names.hostPool
    appGroupName: names.appGroup
    workspaceName: names.workspace
    scalingPlanName: names.scalingPlan
    maxSessionLimit: maxSessionLimit
    rdpProperties: rdpProperties
    validationEnvironment: validationEnvironment
    enableAvdPrivateLink: enableAvdPrivateLink
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: dnsZoneIds.avd
    scalingTimeZone: scalingTimeZone
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    usersGroupObjectId: avdUsersGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// =====================================================================
// 7. SESSION HOSTS — Entra joined, Intune enrolled, Trusted Launch,
//    registered to the host pool and FSLogix-configured declaratively
// =====================================================================
module sessionHosts 'modules/sessionHosts.bicep' = {
  name: 'avdlz-session-hosts'
  scope: rgHosts
  params: {
    location: location
    tags: allTags
    count: sessionHostCount
    namePrefix: sessionHostNamePrefix
    vmSize: sessionHostVmSize
    availabilityZones: availabilityZones
    imageReference: sessionHostImage
    encryptionAtHost: encryptionAtHost
    subnetResourceId: network.outputs.sessionHostSubnetResourceId
    enrollInIntune: enrollInIntune
    localAdminUsername: localAdminUsername
    localAdminPassword: localAdminPassword
    hostPoolRegistrationToken: controlPlane.outputs.registrationToken
    dataCollectionRuleResourceId: monitoring.outputs.avdInsightsDataCollectionRuleResourceId
    profileShareUncPath: storage.outputs.profileShareUncPath
    fslogixProfileSizeMiB: fslogixProfileSizeMiB
    usersGroupObjectId: avdUsersGroupObjectId
    adminsGroupObjectId: avdAdminsGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// ---------- Outputs ----------
output resourceGroups object = {
  network: rgNetwork.name
  management: rgManagement.name
  storage: rgStorage.name
  controlPlane: rgControlPlane.name
  hosts: rgHosts.name
}
output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output workspaceResourceId string = controlPlane.outputs.workspaceResourceId
output storageAccountName string = storage.outputs.name
output storageAccountResourceId string = storage.outputs.resourceId
output keyVaultName string = keyVault.outputs.name
output logAnalyticsWorkspaceResourceId string = monitoring.outputs.logAnalyticsWorkspaceResourceId
output sessionHostNames string[] = sessionHosts.outputs.names
