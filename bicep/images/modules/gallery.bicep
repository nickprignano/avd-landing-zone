// Golden image pipeline: the gallery, the image definition and the two identities.

param location string
param tags object
param galleryName string
param definitionName string
param aibIdentityName string
param buildIdentityName string
param githubRepository string
param distributorRoleId string
param contributorRoleId string

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: galleryName
  location: location
  tags: tags
  properties: {
    description: 'Golden images for the AVD landing zone (docs/image-pipeline-spec.md).'
  }
}

// Session hosts are Trusted Launch with accelerated networking (modules/sessionHosts.bicep),
// so the definition says so; a definition without these features can't serve them.
resource definition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: definitionName
  location: location
  tags: tags
  properties: {
    osType: 'Windows'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    architecture: 'x64'
    identifier: {
      publisher: 'avdlz'
      offer: 'win11-avd-m365'
      sku: '24h2'
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunch'
      }
      {
        name: 'IsAcceleratedNetworkSupported'
        value: 'True'
      }
    ]
    description: 'Windows 11 Enterprise multi-session 24H2 with Microsoft 365 Apps, patched and optimized (WDOT).'
  }
}

// Azure Image Builder runs as this identity.
resource aibIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: aibIdentityName
  location: location
  tags: tags
}

// The image-build workflow signs in as this identity (OIDC, no stored secret).
resource buildIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: buildIdentityName
  location: location
  tags: tags
}

resource buildFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = if (!empty(githubRepository)) {
  parent: buildIdentity
  name: 'github-images-environment'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:environment:images'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

// AIB publishes versions to the gallery.
resource aibDistributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aibIdentity.id, distributorRoleId)
  properties: {
    principalId: aibIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: distributorRoleId
  }
}

// The workflow deploys, runs and deletes image templates here, and assigns the AIB
// identity to them. Contributor can't create role assignments.
resource buildContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, buildIdentity.id, contributorRoleId)
  properties: {
    principalId: buildIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}

output imageDefinitionId string = definition.id
output aibIdentityId string = aibIdentity.id
output aibPrincipalId string = aibIdentity.properties.principalId
output buildPrincipalId string = buildIdentity.properties.principalId
output buildClientId string = buildIdentity.properties.clientId
