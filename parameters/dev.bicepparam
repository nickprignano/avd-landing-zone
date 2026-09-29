// Dev: smallest footprint that still exercises every control.
// Tenant-specific values come from environment variables (see docs/deploy.md),
// so this file is safe to commit. deploy.sh sets them for you.

using '../bicep/main.bicep'

param namePrefix = 'avdlz'
param environmentName = 'dev'
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
param connectivityMode = 'Standalone'

// ---- Session hosts ----
// Regional hosts (no zones) work in every region, including those without
// availability zones such as North Central US.
param availabilityZones = []
// Sizing: the deployment portal's sizing step, deploy.sh (--hosts, --vm-size, --max-sessions,
// --profile-quota) and the pre-deployment preflight override these through AVD_SESSION_HOST_COUNT,
// AVD_SESSION_HOST_VM_SIZE, AVD_MAX_SESSION_LIMIT and AVD_PROFILE_QUOTA_GIB (empty = the value here).
param sessionHostCount = empty(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', '')) ? 1 : int(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', ''))
param sessionHostVmSize = empty(readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')) ? 'Standard_E4as_v5' : readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')
param maxSessionLimit = empty(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', '')) ? 8 : int(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', ''))

// ---- Profiles ----
param profileStorageSku = 'Premium_LRS'
param profileShareQuotaGiB = empty(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', '')) ? 100 : int(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', ''))
param enableProfileBackup = false

// ---- Operations & governance ----
param logRetentionDays = 30
param enableDefenderForCloud = false
param alertEmailAddresses = empty(readEnvironmentVariable('AVD_ALERT_EMAIL', ''))
  ? []
  : [readEnvironmentVariable('AVD_ALERT_EMAIL', '')]
