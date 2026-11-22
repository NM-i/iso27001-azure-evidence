// Prototype resources (rg-iso-proto): collection function, immutable evidence store, log, dashboard, alert.
targetScope = 'resourceGroup'

param location string = 'germanywestcentral'
param suffix string = uniqueString(resourceGroup().id)
@description('Resource group with the monitored test resources.')
param targetResourceGroup string = 'rg-iso-target'
@description('E-mail for the non-compliance alert (R14) and budget alerts (R6).')
param alertEmail string
@description('Object ID of the person running the experiment (read access to evidence for R10).')
param adminPrincipalId string
param budgetStartDate string
@minValue(1)
param immutabilityDays int = 7

var tags = { owner: 'author', environment: 'test', purpose: 'iso27001-evidence-prototype' }
var roles = {
  blobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  blobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  blobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  metricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}
var storageBase = {
  minimumTlsVersion: 'TLS1_2'      // R11
  supportsHttpsTrafficOnly: true   // R11
  allowBlobPublicAccess: false
  allowSharedKeyAccess: false      // R9
}

// ---------- Log Analytics: cycle log and results (R5, R8) ----------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-proto-${take(suffix, 8)}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

var cycleColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'CycleId', type: 'string' }
  { name: 'StartTime', type: 'datetime' }
  { name: 'EndTime', type: 'datetime' }
  { name: 'DurationSec', type: 'real' }
  { name: 'RecordCount', type: 'int' }
  { name: 'Status', type: 'string' }
  { name: 'Throttled', type: 'int' }
  { name: 'Error', type: 'string' }
]
var resultColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'CycleId', type: 'string' }
  { name: 'ControlId', type: 'string' }
  { name: 'ControlName', type: 'string' }
  { name: 'ResourceId', type: 'string' }
  { name: 'Result', type: 'string' }
  { name: 'CollectedAt', type: 'datetime' }
  { name: 'BlobPath', type: 'string' }
  { name: 'Sha256', type: 'string' }
]

var runnerColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Event', type: 'string' }
  { name: 'Detail', type: 'string' }
  { name: 'Step', type: 'string' }
]

// Test runner notifications (tools/runner/notify.py); not part of the prototype requirements.
resource runnerTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'RunnerStatus_CL'
  properties: { plan: 'Analytics', retentionInDays: 30, schema: { name: 'RunnerStatus_CL', columns: runnerColumns } }
}

resource cycleTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'EvidenceCycle_CL'
  properties: { plan: 'Analytics', retentionInDays: 30, schema: { name: 'EvidenceCycle_CL', columns: cycleColumns } }
}

resource resultTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'EvidenceResult_CL'
  properties: { plan: 'Analytics', retentionInDays: 30, schema: { name: 'EvidenceResult_CL', columns: resultColumns } }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-proto-${take(suffix, 8)}'
  location: location
  tags: tags
  properties: { networkAcls: { publicNetworkAccess: 'Enabled' } }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-evidence'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-EvidenceCycle_CL': { columns: cycleColumns }
      'Custom-EvidenceResult_CL': { columns: resultColumns }
      'Custom-RunnerStatus_CL': { columns: runnerColumns }
    }
    destinations: { logAnalytics: [ { name: 'law', workspaceResourceId: law.id } ] }
    dataFlows: [
      { streams: [ 'Custom-EvidenceCycle_CL' ], destinations: [ 'law' ], transformKql: 'source', outputStream: 'Custom-EvidenceCycle_CL' }
      { streams: [ 'Custom-EvidenceResult_CL' ], destinations: [ 'law' ], transformKql: 'source', outputStream: 'Custom-EvidenceResult_CL' }
      { streams: [ 'Custom-RunnerStatus_CL' ], destinations: [ 'law' ], transformKql: 'source', outputStream: 'Custom-RunnerStatus_CL' }
    ]
  }
  dependsOn: [ cycleTable, resultTable, runnerTable ]
}

// ---------- Evidence store (R2, R3, R11) ----------
resource evid 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stevid${take(suffix, 12)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: storageBase
}

resource evidBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: evid
  name: 'default'
}

resource evidContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: evidBlob
  name: 'evidence'
  properties: { publicAccess: 'None' }
}

// R3: time-based retention. Created UNLOCKED; lock it before the experiment (docs/ADMIN.md, T7).
resource evidPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: evidContainer
  name: 'default'
  properties: { immutabilityPeriodSinceCreationInDays: immutabilityDays, allowProtectedAppendWrites: false }
}

// ---------- Function host storage (identity-based, no keys) ----------
resource hostSt 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stfunc${take(suffix, 12)}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: storageBase
}

resource hostBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostSt
  name: 'default'
}

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: 'app-package'
}

