// Key Vault — holds the session hosts' break-glass local admin credential.
// RBAC-authorised, purge-protected, reachable only over its private endpoint.

param location string
param tags object
param name string
param privateEndpointSubnetResourceId string
param privateDnsZoneResourceId string
param logAnalyticsWorkspaceResourceId string
param adminsGroupObjectId string
param localAdminUsername string

@secure()
param localAdminPassword string

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

module vault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'key-vault'
  params: {
    name: name
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    privateEndpoints: [
      {
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: privateDnsZoneResourceId
            }
          ]
        }
      }
    ]
    secrets: [
      {
        name: 'sessionhost-localadmin-username'
        value: localAdminUsername
      }
      {
        name: 'sessionhost-localadmin-password'
        value: localAdminPassword
        contentType: 'Break-glass local administrator for AVD session hosts'
      }
    ]
    roleAssignments: [
      {
        principalId: adminsGroupObjectId
        principalType: 'Group'
        roleDefinitionIdOrName: keyVaultSecretsUserRoleId
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]
  }
}

output name string = vault.outputs.name
output resourceId string = vault.outputs.resourceId
