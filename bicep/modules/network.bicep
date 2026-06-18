// Networking — spoke VNet with session-host + private-endpoint subnets and NSGs.
//
// Two modes:
//   - STANDALONE (default, hubVnetResourceId empty): no peering, no forced-egress
//     route. Session hosts use default Azure internet egress. This is what makes
//     a clone-and-run demo work on a personal subscription.
//   - HUB-PEERED (hubVnetResourceId set): peers to the hub and forces 0.0.0.0/0
//     egress through the hub firewall. The "real" enterprise posture.
// Wraps the AVM virtual-network module.

@description('VNet name.')
param name string
param location string
param tags object
param addressPrefix string
param sessionHostSubnetPrefix string
param privateEndpointSubnetPrefix string

@description('Resource ID of the existing hub VNet to peer to. Empty = standalone mode.')
param hubVnetResourceId string = ''

@description('Private IP of the hub firewall / NVA for forced egress. Only used in hub-peered mode.')
param hubFirewallPrivateIp string = '10.0.0.4'

var useHub = !empty(hubVnetResourceId)

// NSG for the session host subnet — deny inbound from internet, allow intra-vnet.
module sessionHostNsg 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-sh-nsg'
  params: {
    name: '${name}-sh-nsg'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Route table only exists in hub-peered mode (forces egress through the hub firewall).
// In standalone mode there is no route table, so hosts use default internet egress.
module routeTable 'br/public:avm/res/network/route-table:0.4.0' = if (useHub) {
  name: 'deploy-route-table'
  params: {
    name: '${name}-rt'
    location: location
    tags: tags
    routes: [
      {
        name: 'default-via-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: hubFirewallPrivateIp
        }
      }
    ]
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.5.1' = {
  name: 'deploy-vnet'
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [addressPrefix]
    subnets: [
      {
        name: 'snet-session-hosts'
        addressPrefix: sessionHostSubnetPrefix
        networkSecurityGroupResourceId: sessionHostNsg.outputs.resourceId
        // Attach the forced-egress route table only when peering to a hub.
        routeTableResourceId: useHub ? routeTable.outputs.resourceId : null
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
    // Peer to the hub only in hub-peered mode.
    peerings: useHub ? [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowVirtualNetworkAccess: true
        useRemoteGateways: false
      }
    ] : []
  }
}

output vnetResourceId string = vnet.outputs.resourceId
output sessionHostSubnetResourceId string = vnet.outputs.subnetResourceIds[0]
output privateEndpointSubnetResourceId string = vnet.outputs.subnetResourceIds[1]
