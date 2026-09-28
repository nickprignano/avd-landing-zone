<#
.SYNOPSIS
  Reads (and optionally sets) the root ACL of the FSLogix profile share.

.DESCRIPTION
  Runs ON a session host through Run Command (Windows PowerShell 5.1), called by
  Test-AvdProfileShareAcl in AvdLandingZone.psm1. Uses the VM's managed identity
  and the Azure Files REST API with backup intent, so it needs no SMB mount and no
  user Kerberos ticket. The caller grants the identity a temporary Storage File
  Data Privileged Reader/Contributor role and removes it afterwards.

  Output is one JSON object between <<<AVDJSON and AVDJSON>>> markers.
#>
param(
  [Parameter(Mandatory)] [string] $StorageFqdn,
  [Parameter(Mandatory)] [string] $ShareName,
  [string] $DesiredSddlBase64 = '',
  [string] $Apply = 'false'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Result([hashtable] $Result) {
  Write-Output ('<<<AVDJSON' + ($Result | ConvertTo-Json -Compress -Depth 5) + 'AVDJSON>>>')
}

try {
  $imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F'
  $token = (Invoke-RestMethod -UseBasicParsing -Headers @{ Metadata = 'true' } -Uri $imds).access_token
}
catch {
  Write-Result @{ status = 'NoIdentity'; error = "Managed identity token request failed: $($_.Exception.Message)" }
  return
}

$headers = @{
  Authorization              = "Bearer $token"
  'x-ms-version'             = '2023-11-03'
  'x-ms-file-request-intent' = 'backup'
}
$base = "https://$StorageFqdn/$ShareName"

function Get-RootSddl {
  $dir = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($base + '?restype=directory') -Headers $headers
  $h = $headers.Clone()
  $h['x-ms-file-permission-key'] = [string]$dir.Headers['x-ms-file-permission-key']
  (Invoke-RestMethod -UseBasicParsing -Method Get -Uri ($base + '?restype=share&comp=filepermission') -Headers $h).permission
}

try {
  $before = Get-RootSddl
  $after = $null
  if ($Apply -eq 'true') {
    $sddl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($DesiredSddlBase64))
    $body = @{ permission = $sddl } | ConvertTo-Json -Compress
    $created = Invoke-WebRequest -UseBasicParsing -Method Put -Uri ($base + '?restype=share&comp=filepermission') `
      -Headers $headers -Body $body -ContentType 'application/json'
    $h = $headers.Clone()
    $h['x-ms-file-permission-key'] = [string]$created.Headers['x-ms-file-permission-key']
    $h['x-ms-file-attributes'] = 'preserve'
    $h['x-ms-file-creation-time'] = 'preserve'
    $h['x-ms-file-last-write-time'] = 'preserve'
    Invoke-WebRequest -UseBasicParsing -Method Put -Uri ($base + '?restype=directory&comp=properties') -Headers $h | Out-Null
    $after = Get-RootSddl
  }
  Write-Result @{ status = 'ok'; before = $before; after = $after }
}
catch {
  $code = $null
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  $status = 'Error'
  if ($code -eq 403) { $status = 'Forbidden' }
  Write-Result @{ status = $status; httpStatus = $code; error = $_.Exception.Message }
}