// ---------- Function app on Flex Consumption (R4, R9) ----------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-proto-${take(suffix, 8)}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-evid-${take(suffix, 10)}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: hostSt.name }
        { name: 'EVIDENCE_ACCOUNT_URL', value: evid.properties.primaryEndpoints.blob }
        { name: 'EVIDENCE_CONTAINER', value: evidContainer.name }
        { name: 'TARGET_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'TARGET_RESOURCE_GROUP', value: targetResourceGroup }
        { name: 'DCE_ENDPOINT', value: dce.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dcr.properties.immutableId }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostSt.properties.primaryEndpoints.blob}${deployContainer.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 512 }
      runtime: { name: 'python', version: '3.11' }
    }
  }
}

// No basic-auth publishing credentials (R9: no passwords).
resource ftpOff 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'ftp'
  properties: { allow: false }
}
resource scmOff 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: { allow: false }
}

// ---------- Role assignments (R9: least privilege) ----------
resource raEvidence 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(evidContainer.id, app.id, roles.blobDataContributor)
  scope: evidContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.blobDataContributor)
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Required by the Functions host for identity-based AzureWebJobsStorage (leases, deployment package).
resource raHost 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostSt.id, app.id, roles.blobDataOwner)
  scope: hostSt
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.blobDataOwner)
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, app.id, roles.metricsPublisher)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.metricsPublisher)
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raAdminRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(evidContainer.id, adminPrincipalId, roles.blobDataReader)
  scope: evidContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.blobDataReader)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

module sub 'modules/subscription.bicep' = {
  name: 'subscription-scope'
  scope: subscription()
  params: {
    functionPrincipalId: app.identity.principalId
    budgetEmail: alertEmail
    budgetStartDate: budgetStartDate
  }
}

// ---------- Alert on non-compliance (R14) ----------
resource ag 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-evidence'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'evidence'
    enabled: true
    emailReceivers: [ { name: 'author', emailAddress: alertEmail, useCommonAlertSchema: true } ]
  }
}

resource noncompliantAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'sqr-noncompliant'
  location: location
  tags: tags
  properties: {
    displayName: 'ISO 27001 evidence: control not compliant'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [ law.id ]
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'EvidenceResult_CL | where Result == "neatitinka" | summarize NonCompliant = count() by ControlId'
          timeAggregation: 'Total'
          metricMeasureColumn: 'NonCompliant'
          dimensions: [ { name: 'ControlId', operator: 'Include', values: [ '*' ] } ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [ ag.id ] }
  }
  dependsOn: [ resultTable ]
}

// ---------- Test runner e-mails (not a prototype requirement) ----------
// Every runner event except HEARTBEAT (started, stage finished, failed, done). Stateless; ingestion_time()
// prevents both duplicates and misses caused by ingestion delay.
resource runnerEventAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'sqr-runner-event'
  location: location
  tags: tags
  properties: {
    displayName: 'ISO 27001 test runner: event'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [ law.id ]
    autoMitigate: false
    criteria: {
      allOf: [
        {
          query: 'RunnerStatus_CL | where ingestion_time() > ago(15m) and Event != "HEARTBEAT" | summarize Events = count() by Event, Detail'
          timeAggregation: 'Total'
          metricMeasureColumn: 'Events'
          dimensions: [
            { name: 'Event', operator: 'Include', values: [ '*' ] }
            { name: 'Detail', operator: 'Include', values: [ '*' ] }
          ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [ ag.id ] }
  }
  dependsOn: [ runnerTable ]
}

// No runner message for 3 h and the run is not finished -> the runner probably died. Hourly reminder.
resource runnerStaleAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'sqr-runner-stale'
  location: location
  tags: tags
  properties: {
    displayName: 'ISO 27001 test runner: no heartbeat for 3 h (check Defender CSPM!)'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'P2D'
    scopes: [ law.id ]
    autoMitigate: false
    criteria: {
      allOf: [
        {
          query: 'RunnerStatus_CL | summarize last = max(TimeGenerated), finished = countif(Event in ("DONE", "CANCELLED")) | where isnotnull(last) and finished == 0 and last < ago(3h) | extend Stale = 1'
          timeAggregation: 'Total'
          metricMeasureColumn: 'Stale'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [ ag.id ] }
  }
  dependsOn: [ runnerTable ]
}

// ---------- Dashboard (R5) ----------
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'iso27001-controls-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'ISO/IEC 27001 kontrolių būklė'
    category: 'workbook'
    sourceId: law.id
    serializedData: replace(loadTextContent('../workbook/controls.workbook.json'), '__WORKSPACE_ID__', law.id)
  }
}

output functionAppName string = app.name
output evidenceAccountName string = evid.name
output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output dcrId string = dcr.id
