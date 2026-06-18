#requires -Version 7.0
<#
.SYNOPSIS
  Installs the AVD agent + boot loader on each session host and registers them
  to the host pool using a freshly generated registration token.

.DESCRIPTION
  Post-deploy step. The Bicep creates the host pool and the VMs; this generates
  a registration token and runs the AVD agent install on each host so they join
  the pool. Tokens are short-lived, so this is generated at run time, not baked
  into the template.

.PARAMETER ResourceGroup
  Resource group the landing zone was deployed into.
#>
param(
  [Parameter(Mandatory)] [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Locating host pool in $ResourceGroup" -ForegroundColor Cyan
$hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroup | Select-Object -First 1
if (-not $hostPool) { throw "No host pool found in $ResourceGroup." }
Write-Host "    Host pool: $($hostPool.Name)"

Write-Host "==> Generating registration token (valid 2h)" -ForegroundColor Cyan
$token = New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroup `
  -HostPoolName $hostPool.Name `
  -ExpirationTime (Get-Date).AddHours(2).ToUniversalTime().ToString('o')

# AVD agent + boot loader install, run on each host with the token.
$registerScript = @"
`$ErrorActionPreference = 'Stop'
`$base = `$env:TEMP
`$agent = Join-Path `$base 'AVDAgent.msi'
`$boot  = Join-Path `$base 'AVDBootloader.msi'
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -OutFile `$agent
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -OutFile `$boot
Start-Process msiexec -ArgumentList "/i `$agent /quiet REGISTRATIONTOKEN=$($token.Token)" -Wait
Start-Process msiexec -ArgumentList "/i `$boot /quiet" -Wait
"@

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $registerScript

Write-Host "==> Registering session hosts" -ForegroundColor Cyan
$vms = Get-AzVM -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like '*-sh-*' }
if (-not $vms) { throw "No session host VMs (*-sh-*) found in $ResourceGroup." }

foreach ($vm in $vms) {
  Write-Host "    -> $($vm.Name)"
  Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $vm.Name `
    -CommandId 'RunPowerShellScript' -ScriptPath $tmp | Out-Null
}
Remove-Item $tmp -Force

Write-Host "==> Registered $($vms.Count) host(s) to $($hostPool.Name)." -ForegroundColor Green
Write-Host "    Check the host pool blade — hosts should show 'Available' within a few minutes." -ForegroundColor Yellow
