// Private DNS — Standalone mode only.
// Creates the privatelink zones this landing zone needs and links them to the
// spoke. In HubPeered mode with central DNS, pass the platform's zone IDs via
// centralPrivateDnsZoneResourceIds instead and this module is skipped.

param tags object
param vnetResourceId string

// Key Vault's privatelink zone follows the cloud's vault DNS suffix
// (e.g. .vault.azure.net -> privatelink.vaultcore.azure.net).
var keyVaultZone = 'privatelink${replace(environment().suffixes.keyvaultDns, '.vault.', '.vaultcore.')}'

// The AVD zone is created even if AVD Private Link is off, so turning it on
// later is a parameter change rather than a DNS change.
var zones = [
  'privatelink.file.${environment().suffixes.storage}'
  keyVaultZone
  'privatelink.wvd.microsoft.com'
]

module zone 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for z in zones: {
    name: 'pdns-${z}'
    params: {
      name: z
      tags: tags
      virtualNetworkLinks: [
        {
          virtualNetworkResourceId: vnetResourceId
          registrationEnabled: false
        }
      ]
    }
  }
]

output fileZoneResourceId string = zone[0].outputs.resourceId
output keyVaultZoneResourceId string = zone[1].outputs.resourceId
output avdZoneResourceId string = zone[2].outputs.resourceId
