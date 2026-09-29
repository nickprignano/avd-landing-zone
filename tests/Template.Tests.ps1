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
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_SESSION_HOST_COUNT = '3'; $env:AVD_SESSION_HOST_VM_SIZE = 'Standard_D8as_v5'; $env:AVD_MAX_SESSION_LIMIT = '16'; $env:AVD_PROFILE_QUOTA_GIB = '600'
      try { $p = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
      finally { $env:AVD_SESSION_HOST_COUNT = ''; $env:AVD_SESSION_HOST_VM_SIZE = ''; $env:AVD_MAX_SESSION_LIMIT = ''; $env:AVD_PROFILE_QUOTA_GIB = '' }
      $p.sessionHostCount.value | Should -Be 3
      $p.sessionHostVmSize.value | Should -Be 'Standard_D8as_v5'
      $p.maxSessionLimit.value | Should -Be 16
      $p.profileShareQuotaGiB.value | Should -Be 600
      $d = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
      $d.sessionHostVmSize.value | Should -Be 'Standard_E4as_v5'   # memory-optimised default for multi-session
      $d.maxSessionLimit.value | Should -Be 8
    }
  }
}
