# Pre-deployment preflight on an empty subscription (as in the first real Cloud Shell run):
# missing groups, service principal and providers; then a prod file whose zone 3 is unavailable
# and whose Key Vault name is held by a soft-deleted, purge-protected vault.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.rgs = @()
$global:St.unregistered = @('Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.KeyVault', 'Microsoft.RecoveryServices', 'Microsoft.Security')
$global:St.groups = @(); $global:St.avdSp = $false
$pre = @{ PreDeployment = $true; ParameterFile = 'parameters/dev.bicepparam'; UsersGroup = 'AVD Users'; AdminsGroup = 'AVD Admins' }

Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }
Invoke-ScenarioStep 'fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -Fix -Force }
Invoke-ScenarioStep 'recheck' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }

$global:St.skuZones = @('1', '2')
$global:St.deletedVaults = @([pscustomobject]@{ VaultName = 'kvavdlzprodabc123'; Location = 'northcentralus' })
Invoke-ScenarioStep 'prod-zone-and-vault' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/prod.bicepparam -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Location northcentralus
}

# Sized by the deployment portal: 3 x D8as_v5 with 60 sessions each (above 6 per vCPU), priced at
# the mock's placeholder list prices; the public IP meter is not found, so it is reported, not guessed.
$global:St.skuZones = @('1', '2', '3'); $global:St.deletedVaults = @(); $global:St.ipMeterRenamed = $true
Invoke-ScenarioStep 'sized' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 60 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 60
}
# After a quota increase the same sizing passes, and the printed deploy command carries it.
$global:St.quotaLimit = 100; $global:St.ipMeterRenamed = $false
Invoke-ScenarioStep 'sized-ready' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 32 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 60
}
$global:St.quotaLimit = $null

# The landing zone already runs D4as_v5 hosts; the parameter file now defaults to E4as_v5.
$global:St.rgs = @('rg-avdlz-dev-network', 'rg-avdlz-dev-management', 'rg-avdlz-dev-storage', 'rg-avdlz-dev-avd', 'rg-avdlz-dev-hosts')
Invoke-ScenarioStep 'redeploy-resize' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -Location eastus2 }
$global:St.rgs = @()

$global:St.pricesDown = $true
Invoke-ScenarioStep 'prices-down' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }
