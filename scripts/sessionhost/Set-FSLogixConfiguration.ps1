<#
.SYNOPSIS
  Configures FSLogix profile containers on an Entra ID-joined AVD session host
  against an Azure Files share that uses Entra Kerberos.

.DESCRIPTION
  Runs on each session host as an Azure managed Run Command, declared in
  bicep/modules/sessionHosts.bicep (the script is embedded at compile time,
  nothing is downloaded at deploy time). Idempotent: safe to re-run.
#>
param(
  [Parameter(Mandatory)] [string] $ProfileShareUncPath,
  [int] $ProfileSizeMiB = 30720,
  [string] $LocalAdminUsername = ''
)

$ErrorActionPreference = 'Stop'

function Write-RegValue([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord') {
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# FSLogix ships in the AVD marketplace images; fail loudly if a custom image lacks it.
if (-not (Get-Service -Name frxsvc -ErrorAction SilentlyContinue)) {
  throw 'FSLogix (frxsvc) is not installed on this image.'
}

# --- Entra Kerberos: let the host fetch cloud Kerberos tickets for Azure Files ---
Write-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled' 1
Write-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' 'LoadCredKeyFromProfile' 1

# --- FSLogix profile container ---
$fsl = 'HKLM:\SOFTWARE\FSLogix\Profiles'
Write-RegValue $fsl 'VHDLocations' @($ProfileShareUncPath) 'MultiString'
Write-RegValue $fsl 'VolumeType' 'VHDX' 'String'
$dwords = [ordered]@{
  Enabled                              = 1
  SizeInMBs                            = $ProfileSizeMiB
  IsDynamic                            = 1
  DeleteLocalProfileWhenVHDShouldApply = 1
  FlipFlopProfileDirectoryName         = 1
  PreventLoginWithFailure              = 1
  PreventLoginWithTempProfile          = 1
  LockedRetryCount                     = 3
  LockedRetryInterval                  = 15
  ReAttachRetryCount                   = 3
  ReAttachIntervalSeconds              = 15
  RoamRecycleBin                       = 0
}
foreach ($k in $dwords.Keys) { Write-RegValue $fsl $k $dwords[$k] }

# --- Keep the break-glass account out of profile containers ---
# (Get-LocalGroupMember is avoided: it throws on unresolvable Entra SIDs in Windows PowerShell 5.1.)
if ($LocalAdminUsername) {
  try { Add-LocalGroupMember -Group 'FSLogix Profile Exclude List' -Member $LocalAdminUsername -ErrorAction Stop }
  catch [Microsoft.PowerShell.Commands.MemberExistsException] { Write-Output "$LocalAdminUsername already excluded." }
}

# --- Microsoft-recommended Defender exclusions for FSLogix ---
# Tamper protection or MDE policy may own exclusions; don't fail the host over it.
try {
  $share = $ProfileShareUncPath.TrimEnd('\')
  Add-MpPreference -ExclusionPath @(
    '%TEMP%\*\*.VHD', '%TEMP%\*\*.VHDX',
    '%Windir%\TEMP\*\*.VHD', '%Windir%\TEMP\*\*.VHDX',
    "$share\*\*.VHD", "$share\*\*.VHD.lock", "$share\*\*.VHD.meta", "$share\*\*.VHD.metadata",
    "$share\*\*.VHDX", "$share\*\*.VHDX.lock", "$share\*\*.VHDX.meta", "$share\*\*.VHDX.metadata"
  )
  Add-MpPreference -ExclusionProcess @(
    '%ProgramFiles%\FSLogix\Apps\frxccd.exe',
    '%ProgramFiles%\FSLogix\Apps\frxccds.exe',
    '%ProgramFiles%\FSLogix\Apps\frxsvc.exe'
  )
} catch {
  Write-Warning "Defender exclusions not applied (likely policy-managed): $($_.Exception.Message)"
}

Write-Output "FSLogix configured for $ProfileShareUncPath"
