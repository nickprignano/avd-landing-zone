// Cost guard — budget, alerts, and an automated kill switch for the session hosts.
//
// READ THIS BEFORE YOU TRUST IT:
//
// Azure has NO hard spending cap on pay-as-you-go. Nothing in this file can stop
// your card being charged. A budget is an alerting construct, not a limit, and it
// is evaluated against cost data that LAGS REAL USAGE BY ROUGHLY 8-24 HOURS. A
// budget-triggered kill switch can therefore fire most of a day after you blew
// past the number.
//
// That makes this a BACKSTOP, not a guard. What actually bounds your spend, in
// order of how much it matters:
//
//   1. Auto-shutdown on the session hosts — deterministic, daily, no latency.
//      Wired in hostPool.bicep and ON by default.
//   2. The scaling plan ramping hosts down out of hours — scalingPlan.bicep.
//   3. Running scripts/ops/stop-lab.sh yourself the moment you stop working.
//   4. This: a budget that emails you, and at the limit deallocates the VMs.
//
// The forecast alert below is the useful early warning; the actual-spend alert
// is what pulls the trigger. See docs/cost-controls.md.

targetScope = 'resourceGroup'

param location string
param tags object

@description('Short naming prefix, shared with the rest of the deployment.')
param namePrefix string

@description('Monthly budget for THIS resource group, in the subscription billing currency.')
@minValue(1)
param budgetAmount int

@description('Email addresses that receive the budget alerts. Must not be empty or nobody hears about it.')
@minLength(1)
param alertEmails array

@description('First warning, as a percentage of budgetAmount (actual spend).')
param firstWarningPct int = 50

@description('Second warning, as a percentage of budgetAmount (actual spend).')
param secondWarningPct int = 80

@description('Percentage of budgetAmount that fires the kill switch. Also emails you, and is alerted on forecast as an early warning.')
param killThresholdPct int = 100

@description('First day of the month the budget starts tracking. Azure requires the 1st of a month. If you redeploy in a later month and Azure rejects the start-date change, pass the ORIGINAL value here.')
param budgetStartDate string

@description('Resource ID of the scaling plan. The kill switch disables it first - otherwise the plan starts the hosts again at the next ramp-up and the stop is undone.')
param scalingPlanResourceId string

@description('Resource ID of the host pool the scaling plan drives.')
param hostPoolResourceId string

var actionGroupName = '${namePrefix}-costguard-ag'
var logicAppName = '${namePrefix}-killswitch'
var budgetName = '${namePrefix}-monthly-budget'

// Virtual Machine Contributor — enough to deallocate a VM and nothing else.
// Deliberately NOT Contributor: the kill switch is fired by a callback URL, and
// a URL that can delete your lab is a far worse trade than one that can stop it.
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

// Desktop Virtualization Contributor — to switch the scaling plan off, so it
// does not helpfully start everything back up at 07:00.
var avdContributorRoleId = '082f0a83-3be5-4ba1-904c-961cca79b387'

var armRoot = environment().resourceManager   // ends with a trailing slash

