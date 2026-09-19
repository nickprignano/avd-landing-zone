// Storage — Azure Files share for FSLogix profiles.
// Public network access disabled; reached only via the private endpoint
// created in privateEndpoints.bicep. Wraps the AVM storage-account module.

@description('Storage account name (3-24 lowercase alphanumeric).')
param name string
param location string
param tags object

@description('Name of the file share for FSLogix profiles.')
param profileShareName string = 'profiles'

@description('Quota for the profile share, in GB. Premium file shares start at 100.')
param shareQuotaGb int = 100

@description('Object IDs (Entra ID) granted SMB share access to the profile share. Normally the same principals that get the desktop.')
param smbShareContributorObjectIds array = []

@description('Principal type for smbShareContributorObjectIds.')
@allowed(['User', 'Group', 'ServicePrincipal'])
param smbSharePrincipalType string = 'Group'

module storageAccount 'br/public:avm/res/storage/storage-account:0.14.3' = {
  name: 'deploy-storage-account'
  params: {
    name: name
    location: location
    tags: tags
    // Premium Azure Files requires kind 'FileStorage'. 'StorageV2' + Premium_LRS
    // is premium PAGE BLOB storage, not files, and will not give you a premium
    // SMB share. Sizing the share is still YOUR call (see docs/out-of-scope.md).
    kind: 'FileStorage'
    skuName: 'Premium_LRS'
    // Entra Kerberos: the identity source for SMB when session hosts are
    // Entra-ID joined and there is no AD DS / Entra Domain Services. Without
    // this the share has no way to authenticate a session host user, and
    // FSLogix profiles cannot mount. See docs/gotchas.md.
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
    // Lock the front door: no public network access. PE only.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    // Share-level RBAC. This is one of the two permission layers FSLogix needs;
    // the NTFS layer on the share itself is still a manual step (docs/gotchas.md).
    roleAssignments: [for id in smbShareContributorObjectIds: {
      principalId: id
      roleDefinitionIdOrName: 'Storage File Data SMB Share Contributor'
      principalType: smbSharePrincipalType
    }]
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
