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
  # The machine-readable state lines the deployment portal reads (docs/portal/README.md).
  function Get-PortalState([string] $Output) {
    @([regex]::Matches($Output, '<<<AVDLZ-STATE (.*?) AVDLZ-STATE>>>') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
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
  It 'ends every run with a portal state line (none under -WhatIf)' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status):$($_.fix)" }) -join ' ' |
      Should -Be 'postdeploy:notready:False postdeploy:ready:True postdeploy:ready:False demo:ready:False cleanup:ready:False cleanup:ready:False'
    $s[0].context.namePrefix | Should -Be 'avdlz'
    $s[0].failures.Count | Should -Be $s[0].counts.fail
    $s[5].context.includeLandingZone | Should -BeTrue
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
  It 'gives the portal the context and structured failures it needs' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status)" }) -join ' ' | Should -Be 'predeploy:notready predeploy:ready predeploy:ready predeploy:notready'
    $s[1].context.parameterFile | Should -Be 'parameters/dev.bicepparam'
    $s[1].context.location | Should -Be 'northcentralus'
    $s[1].context.usersGroup | Should -Be 'AVD Users'
    $quota = $s[3].failures | Where-Object id -eq 'quota'
    $quota.data.quotaName | Should -Be 'standardDASv5Family'
    $quota.data.needed | Should -Be 16
    ($s[3].failures | Where-Object id -eq 'kv-softdeleted').data.vaults | Should -Contain 'kvavdlzprodabc123'
  }
}

Describe 'No landing zone in the subscription' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'NoLandingZone' }

  It 'fails once with a pointer to what is there, not once per missing resource' {
    Get-StepExit $out 'check' | Should -Be 1
    $out | Should -Match '-NamePrefix contoso -Environment prod'
    $out | Should -Match 'Nothing to check until the landing zone exists'
  }
  It 'tells the portal which landing zones do exist' {
    $f = (Get-PortalState $out)[0].failures | Where-Object id -eq 'lz-missing'
    $f.data.found[0].namePrefix | Should -Be 'contoso'
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

Describe 'Well-Architected review of the deployed landing zone' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'WellArchitected' }

  It 'reports findings as warnings, so a dev landing zone is still ready' {
    foreach ($step in 'dev', 'skip-psrule', 'production-grade', 'without-switch') { Get-StepExit $out $step | Should -Be 0 }
  }
  It 'marks the dev parameter file''s trade-offs as expected' {
    $s = (Get-PortalState $out)[0]
    $s.context.wellArchitected | Should -BeTrue
    $waf = @($s.warnings | Where-Object { $_.id -like 'waf-*' })
    ($waf | Where-Object { $_.data.accepted } | ForEach-Object id | Sort-Object) -join ',' |
      Should -Be 'waf-budget,waf-defender-plans,waf-host-count,waf-log-retention,waf-profile-backup,waf-storage-redundancy,waf-zones'
    ($waf | Where-Object { -not $_.data.accepted } | ForEach-Object id | Sort-Object) -join ',' |
      Should -Be 'waf-advisor-highavailability,waf-defender-recommendations,waf-policy-compliance,waf-psrule-cost-optimization,waf-psrule-reliability'
  }
  It 'keeps only recommendations for the landing zone (any case), across pages' {
    $out | Should -Match 'Use availability zones for better resiliency'
    $out | Should -Match 'Machines should have vulnerability findings resolved'
    $out | Should -Not -Match 'Right-size underused VM|Other workload'
    $out | Should -Match 'assessmentPages=2'
  }
  It 'runs PSRule on the landing zone resource groups with the repo suppressions, unless skipped' {
    $out | Should -Match 'RESULT dev-calls psruleExport=1 suppressions=1'
    $out | Should -Match 'RESULT skip-psrule-calls psrule=0'
  }
  It 'passes every pillar for a production-grade landing zone' {
    $s = Get-PortalState $out
    @($s[2].warnings).Count | Should -Be 0
    $out | Should -Match 'Reliability\s+7 of 7 pass'
  }
  It 'adds nothing without -WellArchitected' {
    $s = Get-PortalState $out
    $s[3].context.wellArchitected | Should -BeFalse
    $out.Substring($out.IndexOf('######## without-switch')) | Should -Not -Match 'Well-Architected'
  }
}
