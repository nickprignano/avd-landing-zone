// Dev: smallest footprint that still exercises every control.
// Tenant-specific values come from environment variables (see docs/deploy.md),
// so this file is safe to commit. deploy.sh sets them for you.

using '../bicep/main.bicep'

param namePrefix = 'avdlz'
param environmentName = 'dev'
param location = 'eastus2'

// ---- Identity (Entra ID) ----
param avdUsersGroupObjectId = readEnvironmentVariable('AVD_USERS_GROUP_ID')
param avdAdminsGroupObjectId = readEnvironmentVariable('AVD_ADMINS_GROUP_ID')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_ID')
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---- Connectivity ----
param connectivityMode = 'Standalone'

// ---- Session hosts ----
param sessionHostCount = 1
param sessionHostVmSize = 'Standard_D4as_v5'

// ---- Profiles ----
param profileStorageSku = 'Premium_LRS'
param profileShareQuotaGiB = 100
param enableProfileBackup = false

// ---- Operations & governance ----
param logRetentionDays = 30
param enableDefenderForCloud = false
param alertEmailAddresses = empty(readEnvironmentVariable('AVD_ALERT_EMAIL', ''))
  ? []
  : [readEnvironmentVariable('AVD_ALERT_EMAIL', '')]
