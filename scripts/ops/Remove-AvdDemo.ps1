#requires -Version 7.2
<#
.SYNOPSIS
  Removes the demo host pool deployed by Deploy-AvdDemo.ps1, and optionally the
  whole landing zone.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Supports -WhatIf.

  Default (demo only)
    - rg-<prefix>-<env>-demo: host pool, app group, workspace, session hosts,
      disks, NICs, the host pool's private endpoint and the demo RBAC
    - the subscription deployment record avdlz-demo-<prefix>-<env>
    - the demo hosts' Entra ID and Intune device objects (skip with -KeepDevices)

  -IncludeLandingZone (everything; asks you to type the landing zone name)
    - profile backup: turns vault immutability and soft delete off, stops
      protection deleting recovery points, unregisters the storage account
      (which releases the AzureBackupProtectionLock)
    - resource groups hosts, avd, storage, management, network (in that order)
    - policy assignments avdlz-* and their role assignments, the budget,
      the activity-log diagnostic setting, avdlz-* deployment records
    - Entra ID / Intune device objects of the landing zone hosts
    - -ResetDefender also sets the Defender plans the landing zone enabled back to Free

  Key Vault is left soft-deleted with purge protection (90 days); its name can't
  be reused until then. See docs/gotchas.md.

.EXAMPLE
  ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -IncludeLandingZone -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  [string] $SubscriptionId,
  [switch] $IncludeLandingZone,
  [switch] $KeepDevices,
  [switch] $ResetDefender,
  # Skip confirmations (including the typed confirmation for -IncludeLandingZone).
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
if ($Force) { $ConfirmPreference = 'None' }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$sub = "/subscriptions/$($lz.SubscriptionId)"
Clear-AvdCheckResult
Write-Host "AVD cleanup - $($lz.BaseName) in '$($ctx.Subscription.Name)'$(if ($IncludeLandingZone) { ' (DEMO + LANDING ZONE)' } else { ' (demo only)' })" -ForegroundColor White

if ($IncludeLandingZone -and -not $Force -and -not $WhatIfPreference) {
  Write-Host "This permanently deletes the landing zone '$($lz.BaseName)', its profiles and their backups." -ForegroundColor Red
  $typed = Read-Host "Type '$($lz.BaseName)' to continue"
  if ($typed -ne $lz.BaseName) { throw 'Confirmation did not match; nothing was removed.' }
  $ConfirmPreference = 'None'
}

function Remove-AvdDevice {
  <# Deletes Entra ID and Intune device objects for the given computer names. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([string[]] $ComputerName)
  if (-not $ComputerName) { return }
  try { Connect-AvdGraph -Purpose Cleanup }
  catch { Add-AvdCheckResult 'Devices' 'Microsoft Graph sign-in' 'Warn' -Detail $_.Exception.Message -Remediation 'Delete the devices manually in Entra ID and Intune.'; return }
  foreach ($name in $ComputerName) {
    try {
      $found = 0; $removed = 0
      $managed = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection 'deviceManagement/managedDevices' -Filter "deviceName eq '$name'" -Select 'id,deviceName')
      foreach ($d in @($managed)) {
        $found++
        if ($PSCmdlet.ShouldProcess("Intune device $name", 'Delete')) { Invoke-AvdGraph -Method DELETE -Uri "v1.0/deviceManagement/managedDevices/$($d.id)" | Out-Null; $removed++ }
      }
      $devices = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection devices -Filter "displayName eq '$name'" -Select 'id,displayName')
      foreach ($d in @($devices)) {
        $found++
        if ($PSCmdlet.ShouldProcess("Entra ID device $name", 'Delete')) { Invoke-AvdGraph -Method DELETE -Uri "v1.0/devices/$($d.id)" | Out-Null; $removed++ }
      }
      if ($removed) { Add-AvdCheckResult 'Devices' "Device objects for $name" 'Fixed' -Detail "Removed $removed of $found object(s)." }
      elseif (-not $found) { Add-AvdCheckResult 'Devices' "Device objects for $name" 'Pass' -Detail 'None found.' }
    }
    catch { Add-AvdCheckResult 'Devices' "Device objects for $name" 'Warn' -Detail $_.Exception.Message }
  }
}