// ---------------------------------------------------------------------------
// The kill switch: list every VM in this resource group, deallocate each one.
//
// Deallocate, not "stop" — a stopped-but-allocated VM still bills for compute.
// Disks and the storage account keep costing money; the VMs ARE the bill, so
// this is where the bleeding stops. Reversible: start them again and carry on.
//
// A consumption Logic App with no runs costs nothing, so this sits idle for free.
// ---------------------------------------------------------------------------
resource killSwitch 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
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
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {}
          }
        }
      }
      actions: {
        // First: stop the scaling plan. Deallocating the hosts is pointless if
        // the plan ramps them straight back up tomorrow morning.
        Disable_Scaling_Plan: {
          type: 'Http'
          inputs: {
            method: 'PATCH'
            uri: '${armRoot}${substring(scalingPlanResourceId, 1)}?api-version=2024-04-03'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              properties: {
                hostPoolReferences: [
                  {
                    hostPoolArmPath: hostPoolResourceId
                    scalingPlanEnabled: false
                  }
                ]
              }
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: armRoot
            }
          }
        }
        List_VMs: {
          // Runs whether or not the scaling plan patch worked. A failure there
          // must not stop us from stopping the VMs.
          runAfter: {
            Disable_Scaling_Plan: ['Succeeded', 'Failed']
          }
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: '${armRoot}subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: armRoot
            }
          }
        }
        Deallocate_each_VM: {
          type: 'Foreach'
          foreach: '@body(\'List_VMs\')?[\'value\']'
          runAfter: {
            List_VMs: ['Succeeded']
          }
          actions: {
            Deallocate: {
              type: 'Http'
              inputs: {
                method: 'POST'
                // armRoot ends in '/' and a resource ID starts with '/', so drop
                // one of them rather than emitting a double slash.
                uri: '${armRoot}@{substring(items(\'Deallocate_each_VM\')?[\'id\'], 1)}/deallocate?api-version=2024-07-01'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: armRoot
                }
              }
            }
          }
        }
      }
    }
  }
}

// The workflow's managed identity needs to deallocate the VMs it finds...
resource killSwitchVmRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logicAppName, vmContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    principalId: killSwitch.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ...and to switch the scaling plan off before it does.
resource killSwitchAvdRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logicAppName, avdContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', avdContributorRoleId)
    principalId: killSwitch.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The HTTP trigger's callback URL is what the action group calls. Treat it as a
// bearer credential: anyone holding it can stop the lab. That is an acceptable
// blast radius for "turn it off" and would not be for "delete it".
resource killSwitchTrigger 'Microsoft.Logic/workflows/triggers@2019-05-01' existing = {
  parent: killSwitch
  name: 'manual'
}

// ---------------------------------------------------------------------------
// Action group — what the budget notifies when a threshold is crossed.
// ---------------------------------------------------------------------------
module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = {
  name: 'deploy-costguard-ag'
  params: {
    name: actionGroupName
    groupShortName: 'costguard'
    location: 'global'
    tags: tags
    emailReceivers: [for (mail, i) in alertEmails: {
      name: 'email-${i}'
      emailAddress: mail
      useCommonAlertSchema: true
    }]
    logicAppReceivers: [
      {
        name: 'killswitch'
        resourceId: killSwitch.id
        callbackUrl: killSwitchTrigger.listCallbackUrl().value
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Budget — scoped to THIS resource group, so it tracks the lab and nothing else.
// The AVM consumption/budget module is subscription-scoped only, hence native.
// ---------------------------------------------------------------------------
resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: {
      // Heads-up emails on money already spent.
      actualFirstWarning: {
        enabled: true
        operator: 'GreaterThan'
        threshold: firstWarningPct
        thresholdType: 'Actual'
        contactEmails: alertEmails
      }
      actualSecondWarning: {
        enabled: true
        operator: 'GreaterThan'
        threshold: secondWarningPct
        thresholdType: 'Actual'
        contactEmails: alertEmails
      }
      // Forecast. THIS is the one that warns you rather than autopsies you,
      // because it does not wait for the spend to land in the cost data.
      forecastAtLimit: {
        enabled: true
        operator: 'GreaterThan'
        threshold: killThresholdPct
        thresholdType: 'Forecasted'
        contactEmails: alertEmails
      }
      // The trigger. Emails you AND calls the action group, which stops the VMs.
      actualAtLimit: {
        enabled: true
        operator: 'GreaterThan'
        threshold: killThresholdPct
        thresholdType: 'Actual'
        contactEmails: alertEmails
        contactGroups: [actionGroup.outputs.resourceId]
      }
    }
  }
}

output actionGroupResourceId string = actionGroup.outputs.resourceId
output budgetName string = budget.name
output killSwitchName string = killSwitch.name
