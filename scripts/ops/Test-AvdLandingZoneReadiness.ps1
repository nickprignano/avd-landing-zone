#requires -Version 7.2
<#
.SYNOPSIS
  Preflight for the AVD landing zone, in two stages:
    -PreDeployment   before deploying: is this subscription and tenant ready
                     for the landing zone described by the parameter file?
    (default)        after deploying: is the landing zone ready for session
                     hosts and users, including the three post-deployment
                     tenant steps?
  Check mode by default; -Fix remediates what it can.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) in the landing zone subscription.

  PRE-DEPLOYMENT (-PreDeployment -ParameterFile -UsersGroup -AdminsGroup)
    Tooling        PowerShell, Bicep, az and bash (deploy.sh), Graph module
    Entra ID       the AVD Users/Admins security groups and the Azure Virtual
                   Desktop service principal exist; groups have members
    Parameters     the .bicepparam compiles; effective values are shown.
                   -Location overrides the region (AVD_LOCATION)
    Subscription   your RBAC (incl. policy rights when guardrails are on),
                   resource providers, AVD host pools offered in the region,
                   EncryptionAtHost feature, VM size in
                   the requested zones, vCPU quota, Premium file share SKU in
                   the region, no soft-deleted Key Vault blocking the name,
                   budget parameters
    Network        hub VNet, firewall IP and central DNS zones (HubPeered)
    Landing zone   whether it already exists (deploy updates it in place)
    Tenant         Intune licensing when enrollInIntune = true, your Entra
                   roles for the post-deployment steps, which Conditional
                   Access policies will need the storage app excluded
    -Fix           registers providers and the EncryptionAtHost feature and
                   waits for them (then re-registers Microsoft.Compute),
                   creates missing groups (by name) and the AVD service
                   principal
    -AddMeToGroups adds you to both groups

  POST-DEPLOYMENT (-NamePrefix -Environment)
    Tooling, subscription, landing zone resources, private DNS, RBAC, and:
    Step 1         admin consent for the storage account's Entra app
                   (+ the kdc_enable_cloud_group_sids tag)
    Step 2         the storage app excluded from MFA Conditional Access policies
    Step 3         NTFS permissions on the profile share root (checked from a
                   running session host)
    -Fix           registers providers/feature, grants admin consent, tags the
                   app, excludes the app from the affected CA policies (you
                   confirm each), sets the FSLogix-recommended root ACL

  Exit code 0 = no failures; 1 = at least one failure. Warnings don't fail.

.EXAMPLE
  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location westus2 -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins'

.EXAMPLE
  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'PostDeployment')]
param(
  # ---- Pre-deployment ----
  [Parameter(Mandatory, ParameterSetName = 'PreDeployment')][switch] $PreDeployment,
  [Parameter(Mandatory, ParameterSetName = 'PreDeployment')][string] $ParameterFile,
  # Entra security group name or object ID. With -Fix, a missing group (by name) is created.
  [Parameter(Mandatory, ParameterSetName = 'PreDeployment')][string] $UsersGroup,
  [Parameter(Mandatory, ParameterSetName = 'PreDeployment')][string] $AdminsGroup,
  # Region to check and deploy to, instead of the parameter file's default (e.g. from the region latency page).
  [Parameter(ParameterSetName = 'PreDeployment')][ValidatePattern('^[a-z0-9]+$')][string] $Location,
  # Add the signed-in user to both groups (the desktop, plus admin sign-in to the hosts).
  [Parameter(ParameterSetName = 'PreDeployment')][switch] $AddMeToGroups,

  # ---- Post-deployment ----
  [Parameter(Mandatory, ParameterSetName = 'PostDeployment')][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory, ParameterSetName = 'PostDeployment')][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  # Size and count to check quota for.
  [Parameter(ParameterSetName = 'PostDeployment')][string] $SessionHostVmSize = 'Standard_D4as_v5',
  [Parameter(ParameterSetName = 'PostDeployment')][int] $SessionHostCount = 1,
  # NTFS check: pick the host, or allow starting a stopped one (it is stopped again afterwards).
  [Parameter(ParameterSetName = 'PostDeployment')][string] $NtfsHostName,
  [Parameter(ParameterSetName = 'PostDeployment')][switch] $AllowHostStart,
  [Parameter(ParameterSetName = 'PostDeployment')][switch] $SkipNtfs,

  # ---- Both ----
  [string] $SubscriptionId,
  # Remediate instead of only reporting.
  [switch] $Fix,
  # Skip the per-policy confirmation for Conditional Access changes when fixing.
  [switch] $Force,
  [switch] $SkipTenant,
  # Return the result objects instead of setting an exit code.
  [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult

if ($PreDeployment) {
  if (-not (Test-Path $ParameterFile)) { throw "Parameter file not found: $ParameterFile" }
  Write-Host "AVD landing zone PRE-DEPLOYMENT preflight - $ParameterFile in '$($ctx.Subscription.Name)'$(if ($Fix) { ' (FIX mode)' })" -ForegroundColor White
  $pre = @{ ParameterFile = $ParameterFile; UsersGroup = $UsersGroup; AdminsGroup = $AdminsGroup; Location = $Location; Fix = $Fix; AddMeToGroups = $AddMeToGroups; SkipTenant = $SkipTenant; WhatIf = $WhatIfPreference }
  if ($Force) { $pre.Confirm = $false }
  $outcome = Test-AvdPreDeployment @pre
}
else {
  Write-Host "AVD landing zone preflight - $NamePrefix/$Environment in '$($ctx.Subscription.Name)'$(if ($Fix) { ' (FIX mode)' })" -ForegroundColor White
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
}

$summary = Write-AvdSummary
if ($PassThru) { return $summary }
if ($summary.Failed) {
  Write-Host "Not ready: $($summary.Failed) failure(s).$(if (-not $Fix) { ' Rerun with -Fix to remediate what can be fixed automatically.' })" -ForegroundColor Red
  exit 1
}
Write-Host 'Ready.' -ForegroundColor Green
if ($PreDeployment -and $outcome -and $outcome.Plan) {
  $u = if ($outcome.UsersGroup) { $outcome.UsersGroup.displayName } else { $UsersGroup }
  $a = if ($outcome.AdminsGroup) { $outcome.AdminsGroup.displayName } else { $AdminsGroup }
  Write-Host ''
  Write-Host 'Next, deploy the landing zone as a separate run:' -ForegroundColor White
  Write-Host "  bash ./scripts/deploy/deploy.sh -p $ParameterFile -l $($outcome.Plan.location) --users-group '$u' --admins-group '$a'"
  Write-Host 'Then run the post-deployment preflight:' -ForegroundColor White
  Write-Host "  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix $($outcome.Plan.namePrefix) -Environment $($outcome.Plan.environmentName) -Fix"
}
exit 0