function Remove-AvdResourceGroupIfPresent {
  [CmdletBinding(SupportsShouldProcess)]
  param([string] $Name)
  if (-not (Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue)) { Add-AvdCheckResult 'Resource groups' $Name 'Pass' -Detail 'Not present.'; return }
  if ($PSCmdlet.ShouldProcess($Name, 'Delete resource group')) {
    Write-Host "  deleting $Name (this can take several minutes)" -ForegroundColor DarkGray
    Remove-AzResourceGroup -Name $Name -Force | Out-Null
    Add-AvdCheckResult 'Resource groups' $Name 'Fixed' -Detail 'Deleted.'
  }
}

# ---------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------
Write-AvdSection 'Demo host pool'
$demoHosts = @()
if ($lz.RgExists.Demo) {
  $demoHosts = @(Get-AzVM -ResourceGroupName $lz.ResourceGroups.Demo -ErrorAction SilentlyContinue | ForEach-Object { $_.OSProfile.ComputerName })
}
Remove-AvdResourceGroupIfPresent -Name $lz.ResourceGroups.Demo
$demoDeployment = "avdlz-demo-$($lz.BaseName)"
if ((Get-AzDeployment -Name $demoDeployment -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($demoDeployment, 'Delete deployment record')) {
  Remove-AzDeployment -Name $demoDeployment | Out-Null
  Add-AvdCheckResult 'Deployments' $demoDeployment 'Fixed' -Detail 'Deleted.'
}
if (-not $KeepDevices) { Remove-AvdDevice -ComputerName $demoHosts }

if (-not $IncludeLandingZone) {
  Write-AvdSummary | Out-Null
  if (-not $WhatIfPreference) { Write-AvdPortalState (Get-AvdPortalState -Stage cleanup -Context @{ namePrefix = $NamePrefix; environment = $Environment; includeLandingZone = [bool]$IncludeLandingZone }) }
  return
}

# ---------------------------------------------------------------------
# Landing zone
# ---------------------------------------------------------------------
$lzHosts = @()
if ($lz.RgExists.Hosts) {
  $lzHosts = @(Get-AzVM -ResourceGroupName $lz.ResourceGroups.Hosts -ErrorAction SilentlyContinue | ForEach-Object { $_.OSProfile.ComputerName })
}

Write-AvdSection 'Profile backup'
if ($lz.RecoveryVault) {
  $vault = Get-AzRecoveryServicesVault -ResourceGroupName $lz.RecoveryVault.ResourceGroupName -Name $lz.RecoveryVault.Name
  if ($PSCmdlet.ShouldProcess($vault.Name, 'Disable immutability and soft delete, stop protection and delete recovery points')) {
    # Immutability blocks "stop protection and delete data"; soft delete would keep
    # the items for 14 days and block deleting the vault.
    Update-AzRecoveryServicesVault -ResourceGroupName $vault.ResourceGroupName -Name $vault.Name -ImmutabilityState Disabled | Out-Null
    Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -SoftDeleteFeatureState Disable | Out-Null
    $items = @(Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $vault.ID)
    foreach ($item in $items) {
      Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints -VaultId $vault.ID -Force | Out-Null
    }
    foreach ($c in @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $vault.ID)) {
      Unregister-AzRecoveryServicesBackupContainer -Container $c -VaultId $vault.ID -Force | Out-Null
    }
    Add-AvdCheckResult 'Backup' "Stopped protection on $($items.Count) share(s) and unregistered the storage account" 'Fixed'
  }
}
else { Add-AvdCheckResult 'Backup' 'Recovery Services vault' 'Pass' -Detail 'Not present.' }

if ($lz.StorageAccount) {
  foreach ($lock in @(Get-AzResourceLock -Scope $lz.StorageAccount.Id -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("lock $($lock.Name) on $($lz.StorageAccount.StorageAccountName)", 'Remove')) {
      Remove-AzResourceLock -LockId $lock.LockId -Force | Out-Null
      Add-AvdCheckResult 'Backup' "Removed lock $($lock.Name) from the storage account" 'Fixed'
    }
  }
}

