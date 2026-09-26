// Profile backup — Recovery Services vault protecting the FSLogix share with
// daily snapshot backups.
//
// Note: registering a storage account with Azure Backup places a delete lock
// (AzureBackupProtectionLock) on it. Stop protection before tearing down.

param location string
param tags object
param vaultName string
param storageAccountResourceId string
param shareName string
param retentionDays int
param logAnalyticsWorkspaceResourceId string

var storageAccountName = last(split(storageAccountResourceId, '/'))
var backupTime = '2025-01-01T02:00:00Z'

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    securitySettings: {
      softDeleteSettings: {
        softDeleteState: 'Enabled'
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: 'fslogix-daily'
  properties: {
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    timeZone: 'UTC'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        backupTime
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          backupTime
        ]
        retentionDuration: {
          count: retentionDays
          durationType: 'Days'
        }
      }
    }
  }
}

// The 'Azure' backup fabric is built in to every vault and is not a deployable
// type, so the container is addressed by its full name rather than via parent.
#disable-next-line use-parent-property
resource container 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = {
  name: '${vault.name}/Azure/storagecontainer;Storage;${resourceGroup().name};${storageAccountName}'
  properties: {
    backupManagementType: 'AzureStorage'
    containerType: 'StorageContainer'
    sourceResourceId: storageAccountResourceId
  }
}

resource protectedShare 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = {
  parent: container
  name: 'AzureFileShare;${shareName}'
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: storageAccountResourceId
    policyId: policy.id
  }
}

resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output vaultResourceId string = vault.id
