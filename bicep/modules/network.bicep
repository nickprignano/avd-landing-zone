// Network — the AVD spoke.
//
// Both subnets are created with default outbound access OFF, so egress is
// always explicit:
//   - Standalone: NAT Gateway on the session host subnet. No hub needed.
//   - HubPeered:  peered to an existing hub (both directions), 0.0.0.0/0
//                 routed to the hub firewall, DNS from the hub.
// The private endpoint subnet enforces NSG rules on its endpoints.

param location string
param tags object
param vnetName string
param addressPrefix string
param sessionHostSubnetPrefix string
param privateEndpointSubnetPrefix string

@allowed([
  'Standalone'
  'HubPeered'
])
param connectivityMode string
param hubVnetResourceId string
param createHubToSpokePeering bool
param hubFirewallPrivateIp string
param dnsServers array
param logAnalyticsWorkspaceResourceId string

var isHub = connectivityMode == 'HubPeered'
var useRouteTable = isHub && !empty(hubFirewallPrivateIp)
var diagnostics = [
  {
    workspaceResourceId: logAnalyticsWorkspaceResourceId
  }
]

// ---------- NSGs ----------
module sessionHostNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-session-hosts'
  params: {
    name: 'nsg-${vnetName}-hosts'
    location: location
    tags: tags
    // Session hosts accept no inbound connections (AVD uses reverse connect) and
    // may not RDP/SSH to anything else in the network (no lateral movement).
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-VirtualNetwork-RDP-SSH-Outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

module privateEndpointNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-private-endpoints'
  params: {
    name: 'nsg-${vnetName}-pe'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Allow-SessionHosts-SMB'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sessionHostSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '445'
        }
      }
      {
        name: 'Allow-VirtualNetwork-HTTPS'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-VirtualNetwork-RDP-SSH-Outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// ---------- Egress ----------
module natGateway 'br/public:avm/res/network/nat-gateway:2.1.1' = if (!isHub) {
  name: 'nat-gateway'
  params: {
    name: 'ng-${vnetName}'
    location: location
    tags: tags
    availabilityZone: -1
    publicIPAddresses: [
      {
        name: 'pip-ng-${vnetName}'
      }
    ]
  }
}

module routeTable 'br/public:avm/res/network/route-table:0.5.0' = if (useRouteTable) {
  name: 'route-table'
  params: {
    name: 'rt-${vnetName}-hosts'
    location: location
    tags: tags
    disableBgpRoutePropagation: true
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

// ---------- VNet ----------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [
      addressPrefix
    ]
    dnsServers: dnsServers
    subnets: [
      {
        name: 'snet-session-hosts'
        addressPrefix: sessionHostSubnetPrefix
        defaultOutboundAccess: false
        networkSecurityGroupResourceId: sessionHostNsg.outputs.resourceId
        natGatewayResourceId: isHub ? null : natGateway!.outputs.resourceId
        routeTableResourceId: useRouteTable ? routeTable!.outputs.resourceId : null
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
        defaultOutboundAccess: false
        networkSecurityGroupResourceId: privateEndpointNsg.outputs.resourceId
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
      }
    ]
    peerings: isHub
      ? [
          {
            remoteVirtualNetworkResourceId: hubVnetResourceId
            allowForwardedTraffic: true
            allowVirtualNetworkAccess: true
            useRemoteGateways: false
            remotePeeringEnabled: createHubToSpokePeering
            remotePeeringAllowForwardedTraffic: true
            remotePeeringAllowVirtualNetworkAccess: true
          }
        ]
      : []
    diagnosticSettings: diagnostics
  }
}

output vnetResourceId string = vnet.outputs.resourceId
output sessionHostSubnetResourceId string = vnet.outputs.subnetResourceIds[0]
output privateEndpointSubnetResourceId string = vnet.outputs.subnetResourceIds[1]
