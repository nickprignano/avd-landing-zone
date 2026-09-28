# Post-deployment preflight, demo and cleanup against a mocked landing zone whose three
# tenant steps are not done yet.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev' }

Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }
Invoke-ScenarioStep 'fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force }
Write-Host "RESULT fix-state consent=$(@($global:St.grants).Count -gt 0) tagged=$(@($global:St.tags).Count -gt 0) caExcluded=$(@($global:St.caExclude).Count -gt 0) aclApplied=$($global:St.aclApplied) leftoverRoles=$(@($global:St.roleAssignments).Count)"
Invoke-ScenarioStep 'recheck' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }

Invoke-ScenarioStep 'demo' { & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com }
Invoke-ScenarioStep 'remove-demo' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force }

$global:Calls.Clear()
Invoke-ScenarioStep 'remove-lz-whatif' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -WhatIf }
Write-Host "RESULT remove-lz-whatif changes=$(@($global:Calls | Where-Object { $_ -match 'del |unlock|backup|rsv|DELETE|RBAC -|PUT' }).Count)"

Invoke-ScenarioStep 'remove-lz' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -ResetDefender -Force }
Write-Host "RESULT remove-lz remainingRgs=$(@($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-dev-*' }).Count)"
