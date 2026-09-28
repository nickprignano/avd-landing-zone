// Prod: zone-redundant, backed up, Defender on, budget set.
// Tenant-specific values come from environment variables (see docs/deploy.md).

using '../bicep/main.bicep'

param namePrefix = 'avdlz'
param environmentName = 'prod'
// Default region; deploy.sh -l and the preflight's -Location override it (AVD_LOCATION).
param location = empty(readEnvironmentVariable('AVD_LOCATION', ''))
  ? 'northcentralus'
  : readEnvironmentVariable('AVD_LOCATION', '')

// ---- Identity (Entra ID) ----
param avdUsersGroupObjectId = readEnvironmentVariable('AVD_USERS_GROUP_ID')
param avdAdminsGroupObjectId = readEnvironmentVariable('AVD_ADMINS_GROUP_ID')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_ID')
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---- Connectivity ----
// Standalone by default. To join an existing hub instead:
//   param connectivityMode = 'HubPeered'
//   param hubVnetResourceId = '/subscriptions/<hub-sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<hub>'
//   param hubFirewallPrivateIp = '10.0.0.4'
//   param dnsServers = ['10.0.0.4']
//   param centralPrivateDnsZoneResourceIds = { file: '...', keyVault: '...', avd: '...' }
param connectivityMode = 'Standalone'
param spokeAddressPrefix = '10.100.0.0/22'
param sessionHostSubnetPrefix = '10.100.0.0/23'
param privateEndpointSubnetPrefix = '10.100.2.0/27'

// ---- Session hosts ----
param sessionHostCount = 4
param sessionHostVmSize = 'Standard_D4as_v5'
// Regional hosts work in every region (North Central US has no zones) and profiles
// use locally redundant storage. For zone redundancy, use a zonal region (e.g.
// centralus) with availabilityZones = [1, 2, 3] and profileStorageSku = 'Premium_ZRS'.
param availabilityZones = []
param maxSessionLimit = 8

// ---- Profiles ----
param profileStorageSku = 'Premium_LRS'
param profileShareQuotaGiB = 1024
param enableProfileBackup = true
param profileBackupRetentionDays = 30

// ---- Scaling ----
param scalingTimeZone = 'Central Standard Time'

// ---- Operations & governance ----
param logRetentionDays = 90
param enableDefenderForCloud = true
param enablePolicyGuardrails = true
param alertEmailAddresses = empty(readEnvironmentVariable('AVD_ALERT_EMAIL', ''))
  ? []
  : [readEnvironmentVariable('AVD_ALERT_EMAIL', '')]
param monthlyBudgetAmount = int(readEnvironmentVariable('AVD_MONTHLY_BUDGET', '0'))
param budgetStartDate = '2026-10-01'