Write-AvdSection 'Landing zone resource groups'
foreach ($k in 'Hosts', 'ControlPlane', 'Storage', 'Management', 'Network') {
  Remove-AvdResourceGroupIfPresent -Name $lz.ResourceGroups[$k]
}

Write-AvdSection 'Subscription-level resources'
$assignments = Invoke-AvdArm -Path "$sub/providers/Microsoft.Authorization/policyAssignments?api-version=2024-04-01&`$filter=atScope()"
foreach ($pa in @($assignments.value | Where-Object name -like 'avdlz-*')) {
  if (-not $PSCmdlet.ShouldProcess("policy assignment $($pa.name)", 'Delete (and its role assignments)')) { continue }
  if ($pa.identity -and $pa.identity.principalId) {
    Get-AzRoleAssignment -ObjectId $pa.identity.principalId -Scope $sub -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-AzRoleAssignment -InputObject $_ | Out-Null }
  }
  Invoke-AvdArm -Method DELETE -Path "$($pa.id)?api-version=2024-04-01" | Out-Null
  Add-AvdCheckResult 'Subscription' "Policy assignment $($pa.name)" 'Fixed' -Detail 'Deleted.'
}

$budgetPath = "$sub/providers/Microsoft.Consumption/budgets/budget-$($lz.BaseName)?api-version=2023-11-01"
if ((Invoke-AvdArm -Path $budgetPath -AllowNotFound) -and $PSCmdlet.ShouldProcess("budget-$($lz.BaseName)", 'Delete budget')) {
  Invoke-AvdArm -Method DELETE -Path $budgetPath | Out-Null
  Add-AvdCheckResult 'Subscription' "Budget budget-$($lz.BaseName)" 'Fixed' -Detail 'Deleted.'
}

$diagPath = "$sub/providers/Microsoft.Insights/diagnosticSettings/avdlz-activity-log?api-version=2021-05-01-preview"
if ((Invoke-AvdArm -Path $diagPath -AllowNotFound) -and $PSCmdlet.ShouldProcess('avdlz-activity-log', 'Delete activity log diagnostic setting')) {
  Invoke-AvdArm -Method DELETE -Path $diagPath | Out-Null
  Add-AvdCheckResult 'Subscription' 'Activity log diagnostic setting' 'Fixed' -Detail 'Deleted.'
}

foreach ($d in @(Get-AzDeployment -ErrorAction SilentlyContinue | Where-Object DeploymentName -like 'avdlz-*')) {
  if ($PSCmdlet.ShouldProcess($d.DeploymentName, 'Delete deployment record')) { Remove-AzDeployment -Name $d.DeploymentName | Out-Null }
}

if ($ResetDefender) {
  foreach ($plan in 'VirtualMachines', 'StorageAccounts', 'KeyVaults') {
    if ($PSCmdlet.ShouldProcess("Defender plan $plan", 'Set to Free')) {
      Invoke-AvdArm -Method PUT -Path "$sub/providers/Microsoft.Security/pricings/$plan`?api-version=2024-01-01" -Body @{ properties = @{ pricingTier = 'Free' } } | Out-Null
      Add-AvdCheckResult 'Subscription' "Defender plan $plan set to Free" 'Fixed'
    }
  }
}

if (-not $KeepDevices) { Remove-AvdDevice -ComputerName $lzHosts }

if ($lz.KeyVault) {
  Add-AvdCheckResult 'Subscription' "Key Vault $($lz.KeyVault.Name) is soft-deleted with purge protection" 'Warn' -Detail 'The name is reserved for 90 days.' -Remediation 'Change namePrefix to redeploy sooner, or recover it with Undo-AzKeyVaultRemoval.'
}
Write-AvdSummary | Out-Null
if (-not $WhatIfPreference) { Write-AvdPortalState (Get-AvdPortalState -Stage cleanup -Context @{ namePrefix = $NamePrefix; environment = $Environment; includeLandingZone = [bool]$IncludeLandingZone }) }
