#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards on the compiled Bicep template for failures seen in real deployments.
# Needs the Bicep CLI on PATH.

BeforeAll {
  $script:bicep = (Get-Command bicep -ErrorAction Stop).Source
  $env:AVD_USERS_GROUP_ID = '00000000-0000-0000-0000-000000000001'
  $env:AVD_ADMINS_GROUP_ID = '00000000-0000-0000-0000-000000000002'
  $env:AVD_SERVICE_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000003'
  $env:AVD_LOCAL_ADMIN_PASSWORD = 'Placeholder-only-for-build-1!'
  function Get-CompiledTemplate([string] $ParameterFile) {
    $raw = & $script:bicep build-params $ParameterFile --stdout 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build-params failed: $raw" }
    (($raw -join "`n") | ConvertFrom-Json -Depth 100).templateJson | ConvertFrom-Json -Depth 100 -AsHashtable
  }
  function Find-Deployment($Template, [string] $Name) {
    foreach ($r in @($Template.resources.Values) + @($Template.resources)) {
      if ($r -is [System.Collections.IDictionary] -and $r['type'] -eq 'Microsoft.Resources/deployments') {
        if ($r['name'] -eq $Name) { return $r }
        $inner = $r['properties']['template']
        if ($inner) { $hit = Find-Deployment $inner $Name; if ($hit) { return $hit } }
      }
    }
  }
}

Describe 'NAT Gateway public IP zones' {
  # docs/lessons/0001: the AVM nat-gateway module defaults its public IP to zones 1-3,
  # which fails in regions without availability zones (North Central US).
  It 'follows the landing zone availabilityZones instead of the module default' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $network = Find-Deployment $t 'avdlz-network'
    $network['properties']['parameters']['availabilityZones'] | Should -Not -BeNullOrEmpty
    $nat = Find-Deployment $network['properties']['template'] 'nat-gateway'
    $pip = $nat['properties']['parameters']['publicIPAddresses']['value'][0]
    $pip['availabilityZones'] | Should -Match "empty\(parameters\('availabilityZones'\)\)"
  }
}

