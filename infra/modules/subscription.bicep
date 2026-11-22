// Subscription-scope resources: Reader role for the function identity (R9, A.8.2) and the budget (R6).
targetScope = 'subscription'

param functionPrincipalId string
param budgetEmail string
@description('First day of the current month, yyyy-MM-01.')
param budgetStartDate string
param budgetAmount int = 20

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// R6: 20 USD budget with alerts at 5, 10 and 20 USD (25 %, 50 %, 100 %).
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-iso-evidence'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      usd5: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 25, thresholdType: 'Actual', contactEmails: [ budgetEmail ] }
      usd10: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 50, thresholdType: 'Actual', contactEmails: [ budgetEmail ] }
      usd20: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 100, thresholdType: 'Actual', contactEmails: [ budgetEmail ] }
    }
  }
}
