// Monitored test resources (rg-iso-target). Every resource starts COMPLIANT with all 11 controls.
// Drift scenarios D01–D11 (tests/drift/drift.sh) change these resources one at a time.
targetScope = 'resourceGroup'

@description('Azure region (T2).')
param location string = 'germanywestcentral'

@description('Short unique suffix used in globally unique names.')
param suffix string = uniqueString(resourceGroup().id)

@description('Value of the owner tag (A.8.9).')
param ownerTag string

var tags = {
  owner: ownerTag
  environment: 'test'
  purpose: 'iso27001-evidence-target'
}

// A.8.3, A.8.5, A.8.24
resource st 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'sttgt${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

// A.8.13, A.8.21
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-tgt-${take(suffix, 10)}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

// A.8.20
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-app'
  location: location
  tags: tags
  properties: { securityRules: [] }
}

// A.8.22
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-tgt'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.50.0.0/16' ] }
    subnets: [
      {
        name: 'snet-app'
        properties: { addressPrefix: '10.50.1.0/24', networkSecurityGroup: { id: nsg.id } }
      }
      {
        name: 'snet-data'
        properties: { addressPrefix: '10.50.2.0/24', networkSecurityGroup: { id: nsg.id } }
      }
    ]
  }
}

// A.8.15 – no data is ingested here, so longer retention has no storage cost.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-tgt-${take(suffix, 8)}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 90
  }
}

// A.8.16
resource nsgAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'ala-nsg-write'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    scopes: [ subscription().id ]
    condition: {
      allOf: [
        { field: 'category', equals: 'Administrative' }
        { field: 'operationName', equals: 'Microsoft.Network/networkSecurityGroups/write' }
      ]
    }
    actions: { actionGroups: [] }
    description: 'A.8.16: alert on NSG changes'
  }
}

// Used only by drift D01 (A.8.2); has no role assignments at baseline.
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-drift-d01'
  location: location
  tags: tags
}

output storageName string = st.name
output keyVaultName string = kv.name
output workspaceName string = law.name
output driftIdentityPrincipalId string = uami.properties.principalId
output nsgId string = nsg.id