Describe 'Region override' {
  It 'takes the region from AVD_LOCATION and defaults when it is empty' {
    $env:AVD_LOCATION = 'westus2'
    try { (& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | Should -Match '"location":\s*\{\s*"value":\s*"westus2"' }
    finally { $env:AVD_LOCATION = '' }
    (& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | Should -Match '"location":\s*\{\s*"value":\s*"northcentralus"'
  }
}

Describe 'Sizing overrides' {
  # The deployment portal's sizing step passes these through deploy.sh and the preflight.
  # Set-but-empty must fall back to the file's value (docs/lessons/0004).
  It 'takes host count, size, sessions and profile quota from the environment, and defaults when empty' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/test.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_SESSION_HOST_COUNT = '3'; $env:AVD_SESSION_HOST_VM_SIZE = 'Standard_D8as_v5'; $env:AVD_MAX_SESSION_LIMIT = '16'; $env:AVD_PROFILE_QUOTA_GIB = '600'
      try { $p = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
      finally { $env:AVD_SESSION_HOST_COUNT = ''; $env:AVD_SESSION_HOST_VM_SIZE = ''; $env:AVD_MAX_SESSION_LIMIT = ''; $env:AVD_PROFILE_QUOTA_GIB = '' }
      $p.sessionHostCount.value | Should -Be 3
      $p.sessionHostVmSize.value | Should -Be 'Standard_D8as_v5'
      $p.maxSessionLimit.value | Should -Be 16
      $p.profileShareQuotaGiB.value | Should -Be 600
      $d = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
      $d.sessionHostVmSize.value | Should -Be 'Standard_E4as_v5'   # memory-optimized default for multi-session
      $d.maxSessionLimit.value | Should -Be 8
    }
  }

  # The portal's Cost step passes these through deploy.sh (--auto-shutdown, --start-vm-on-connect).
  It 'takes the scheduled stop and Start VM on Connect from the environment; none = no scheduled stop' {
    $read = { param($file) ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
    foreach ($case in @(
        @{ file = 'parameters/dev.bicepparam'; time = ''; svmoc = ''; expectTime = '20:00'; expectSvmoc = $true },
        @{ file = 'parameters/prod.bicepparam'; time = ''; svmoc = ''; expectTime = ''; expectSvmoc = $true },
        @{ file = 'parameters/dev.bicepparam'; time = 'none'; svmoc = 'false'; expectTime = ''; expectSvmoc = $false },
        @{ file = 'parameters/prod.bicepparam'; time = '18:30'; svmoc = 'true'; expectTime = '18:30'; expectSvmoc = $true })) {
      $env:AVD_AUTO_SHUTDOWN_TIME = $case.time; $env:AVD_START_VM_ON_CONNECT = $case.svmoc
      try { $p = & $read $case.file } finally { $env:AVD_AUTO_SHUTDOWN_TIME = ''; $env:AVD_START_VM_ON_CONNECT = '' }
      $p.autoShutdownTime.value | Should -Be $case.expectTime -Because "$($case.file) time='$($case.time)'"
      $p.startVmOnConnect.value | Should -Be $case.expectSvmoc -Because "$($case.file) svmoc='$($case.svmoc)'"
    }
  }
}

Describe 'Auto shutdown' {
  # decision 0011: a runbook started by a schedule and by the budget's action group.
  It 'deploys the runbook, the dev schedule and the runbook identity''s roles' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $auto = Find-Deployment $t 'avdlz-auto-shutdown'
    $auto | Should -Not -BeNullOrEmpty
    $inner = $auto['properties']['template']
    $res = @($inner['resources'].Values) + @($inner['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] }
    ($res | Where-Object type -eq 'Microsoft.Automation/automationAccounts/runbooks')['properties']['runbookType'] | Should -Be 'PowerShell'
    ($res | Where-Object type -eq 'Microsoft.Automation/automationAccounts')['properties']['disableLocalAuth'] | Should -BeTrue
    $wf = @($res | Where-Object type -eq 'Microsoft.Logic/workflows')
    $wf.Count | Should -Be 2
    ($wf | ForEach-Object { $_['properties']['definition']['triggers'] | ConvertTo-Json -Depth 10 }) -join ' ' | Should -Match 'Recurrence'
    # format() escapes the braces: '@{{guid()}}' becomes the Logic Apps expression '@{guid()}'.
    ($inner['functions'] | ConvertTo-Json -Depth 20) | Should -Match 'jobs/@\{\{guid\(\)\}\}'
    ($inner['functions'] | ConvertTo-Json -Depth 20) | Should -Match 'ManagedServiceIdentity'
    $p = ((& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
    $p.autoShutdownTime.value | Should -Be '20:00'
    $p.autoShutdownRunbookUri.value | Should -Match '^https://raw\.githubusercontent\.com/.+/scripts/automation/Invoke-AvdPowerAction\.ps1$'
    ($t['variables']['roleIds'] | ConvertTo-Json) | Should -Match '082f0a83-3be5-4ba1-904c-961cca79b387'
    (Find-Deployment $t 'avdlz-auto-shutdown-rbac-hosts') | Should -Not -BeNullOrEmpty
    (Find-Deployment $t 'avdlz-auto-shutdown-rbac-avd') | Should -Not -BeNullOrEmpty
  }
  It 'has the budget call the auto-shutdown action group' {
    $t = Get-CompiledTemplate 'parameters/prod.bicepparam'
    $gov = @($t['resources'].Values) + @($t['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -match 'avdlz-governance' }
    ($gov['properties']['parameters']['budgetActionGroupId'] | ConvertTo-Json) | Should -Match "budgetActionGroupId"
    $budget = @($gov['properties']['template']['resources'].Values) + @($gov['properties']['template']['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'Microsoft.Consumption/budgets' }
    ($budget['properties']['notifications'] | ConvertTo-Json) | Should -Match 'contactGroups'
  }
  It 'takes an empty AVD_MONTHLY_BUDGET as no budget (docs/lessons/0004)' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_MONTHLY_BUDGET = ''
      ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.monthlyBudgetAmount.value | Should -Be 0
    }
  }
}

Describe 'A second landing zone beside dev (parameters/test.bicepparam, docs/demo.md)' {
  It 'is dev''s footprint under its own names, and leaves the subscription-wide pieces to dev' {
    $read = { param($file) ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
    $dev = & $read 'parameters/dev.bicepparam'; $test = & $read 'parameters/test.bicepparam'
    $test.environmentName.value | Should -Be 'test'
    $test.deploySubscriptionSettings.value | Should -BeFalse
    $dev.PSObject.Properties.Name | Should -Not -Contain 'deploySubscriptionSettings'   # dev owns them (default true)
    foreach ($p in 'namePrefix', 'sessionHostCount', 'sessionHostVmSize', 'profileShareQuotaGiB', 'enableProfileBackup', 'enableDefenderForCloud', 'autoShutdownTime') {
      ($test.$p.value | ConvertTo-Json -Compress) | Should -Be ($dev.$p.value | ConvertTo-Json -Compress) -Because $p
    }
  }
  It 'turns off the policy guardrails and the activity log export when deploySubscriptionSettings is false' {
    $t = Get-CompiledTemplate 'parameters/test.bicepparam'
    $gov = Find-Deployment $t "[take(format('avdlz-governance-{0}-{1}', variables('baseName'), parameters('location')), 64)]"
    $gov.properties.parameters.enablePolicyGuardrails.value | Should -Be "[and(parameters('enablePolicyGuardrails'), parameters('deploySubscriptionSettings'))]"
    $gov.properties.parameters.deployActivityLog.value | Should -Be "[parameters('deploySubscriptionSettings')]"
  }
}

