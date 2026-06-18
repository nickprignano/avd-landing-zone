// Storage — Azure Files share for FSLogix profiles.
// Public network access disabled; reached only via the private endpoint
// created in privateEndpoints.bicep. Wraps the AVM storage-account module.

@description('Storage account name (3-24 lowercase alphanumeric).')
param name string
param location string
param tags object

@description('Name of the file share for FSLogix profiles.')
param profileShareName string = 'profiles'

@description('Quota for the profile share, in GB.')
param shareQuotaGb int = 100

module storageAccount 'br/public:avm/res/storage/storage-account:0.14.3' = {
  name: 'deploy-storage-account'
  params: {
    name: name
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Premium_LRS'      // Premium FileStorage for FSLogix IOPS; sizing is YOUR call (see docs)
    largeFileSharesState: 'Enabled'
    // Lock the front door: no public network access. PE only.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    fileServices: {
      shares: [
        {
          name: profileShareName
          shareQuota: shareQuotaGb
          enabledProtocols: 'SMB'
        }
      ]
    }
  }
}

output resourceId string = storageAccount.outputs.resourceId
output name string = storageAccount.outputs.name
