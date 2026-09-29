// Auto shutdown (decision 0011): an Azure Automation runbook
// (scripts/automation/Invoke-AvdPowerAction.ps1) that stops, locks or resumes the session hosts.
// Two Logic Apps start it: one on a schedule, one when the budget's action group calls it. Each
// starts a runbook job with its own managed identity (Automation Operator on the account); the
// runbook acts with the Automation account's (roles in autoShutdownRbac.bicep).

param location string
param tags object
param baseName string
param namePrefix string
param environmentName string
param logAnalyticsWorkspaceResourceId string

@description('Where Automation downloads the runbook from when the landing zone is deployed.')
param runbookUri string

@description('Stop time (HH:mm) on the scheduled days, in timeZone. Empty = no schedule.')
param scheduleTime string

@description('Days the schedule runs.')
param scheduleDays string[]

@description('Windows time zone name for the schedule.')
param timeZone string

@allowed([
  'Stop'
  'Lock'
])
param scheduleAction string

@description('What a budget alert does. None = no budget trigger (no budget, or turned off).')
@allowed([
  'Lock'
  'Stop'
  'None'
])
param budgetAction string

var runbookName = 'Invoke-AvdPowerAction'
var hasSchedule = !empty(scheduleTime)
var hasBudgetTrigger = budgetAction != 'None'
// Automation Operator: start jobs of the account's runbooks (Microsoft's built-in role).
var automationOperatorRoleId = 'd3881f73-407a-4167-8283-e981cbba0404'
var jobsApiVersion = '2023-11-01'

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: 'aa-${baseName}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    disableLocalAuth: true
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: runbookName
  location: location
  tags: tags
  properties: {
    // Windows PowerShell 5.1, no modules: the runbook calls ARM with the managed identity's token.
    runbookType: 'PowerShell'
    description: 'Stops, locks or resumes the AVD landing zone session hosts (auto shutdown).'
    logProgress: false
    logVerbose: false
    publishContentLink: {
      uri: runbookUri
    }
  }
}

resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${automation.name}'
  scope: automation
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      for category in [
        'JobLogs'
        'JobStreams'
        'DscNodeStatus'
        'AuditEvent'
      ]: {
        category: category
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// The one action both Logic Apps run: start a runbook job with the managed identity.
func startJob(arm string, automationId string, parameters object) object => {
  Start_runbook_job: {
    type: 'Http'
    runAfter: {}
    inputs: {
      method: 'PUT'
      uri: '${arm}${skip(automationId, 1)}/jobs/@{guid()}?api-version=${jobsApiVersion}'
      body: {
        properties: {
          runbook: {
            name: runbookName
          }
          parameters: parameters
        }
      }
      authentication: {
        type: 'ManagedServiceIdentity'
        audience: arm
      }
    }
  }
}

var jobParameters = {
  NamePrefix: namePrefix
  Environment: environmentName
  SubscriptionId: subscription().subscriptionId
}

resource scheduleWorkflow 'Microsoft.Logic/workflows@2019-05-01' = if (hasSchedule) {
  name: 'logic-${baseName}-shutdown-schedule'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        Schedule: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Week'
            interval: 1
            timeZone: timeZone
            schedule: {
              weekDays: scheduleDays
              hours: [
                int(split(scheduleTime, ':')[0])
              ]
              minutes: [
                int(split(scheduleTime, ':')[1])
              ]
            }
          }
        }
      }
      actions: startJob(environment().resourceManager, automation.id, union(jobParameters, { Action: scheduleAction, Reason: 'schedule' }))
      outputs: {}
    }
  }
  dependsOn: [
    runbook
  ]
}

resource budgetWorkflow 'Microsoft.Logic/workflows@2019-05-01' = if (hasBudgetTrigger) {
  name: 'logic-${baseName}-shutdown-budget'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        // Called by the budget's action group (common alert schema). The callback URL carries a
        // signature; only the action group is given it.
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {}
          }
        }
      }
      actions: startJob(environment().resourceManager, automation.id, union(jobParameters, { Action: budgetAction, Reason: 'budget' }))
      outputs: {}
    }
  }
  dependsOn: [
    runbook
  ]
}

resource scheduleCanStartJobs 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasSchedule) {
  name: guid(automation.id, 'shutdown-schedule', automationOperatorRoleId)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', automationOperatorRoleId)
    principalId: scheduleWorkflow!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource budgetCanStartJobs 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasBudgetTrigger) {
  name: guid(automation.id, 'shutdown-budget', automationOperatorRoleId)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', automationOperatorRoleId)
    principalId: budgetWorkflow!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource budgetActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (hasBudgetTrigger) {
  name: 'ag-${baseName}-budget-shutdown'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('avd${replace(baseName, '-', '')}off', 12)
    enabled: true
    logicAppReceivers: [
      {
        name: 'auto-shutdown'
        resourceId: budgetWorkflow.id
        callbackUrl: listCallbackUrl('${budgetWorkflow.id}/triggers/manual', '2019-05-01').value
        useCommonAlertSchema: true
      }
    ]
  }
}

output automationAccountName string = automation.name
output principalId string = automation.identity.principalId
output budgetActionGroupId string = hasBudgetTrigger ? budgetActionGroup.id : ''
