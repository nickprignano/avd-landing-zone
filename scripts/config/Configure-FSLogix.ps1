#requires -Version 7.0
<#
.SYNOPSIS
  Applies FSLogix configuration to the AVD session hosts via the storage share
  created by the Bicep deployment.

.DESCRIPTION
  Post-deploy step. The Bicep stands up the share and private endpoint; this
  wires FSLogix on the session hosts to point at it. Runs the registry config
  on each host via Run Command.

.PARAMETER ResourceGroup
  Resource group the landing zone was deployed into.

.NOTES
  Permissions on the share (share-level RBAC + NTFS) are the thing that bites
  people. See docs/gotchas.md. This script sets the FSLogix *client* config;
  it assumes the share permissions are correct.
#>
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $ProfileShareName = 'profiles'
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Locating storage account in $ResourceGroup" -ForegroundColor Cyan
$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroup |
  Where-Object { $_.StorageAccountName -like '*fslogix*' } |
  Select-Object -First 1
if (-not $storage) { throw "No FSLogix storage account found in $ResourceGroup." }

$uncPath = "\\$($storage.StorageAccountName).file.$((Get-AzContext).Environment.StorageEndpointSuffix)\$ProfileShareName"
Write-Host "    Profile share: $uncPath"

# FSLogix client registry config, applied on each session host.
$fslogixScript = @"
New-Item -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'Enabled' -Type DWord -Value 1
Set-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'VHDLocations' -Type MultiString -Value '$uncPath'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'DeleteLocalProfileWhenVHDShouldApply' -Type DWord -Value 1
Set-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name 'FlipFlopProfileDirectoryName' -Type DWord -Value 1
"@

Write-Host "==> Applying FSLogix config to session hosts" -ForegroundColor Cyan
$vms = Get-AzVM -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like '*-sh-*' }
if (-not $vms) { throw "No session host VMs (*-sh-*) found in $ResourceGroup." }

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $fslogixScript

foreach ($vm in $vms) {
  Write-Host "    -> $($vm.Name)"
  Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $vm.Name `
    -CommandId 'RunPowerShellScript' -ScriptPath $tmp | Out-Null
}
Remove-Item $tmp -Force

Write-Host "==> FSLogix configured on $($vms.Count) host(s)." -ForegroundColor Green
Write-Host "    If profiles fail to load, check share + NTFS permissions first (docs/gotchas.md)." -ForegroundColor Yellow
