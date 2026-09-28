#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# End-to-end runs of the ops scripts against the offline Azure/Graph mock in tests/offline.
# Each scenario runs in its own pwsh process (the mock replaces Az and Graph globally) and
# prints "RESULT <step> ..." lines. Needs the Bicep CLI on PATH (pre-deployment compiles
# the parameter files).
# Every scenario encodes something a real run taught us; see docs/lessons.

BeforeAll {
  $script:pwsh = (Get-Process -Id $PID).Path
  function Invoke-OfflineScenario([string] $Name) {
    $file = Join-Path $PSScriptRoot "offline/$Name.Scenario.ps1"
    $out = & $script:pwsh -NoProfile -NonInteractive -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Scenario $Name crashed (exit $LASTEXITCODE):`n$out" }
    $out
  }
  function Get-StepExit([string] $Output, [string] $Step) {
    $m = [regex]::Match($Output, "RESULT $([regex]::Escape($Step)) EXIT=(\d+)")
    if (-not $m.Success) { throw "No RESULT line for step '$Step'." }
    [int]$m.Groups[1].Value
  }
}

Describe 'Post-deployment: preflight, demo and cleanup' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'PostDeployment' }

  It 'fails the check while the tenant steps are not done' { Get-StepExit $out 'check' | Should -Be 1 }
  It '-Fix completes all three tenant steps' { Get-StepExit $out 'fix' | Should -Be 0 }
  It '-Fix grants consent, tags the app, excludes it from CA and applies the ACL' {
    $out | Should -Match 'RESULT fix-state consent=True tagged=True caExcluded=True aclApplied=True'
  }
  It '-Fix removes the temporary storage role it granted the host' { $out | Should -Match 'leftoverRoles=0' }
  It 'is clean when checked again' { Get-StepExit $out 'recheck' | Should -Be 0 }
  It 'deploys and validates the demo, then removes it' {
    Get-StepExit $out 'demo' | Should -Be 0
    Get-StepExit $out 'remove-demo' | Should -Be 0
  }
  It 'changes nothing when removing the landing zone with -WhatIf' { $out | Should -Match 'RESULT remove-lz-whatif changes=0' }
  It 'removes every landing zone resource group' {
    Get-StepExit $out 'remove-lz' | Should -Be 0
    $out | Should -Match 'RESULT remove-lz remainingRgs=0'
  }
}

Describe 'Pre-deployment: empty subscription, then a blocked prod deployment' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'PreDeployment' }

  It 'fails on missing groups, service principal and providers' { Get-StepExit $out 'check' | Should -Be 1 }
  It '-Fix creates and registers everything it can' { Get-StepExit $out 'fix' | Should -Be 0 }
  It 'is clean when checked again, and prints the deploy command' {
    Get-StepExit $out 'recheck' | Should -Be 0
    $out | Should -Match 'deploy\.sh -p parameters/dev\.bicepparam -l northcentralus'
  }
  It 'reads the AVD host pool regions from the provider API' { $out | Should -Match '\[PASS \] AVD host pools offered in northcentralus' }
  It 'blocks prod on a soft-deleted, purge-protected Key Vault' {
    Get-StepExit $out 'prod-zone-and-vault' | Should -Be 1
    $out | Should -Match '\[FAIL \] No soft-deleted Key Vault blocking the vault name'
  }
}

Describe 'No landing zone in the subscription' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'NoLandingZone' }

  It 'fails once with a pointer to what is there, not once per missing resource' {
    Get-StepExit $out 'check' | Should -Be 1
    $out | Should -Match '-NamePrefix contoso -Environment prod'
    $out | Should -Match 'Nothing to check until the landing zone exists'
  }
}

Describe 'Profile share root that never had an ACL set' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'DefaultShareRoot' }

  It 'reports the default ACL in check mode' {
    Get-StepExit $out 'check' | Should -Be 1
    $out | Should -Match 'still has the default ACL'
  }
  It 'applies the FSLogix ACL with -Fix' {
    Get-StepExit $out 'fix' | Should -Be 0
    $out | Should -Match '\[FIXED\] Profile share root ACL follows FSLogix guidance'
  }
}
