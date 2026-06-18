// Private endpoints + DNS — the piece people skip.
// A private endpoint gives storage a private IP; nothing resolves to it until
// the private DNS zone is linked to the VNet. Both happen here.
// Wraps the AVM private-dns-zone and private-endpoint modules.

param location string
param tags object

@description('Resource ID of the storage account to expose privately.')
param storageAccountResourceId string

@description('Resource ID of the subnet to place the private endpoint in.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the VNet to link the DNS zone to.')
param vnetResourceId string

// Private DNS zone for Azure Files (file sub-resource).
module dnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'deploy-dns-zone-file'
  params: {
    name: 'privatelink.file.${environment().suffixes.storage}'
    tags: tags
    virtualNetworkLinks: [
      {
        // THE link people forget. Without this, the endpoint exists but won't resolve.
        virtualNetworkResourceId: vnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

// Private endpoint for the storage account's file service.
module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.10.1' = {
  name: 'deploy-pe-file'
  params: {
    name: 'pe-fslogix-file'
    location: location
    tags: tags
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'fslogix-file'
        properties: {
          privateLinkServiceId: storageAccountResourceId
          groupIds: ['file']
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          privateDnsZoneResourceId: dnsZone.outputs.resourceId
        }
      ]
    }
  }
}

output privateEndpointResourceId string = privateEndpoint.outputs.resourceId
output dnsZoneResourceId string = dnsZone.outputs.resourceId
