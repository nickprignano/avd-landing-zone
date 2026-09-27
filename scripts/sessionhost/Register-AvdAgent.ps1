<#
.SYNOPSIS
  Installs the AVD Agent and Boot Loader and registers the session host to its
  host pool.

.DESCRIPTION
  Runs on each session host as an Azure managed Run Command, declared in
  bicep/modules/sessionHosts.bicep. The registration token is passed as a
  protected parameter. Idempotent: a host that is already registered is left
  alone; a host with the agent preinstalled (e.g. from a golden image) is
  re-pointed at the new token instead of reinstalled.
#>
param(
  [Parameter(Mandatory)] [string] $RegistrationToken,
  [string] $AgentUri = 'https://go.microsoft.com/fwlink/?linkid=2310011',
  [string] $BootLoaderUri = 'https://go.microsoft.com/fwlink/?linkid=2311028'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$agentKey = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
$state = Get-ItemProperty -Path $agentKey -ErrorAction SilentlyContinue
if ($state -and $state.IsRegistered -eq 1) {
  Write-Output 'Session host is already registered to a host pool; nothing to do.'
  return
}

if (Get-Service -Name RDAgentBootLoader -ErrorAction SilentlyContinue) {
  Write-Output 'Agent present but not registered; applying the new registration token.'
  Set-ItemProperty -Path $agentKey -Name RegistrationToken -Value $RegistrationToken
  Set-ItemProperty -Path $agentKey -Name IsRegistered -Value 0
  Restart-Service -Name RDAgentBootLoader
  return
}

$work = Join-Path $env:SystemRoot 'Temp\avd-agent'
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Install-Msi([string] $Uri, [string] $FileName, [string] $ExtraArgs = '') {
  $path = Join-Path $work $FileName
  for ($i = 1; $i -le 5; $i++) {
    try { Invoke-WebRequest -Uri $Uri -OutFile $path -UseBasicParsing; break }
    catch { if ($i -eq 5) { throw }; Start-Sleep -Seconds (10 * $i) }
  }
  $log = Join-Path $work "$FileName.log"
  $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$path`" /quiet /norestart /l*v `"$log`" $ExtraArgs"
  if ($p.ExitCode -notin 0, 3010) { throw "$FileName failed with exit code $($p.ExitCode). See $log" }
}

Install-Msi $AgentUri 'RDAgent.msi' "REGISTRATIONTOKEN=$RegistrationToken"
Install-Msi $BootLoaderUri 'RDAgentBootLoader.msi'

Remove-Item -Path (Join-Path $work '*.msi') -Force -ErrorAction SilentlyContinue
Write-Output 'AVD Agent and Boot Loader installed; host will appear in the pool within a few minutes.'
