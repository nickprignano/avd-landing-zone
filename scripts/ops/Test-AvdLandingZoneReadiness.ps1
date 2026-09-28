#requires -Version 7.2
<#
.SYNOPSIS
  Preflight: confirms a deployed landing zone is ready for AVD session hosts and
  users, including the three post-deployment tenant steps. Check mode by
  default; -Fix remediates what it can.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) in the landing zone subscription.

  Checks
    Tooling        PowerShell, Bicep CLI, Microsoft Graph module
    Subscription   your RBAC, resource providers, EncryptionAtHost feature,
                   VM size availability and vCPU quota
    Landing zone   resource groups and core resources, Entra Kerberos on the
                   profile storage, private endpoints and DNS
    RBAC           the AVD Users/Admins groups and AVD service principal the
                   landing zone assigned
    Entra ID       group membership, Intune licensing
    Step 1         admin consent for the storage account's Entra app
                   (+ the kdc_enable_cloud_group_sids tag)
    Step 2         the storage app excluded from MFA Conditional Access policies
    Step 3         NTFS permissions on the profile share root (checked from a
                   running session host)

  -Fix registers providers/features, grants admin consent, tags the app,
  excludes the app from the affected CA policies (you confirm each one), and
  replaces the share root ACL with the FSLogix-recommended one.

  Exit code 0 = no failures; 1 = at least one failure.

.EXAMPLE
  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment prod -Fix -AllowHostStart
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  [string] $SubscriptionId,

  # Remediate instead of only reporting.
  [switch] $Fix,

  # Skip the per-policy confirmation for Conditional Access changes when fixing.
  [switch] $Force,

  # Size and count to check quota for.
  [string] $SessionHostVmSize = 'Standard_D4as_v5',
  [int] $SessionHostCount = 1,

  # NTFS check: pick the host, or allow starting a stopped one (it is stopped again afterwards).
  [string] $NtfsHostName,
  [switch] $AllowHostStart,

  [switch] $SkipTenant,
  [switch] $SkipNtfs,

  # Return the result objects instead of setting an exit code.
  [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Write-Host "AVD landing zone preflight - $NamePrefix/$Environment in '$($ctx.Subscription.Name)'$(if ($Fix) { ' (FIX mode)' })" -ForegroundColor White

Clear-AvdCheckResult
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment

$checkParams = @{
  Lz             = $lz
  Fix            = $Fix
  VmSize         = $SessionHostVmSize
  VmCount        = $SessionHostCount
  SkipTenant     = $SkipTenant
  SkipNtfs       = $SkipNtfs
  NtfsHostName   = $NtfsHostName
  AllowHostStart = $AllowHostStart
  WhatIf         = $WhatIfPreference
}
if ($Force) { $checkParams.Confirm = $false }
Invoke-AvdReadinessCheck @checkParams

$summary = Write-AvdSummary
if ($PassThru) { return $summary }
if ($summary.Failed) {
  Write-Host "Not ready: $($summary.Failed) failure(s).$(if (-not $Fix) { ' Rerun with -Fix to remediate what can be fixed automatically.' })" -ForegroundColor Red
  exit 1
}
Write-Host 'Ready.' -ForegroundColor Green
exit 0
