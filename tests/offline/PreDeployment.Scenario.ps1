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
