#requires -Version 7.2
<#
  Shared functions for the landing-zone operations scripts:
    Test-AvdLandingZoneReadiness.ps1  preflight (check / -Fix)
    Deploy-AvdDemo.ps1                demo host pool + login-readiness validation
    Remove-AvdDemo.ps1                cleanup

  Designed for Azure Cloud Shell (PowerShell): Az modules are already signed
  in there, and Microsoft Graph is reached through Microsoft.Graph.Authentication
  (device-code sign-in in Cloud Shell).
#>

# =====================================================================
# Result reporting
# =====================================================================
$script:Results = [System.Collections.Generic.List[object]]::new()

function Clear-AvdCheckResult { $script:Results.Clear() }

function Get-AvdCheckResult { , $script:Results.ToArray() }

function Write-AvdSection {
  param([Parameter(Mandatory)][string] $Title)
  Write-Host ''
  Write-Host "== $Title" -ForegroundColor White
}

function Add-AvdCheckResult {
  param(
    [Parameter(Mandatory)][string] $Area,
    [Parameter(Mandatory)][string] $Check,
    [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Fixed', 'Skip')][string] $Status,
    [string] $Detail = '',
    [string] $Remediation = ''
  )
  $script:Results.Add([pscustomobject]@{
      Area        = $Area
      Check       = $Check
      Status      = $Status
      Detail      = $Detail
      Remediation = $Remediation
    })
  $color = @{ Pass = 'Green'; Fixed = 'Cyan'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Status]
  Write-Host ('  [{0,-5}] {1}' -f $Status.ToUpper(), $Check) -ForegroundColor $color
  if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
  if ($Remediation -and $Status -in 'Fail', 'Warn') { Write-Host "          -> $Remediation" -ForegroundColor DarkYellow }
}

function Write-AvdSummary {
  $all = Get-AvdCheckResult
  $counts = $all | Group-Object Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
  Write-Host ''
  Write-Host "== Summary: $($counts -join ', ')" -ForegroundColor White
  $open = @($all | Where-Object Status -in 'Fail', 'Warn')
  if ($open.Count) {
    $open | Format-Table Status, Area, Check, Remediation -AutoSize -Wrap | Out-String -Width 200 | Write-Host
  }
  return [pscustomobject]@{
    Failed  = @($all | Where-Object Status -eq 'Fail').Count
    Warned  = @($all | Where-Object Status -eq 'Warn').Count
    Results = $all
  }
}

# =====================================================================
# Azure context, ARM and Graph helpers
# =====================================================================
function Test-AvdCloudShell {
  [bool]$env:ACC_CLOUD -or ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*')
}

function Initialize-AvdAzContext {
  param([string] $SubscriptionId)
  foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Storage') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "PowerShell module $m is required (preinstalled in Azure Cloud Shell)." }
  }
  $ctx = Get-AzContext
  if (-not $ctx) { throw 'Not signed in to Azure. Run Connect-AzAccount (Cloud Shell does this for you).' }
  if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
    $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
  }
  return $ctx
}

function Invoke-AvdArm {
  param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('GET', 'PUT', 'PATCH', 'DELETE', 'POST')][string] $Method = 'GET',
    [object] $Body,
    [switch] $AllowNotFound
  )
  $p = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
  if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 30 -Compress) }
  $r = Invoke-AzRestMethod @p
  if ($AllowNotFound -and $r.StatusCode -eq 404) { return $null }
  if ($r.StatusCode -ge 400) { throw "ARM $Method $Path failed ($($r.StatusCode)): $($r.Content)" }
  if ($r.Content) { return $r.Content | ConvertFrom-Json -Depth 30 }
}

$script:GraphReadScopes = @('Application.Read.All', 'Policy.Read.All', 'Group.Read.All', 'Directory.Read.All')
$script:GraphFixScopes = @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Group.Read.All', 'Directory.Read.All')
$script:GraphCleanupScopes = @('Device.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All')

function Connect-AvdGraph {
  param([ValidateSet('Read', 'Fix', 'Cleanup')][string] $Purpose = 'Read')
  $scopes = switch ($Purpose) {
    'Read' { $script:GraphReadScopes }
    'Fix' { $script:GraphFixScopes }
    'Cleanup' { $script:GraphCleanupScopes }
  }
  if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
  }
  Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
  $tenantId = (Get-AzContext).Tenant.Id
  $ctx = Get-MgContext
  if ($ctx -and $ctx.TenantId -eq $tenantId -and -not ($scopes | Where-Object { $_ -notin $ctx.Scopes })) { return }
  Write-Host "  Signing in to Microsoft Graph ($($scopes -join ', '))" -ForegroundColor DarkGray
  $connect = @{ Scopes = $scopes; TenantId = $tenantId; NoWelcome = $true; ErrorAction = 'Stop' }
  if (Test-AvdCloudShell) { $connect.UseDeviceCode = $true }
  Connect-MgGraph @connect | Out-Null
}

function Invoke-AvdGraph {
  param(
    [Parameter(Mandatory)][string] $Uri,
    [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method = 'GET',
    [object] $Body
  )
  $p = @{ Method = $Method; OutputType = 'PSObject'; ErrorAction = 'Stop' }
  if ($null -ne $Body) {
    $p.Body = ($Body | ConvertTo-Json -Depth 30)
    $p.ContentType = 'application/json'
  }
  if ($Method -ne 'GET') { return Invoke-MgGraphRequest @p -Uri $Uri }
  $items = [System.Collections.Generic.List[object]]::new()
  $next = $Uri
  while ($next) {
    $r = Invoke-MgGraphRequest @p -Uri $next
    if ($r.PSObject.Properties['value']) {
      foreach ($v in $r.value) { $items.Add($v) }
      $link = $r.PSObject.Properties['@odata.nextLink']
      $next = if ($link) { $link.Value } else { $null }
    }
    else { return $r }
  }
  return , $items.ToArray()
}

function Get-AvdGraphFilterUri {
  param([Parameter(Mandatory)][string] $Collection, [Parameter(Mandatory)][string] $Filter, [string] $Select)
  $uri = "v1.0/$Collection`?`$filter=$([uri]::EscapeDataString($Filter))"
  if ($Select) { $uri += "&`$select=$Select" }
  return $uri
}

# =====================================================================
# Identity helpers
# =====================================================================
function ConvertTo-AvdEntraSid {
  <# The SID Windows and Azure Files use for a cloud (Entra ID) object. #>
  param([Parameter(Mandatory)][guid] $ObjectId)
  $bytes = $ObjectId.ToByteArray()
  $parts = 0..3 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $_ * 4) }
  return "S-1-12-1-$($parts -join '-')"
}

function Get-AvdGroupSid {
  <# Synced groups keep their AD SID in Kerberos tickets; cloud groups use the S-1-12-1 form. #>
  param([Parameter(Mandatory)][string] $GroupId)
  $g = Invoke-AvdGraph -Uri "v1.0/groups/$GroupId`?`$select=id,displayName,onPremisesSecurityIdentifier"
  $sid = if ($g.onPremisesSecurityIdentifier) { $g.onPremisesSecurityIdentifier } else { ConvertTo-AvdEntraSid $g.id }
  return [pscustomobject]@{ Id = $g.id; DisplayName = $g.displayName; Sid = $sid; Synced = [bool]$g.onPremisesSecurityIdentifier }
}

function Get-AvdRandomPassword {
  <# 24 random characters with every Windows complexity class, as a SecureString. #>
  param([int] $Length = 24)
  $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%*-_=+?')
  $all = -join $sets
  $chars = [System.Collections.Generic.List[char]]::new()
  foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
  while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
  $secure = [System.Security.SecureString]::new()
  $chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) } | ForEach-Object { $secure.AppendChar($_) }
  $secure.MakeReadOnly()
  return $secure
}

# =====================================================================
# Landing zone discovery
# =====================================================================
function Get-AvdRoleAssigneeId {
  <# Object ID holding a role at exactly this scope (not inherited). #>
  param([Parameter(Mandatory)][string] $Scope, [Parameter(Mandatory)][string] $RoleName, [string] $ObjectType)
  $a = Get-AzRoleAssignment -Scope $Scope -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue |
    Where-Object { $_.Scope -eq $Scope -and (-not $ObjectType -or $_.ObjectType -eq $ObjectType) } |
    Select-Object -First 1
  if ($a) { return $a.ObjectId }
}

function Get-AvdPrivateEndpointDnsZoneId {
  <# Private DNS zone behind the private endpoint that fronts $TargetResourceId, or $null. #>
  param([Parameter(Mandatory)][string] $ResourceGroupId, [Parameter(Mandatory)][string] $TargetResourceId)
  $pes = Invoke-AvdArm -Path "$ResourceGroupId/providers/Microsoft.Network/privateEndpoints?api-version=2024-05-01"
  foreach ($pe in @($pes.value)) {
    $targets = @($pe.properties.privateLinkServiceConnections) + @($pe.properties.manualPrivateLinkServiceConnections) |
      Where-Object { $_ } | ForEach-Object { $_.properties.privateLinkServiceId }
    if ($targets -contains $TargetResourceId) {
      $groups = Invoke-AvdArm -Path "$($pe.id)/privateDnsZoneGroups?api-version=2024-05-01"
      $zone = @($groups.value) | ForEach-Object { $_.properties.privateDnsZoneConfigs } | Select-Object -First 1
      return [pscustomobject]@{ PrivateEndpointId = $pe.id; DnsZoneId = if ($zone) { $zone.properties.privateDnsZoneId } else { $null } }
    }
  }
}

function Get-AvdLandingZone {
  <#
    Finds every landing-zone resource the scripts need from the naming
    convention in bicep/main.bicep, and the Entra groups / AVD service
    principal from the role assignments the landing zone created.
  #>
  param(
    [Parameter(Mandatory)][string] $NamePrefix,
    [Parameter(Mandatory)][string] $Environment,
    [string] $ProfileShareName = 'profiles'
  )
  $ctx = Get-AzContext
  $clean = $NamePrefix.ToLower().Replace('-', '')
  $base = "$clean-$Environment"
  $sub = "/subscriptions/$($ctx.Subscription.Id)"
  $rg = [ordered]@{
    Network      = "rg-$base-network"
    Management   = "rg-$base-management"
    Storage      = "rg-$base-storage"
    ControlPlane = "rg-$base-avd"
    Hosts        = "rg-$base-hosts"
    Demo         = "rg-$base-demo"
  }
  $existingRgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ResourceGroupName)
  $rgExists = @{}; foreach ($k in $rg.Keys) { $rgExists[$k] = $existingRgs -contains $rg[$k] }

  $lz = [ordered]@{
    NamePrefix       = $clean
    Environment      = $Environment
    BaseName         = $base
    SubscriptionId   = $ctx.Subscription.Id
    TenantId         = $ctx.Tenant.Id
    ResourceGroups   = $rg
    ResourceGroupIds = @{}
    RgExists         = $rgExists
    Location         = $null
    Vnet             = $null
    SessionHostSubnetId     = $null
    PrivateEndpointSubnetId = $null
    StorageAccount   = $null
    StorageFqdn      = $null
    ProfileShareName = $ProfileShareName
    ProfileShareUnc  = $null
    KeyVault         = $null
    LogAnalyticsId   = $null
    DataCollectionRuleId = $null
    HostPool         = $null
    AppGroup         = $null
    AvdDnsZoneId     = $null
    StorageDnsZoneId = $null
    UsersGroupId     = $null
    AdminsGroupId    = $null
    AvdServicePrincipalId = $null
    RecoveryVault    = $null
  }
  foreach ($k in $rg.Keys) { $lz.ResourceGroupIds[$k] = "$sub/resourceGroups/$($rg[$k])" }

  if ($rgExists.Network) {
    $lz.Vnet = Get-AzResource -ResourceGroupName $rg.Network -ResourceType Microsoft.Network/virtualNetworks -Name "vnet-$base" -ErrorAction SilentlyContinue
    if ($lz.Vnet) {
      $lz.Location = $lz.Vnet.Location
      $lz.SessionHostSubnetId = "$($lz.Vnet.ResourceId)/subnets/snet-session-hosts"
      $lz.PrivateEndpointSubnetId = "$($lz.Vnet.ResourceId)/subnets/snet-private-endpoints"
    }
  }
  if ($rgExists.Storage) {
    $lz.StorageAccount = Get-AzStorageAccount -ResourceGroupName $rg.Storage -ErrorAction SilentlyContinue |
      Where-Object Kind -eq 'FileStorage' | Select-Object -First 1
    if ($lz.StorageAccount) {
      $lz.StorageFqdn = "$($lz.StorageAccount.StorageAccountName).file.$($ctx.Environment.StorageEndpointSuffix)"
      $lz.ProfileShareUnc = "\\$($lz.StorageFqdn)\$ProfileShareName"
      if ($rgExists.Network) {
        $pe = Get-AvdPrivateEndpointDnsZoneId -ResourceGroupId $lz.ResourceGroupIds.Network -TargetResourceId $lz.StorageAccount.Id
        if ($pe) { $lz.StorageDnsZoneId = $pe.DnsZoneId }
      }
    }
    $lz.RecoveryVault = Get-AzResource -ResourceGroupName $rg.Storage -ResourceType Microsoft.RecoveryServices/vaults -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($rgExists.Management) {
    $lz.KeyVault = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.KeyVault/vaults -ErrorAction SilentlyContinue | Select-Object -First 1
    $law = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.OperationalInsights/workspaces -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($law) { $lz.LogAnalyticsId = $law.ResourceId }
    $dcr = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.Insights/dataCollectionRules -ErrorAction SilentlyContinue |
      Where-Object Name -like 'microsoft-avdi-*' | Select-Object -First 1
    if ($dcr) { $lz.DataCollectionRuleId = $dcr.ResourceId }
  }
  if ($rgExists.ControlPlane) {
    $lz.HostPool = Get-AzResource -ResourceGroupName $rg.ControlPlane -ResourceType Microsoft.DesktopVirtualization/hostPools -ErrorAction SilentlyContinue | Select-Object -First 1
    $lz.AppGroup = Get-AzResource -ResourceGroupName $rg.ControlPlane -ResourceType Microsoft.DesktopVirtualization/applicationGroups -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lz.AppGroup) { $lz.UsersGroupId = Get-AvdRoleAssigneeId -Scope $lz.AppGroup.ResourceId -RoleName 'Desktop Virtualization User' -ObjectType Group }
    $lz.AvdServicePrincipalId = Get-AvdRoleAssigneeId -Scope $lz.ResourceGroupIds.ControlPlane -RoleName 'Desktop Virtualization Power On Off Contributor'
    if ($lz.HostPool -and $rgExists.Network) {
      $pe = Get-AvdPrivateEndpointDnsZoneId -ResourceGroupId $lz.ResourceGroupIds.Network -TargetResourceId $lz.HostPool.ResourceId
      if ($pe) { $lz.AvdDnsZoneId = $pe.DnsZoneId }
    }
  }
  if ($rgExists.Hosts) {
    $lz.AdminsGroupId = Get-AvdRoleAssigneeId -Scope $lz.ResourceGroupIds.Hosts -RoleName 'Virtual Machine Administrator Login' -ObjectType Group
  }
  return [pscustomobject]$lz
}

# =====================================================================
# Checks - subscription
# =====================================================================
function Test-AvdTooling {
  $area = 'Tooling'
  Add-AvdCheckResult $area "PowerShell $($PSVersionTable.PSVersion)" 'Pass'
  if (Test-AvdCloudShell) { Add-AvdCheckResult $area 'Running in Azure Cloud Shell' 'Pass' }
  else { Add-AvdCheckResult $area 'Not running in Azure Cloud Shell' 'Warn' -Detail 'Supported, but Cloud Shell is the tested environment.' }
  $bicep = Get-Command bicep -ErrorAction SilentlyContinue
  if ($bicep) { Add-AvdCheckResult $area 'Bicep CLI on PATH' 'Pass' -Detail $bicep.Source }
  else { Add-AvdCheckResult $area 'Bicep CLI on PATH' 'Warn' -Detail 'Needed by Deploy-AvdDemo.ps1 (New-AzSubscriptionDeployment).' -Remediation 'Install from https://aka.ms/bicep-install or use Cloud Shell.' }
  if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) { Add-AvdCheckResult $area 'Microsoft.Graph.Authentication module' 'Pass' }
  else { Add-AvdCheckResult $area 'Microsoft.Graph.Authentication module' 'Fail' -Remediation 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
}

function Test-AvdCallerPermission {
  param([Parameter(Mandatory)][string] $SubscriptionId)
  $area = 'Subscription'
  $scope = "/subscriptions/$SubscriptionId"
  try {
    $me = Get-AzADUser -SignedIn -ErrorAction Stop
    $roles = @(Get-AzRoleAssignment -ObjectId $me.Id -Scope $scope -ExpandPrincipalGroups -ErrorAction Stop |
        Where-Object { $scope.StartsWith($_.Scope, [StringComparison]::OrdinalIgnoreCase) -or $_.Scope -eq '/' -or $_.Scope -like '/providers/Microsoft.Management/managementGroups/*' } |
        Select-Object -ExpandProperty RoleDefinitionName -Unique)
    $canWrite = $roles -contains 'Owner' -or $roles -contains 'Contributor'
    $canAssign = $roles -contains 'Owner' -or $roles -contains 'User Access Administrator' -or $roles -contains 'Role Based Access Control Administrator'
    if ($canWrite -and $canAssign) { Add-AvdCheckResult $area "Caller $($me.UserPrincipalName) can deploy and assign roles" 'Pass' -Detail ($roles -join ', ') }
    else { Add-AvdCheckResult $area "Caller $($me.UserPrincipalName) lacks deploy/role-assignment rights" 'Fail' -Detail "Roles: $($roles -join ', ')" -Remediation 'Needs Owner, or Contributor + Role Based Access Control Administrator, on the subscription.' }
  }
  catch {
    Add-AvdCheckResult $area 'Caller permissions' 'Warn' -Detail "Could not evaluate: $($_.Exception.Message)"
  }
}

function Test-AvdResourceProvider {
  [CmdletBinding(SupportsShouldProcess)]
  param([switch] $Fix)
  $area = 'Subscription'
  $namespaces = 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Storage', 'Microsoft.Network',
  'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.KeyVault', 'Microsoft.RecoveryServices', 'Microsoft.GuestConfiguration'
  foreach ($ns in $namespaces) {
    $state = (Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
    if ($state -eq 'Registered') { Add-AvdCheckResult $area "Provider $ns registered" 'Pass'; continue }
    if ($state -eq 'Registering') { Add-AvdCheckResult $area "Provider $ns registered" 'Warn' -Detail 'Registration in progress.' -Remediation 'Wait a few minutes and rerun.'; continue }
    if ($Fix -and $PSCmdlet.ShouldProcess($ns, 'Register resource provider')) {
      Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
      Add-AvdCheckResult $area "Provider $ns registered" 'Fixed' -Detail 'Registration started; it completes in the background.'
    }
    else { Add-AvdCheckResult $area "Provider $ns registered" 'Fail' -Detail "State: $state" -Remediation "Register-AzResourceProvider -ProviderNamespace $ns (or rerun with -Fix)" }
  }
  $feature = Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost -ErrorAction SilentlyContinue
  if ($feature.RegistrationState -eq 'Registered') { Add-AvdCheckResult $area 'Feature Microsoft.Compute/EncryptionAtHost registered' 'Pass' }
  elseif ($feature.RegistrationState -eq 'Registering') { Add-AvdCheckResult $area 'Feature Microsoft.Compute/EncryptionAtHost registered' 'Warn' -Detail 'Registration in progress (can take ~15 minutes).' -Remediation 'Wait, then run Register-AzResourceProvider -ProviderNamespace Microsoft.Compute.' }
  elseif ($Fix -and $PSCmdlet.ShouldProcess('Microsoft.Compute/EncryptionAtHost', 'Register feature')) {
    Register-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost | Out-Null
    Add-AvdCheckResult $area 'Feature Microsoft.Compute/EncryptionAtHost registered' 'Fixed' -Detail 'Registration can take ~15 minutes; re-register Microsoft.Compute afterwards.'
  }
  else { Add-AvdCheckResult $area 'Feature Microsoft.Compute/EncryptionAtHost registered' 'Fail' -Detail "State: $($feature.RegistrationState)" -Remediation 'Rerun with -Fix, or set encryptionAtHost = false.' }
}

function Test-AvdVmCapacity {
  param([Parameter(Mandatory)][string] $Location, [Parameter(Mandatory)][string] $VmSize, [int] $Count = 1)
  $area = 'Subscription'
  $sku = Get-AzComputeResourceSku -Location $Location -ErrorAction SilentlyContinue |
    Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } | Select-Object -First 1
  if (-not $sku) { Add-AvdCheckResult $area "VM size $VmSize offered in $Location" 'Fail' -Remediation 'Choose a size available in the region.'; return }
  $blocked = @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' })
  if ($blocked | Where-Object Type -eq 'Location') {
    Add-AvdCheckResult $area "VM size $VmSize available to this subscription" 'Fail' -Remediation 'Request access to the size or choose another.'
    return
  }
  $zoneBlocked = @($blocked | Where-Object Type -eq 'Zone' | ForEach-Object { $_.RestrictionInfo.Zones })
  if ($zoneBlocked.Count) { Add-AvdCheckResult $area "VM size $VmSize zones" 'Warn' -Detail "Not available in zone(s): $($zoneBlocked -join ', ')" -Remediation 'Narrow availabilityZones.' }
  else { Add-AvdCheckResult $area "VM size $VmSize available in $Location" 'Pass' }

  $vcpu = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value)
  $need = $vcpu * $Count
  $usage = Get-AzVMUsage -Location $Location
  foreach ($name in @($sku.Family, 'cores')) {
    $u = $usage | Where-Object { $_.Name.Value -eq $name } | Select-Object -First 1
    if (-not $u) { continue }
    $free = $u.Limit - $u.CurrentValue
    $label = if ($name -eq 'cores') { 'Regional vCPU quota' } else { "$name vCPU quota" }
    if ($free -ge $need) { Add-AvdCheckResult $area $label 'Pass' -Detail "$free free, $need needed" }
    else { Add-AvdCheckResult $area $label 'Fail' -Detail "$free free, $need needed" -Remediation 'Request a quota increase (Portal > Quotas) or reduce host count/size.' }
  }
}

# =====================================================================
# Checks - landing zone resources and RBAC
# =====================================================================
function Test-AvdLandingZoneResource {
  param([Parameter(Mandatory)] $Lz)
  $area = 'Landing zone'
  foreach ($k in 'Network', 'Management', 'Storage', 'ControlPlane', 'Hosts') {
    if ($Lz.RgExists[$k]) { Add-AvdCheckResult $area "Resource group $($Lz.ResourceGroups[$k])" 'Pass' }
    else { Add-AvdCheckResult $area "Resource group $($Lz.ResourceGroups[$k])" 'Fail' -Remediation 'Deploy the landing zone first (scripts/deploy/deploy.sh), or check -NamePrefix/-Environment.' }
  }
  $items = [ordered]@{
    'Spoke VNet'                 = $Lz.Vnet
    'Profile storage account'    = $Lz.StorageAccount
    'Key Vault'                  = $Lz.KeyVault
    'Log Analytics workspace'    = $Lz.LogAnalyticsId
    'AVD Insights DCR'           = $Lz.DataCollectionRuleId
    'Landing zone host pool'     = $Lz.HostPool
  }
  foreach ($k in $items.Keys) {
    if ($items[$k]) { Add-AvdCheckResult $area $k 'Pass' } else { Add-AvdCheckResult $area $k 'Fail' -Remediation 'Redeploy the landing zone.' }
  }

  $sa = $Lz.StorageAccount
  if ($sa) {
    $auth = $sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
    if ($auth -eq 'AADKERB') { Add-AvdCheckResult $area 'Storage uses Entra Kerberos (AADKERB)' 'Pass' }
    else { Add-AvdCheckResult $area 'Storage uses Entra Kerberos (AADKERB)' 'Fail' -Detail "DirectoryServiceOptions: $auth" -Remediation 'Redeploy the landing zone storage module.' }
    if ($sa.PublicNetworkAccess -eq 'Disabled') { Add-AvdCheckResult $area 'Storage public network access disabled' 'Pass' }
    else { Add-AvdCheckResult $area 'Storage public network access disabled' 'Warn' -Detail "PublicNetworkAccess: $($sa.PublicNetworkAccess)" }
    if ($Lz.StorageDnsZoneId) { Add-AvdCheckResult $area 'Storage private endpoint with DNS zone group' 'Pass' -Detail ($Lz.StorageDnsZoneId -split '/')[-1] }
    else { Add-AvdCheckResult $area 'Storage private endpoint with DNS zone group' 'Fail' -Remediation 'Profiles will not resolve privately. Check the storage private endpoint.' }
  }
  if ($Lz.HostPool) {
    $hpAccess = (Get-AzResource -ResourceId $Lz.HostPool.ResourceId -ExpandProperties).Properties.publicNetworkAccess
    if ($hpAccess -eq 'EnabledForClientsOnly' -and -not $Lz.AvdDnsZoneId) {
      Add-AvdCheckResult $area 'AVD Private Link DNS zone' 'Fail' -Detail 'Host pool is private for session hosts but its endpoint has no DNS zone.' -Remediation 'Link privatelink.wvd.microsoft.com to the spoke or pass central zones.'
    }
    elseif ($Lz.AvdDnsZoneId) { Add-AvdCheckResult $area 'AVD Private Link DNS zone' 'Pass' -Detail ($Lz.AvdDnsZoneId -split '/')[-1] }
    else { Add-AvdCheckResult $area 'AVD Private Link' 'Pass' -Detail 'Not in use (host pool public).' }
  }
}

function Test-AvdLandingZoneRbac {
  param([Parameter(Mandatory)] $Lz)
  $area = 'RBAC'
  $ids = [ordered]@{
    'AVD Users group (Desktop Virtualization User on app group)'  = $Lz.UsersGroupId
    'AVD Admins group (VM Administrator Login on hosts RG)'        = $Lz.AdminsGroupId
    'AVD service principal (Power On Off Contributor on avd RG)'   = $Lz.AvdServicePrincipalId
  }
  foreach ($k in $ids.Keys) {
    if ($ids[$k]) { Add-AvdCheckResult $area $k 'Pass' -Detail $ids[$k] }
    else { Add-AvdCheckResult $area $k 'Fail' -Remediation 'Redeploy the landing zone; the demo reuses these assignments.' }
  }
  if ($Lz.StorageAccount -and $Lz.UsersGroupId) {
    $hasSmb = Get-AvdRoleAssigneeId -Scope $Lz.StorageAccount.Id -RoleName 'Storage File Data SMB Share Contributor' -ObjectType Group
    if ($hasSmb -eq $Lz.UsersGroupId) { Add-AvdCheckResult $area 'AVD Users have SMB Share Contributor on the profile storage' 'Pass' }
    else { Add-AvdCheckResult $area 'AVD Users have SMB Share Contributor on the profile storage' 'Fail' -Remediation 'Redeploy the landing zone storage module.' }
  }
}

# =====================================================================
# Checks - Entra tenant (the three post-deployment steps live here)
# =====================================================================
function Get-AvdStorageKerberosApp {
  param([Parameter(Mandatory)] $Lz)
  $name = "[Storage Account] $($Lz.StorageFqdn)"
  $app = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection applications -Filter "displayName eq '$name'" -Select 'id,appId,displayName,tags,requiredResourceAccess') | Select-Object -First 1
  if (-not $app) { return $null }
  $sp = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection servicePrincipals -Filter "appId eq '$($app.appId)'" -Select 'id,appId,displayName') | Select-Object -First 1
  return [pscustomobject]@{ Name = $name; Application = $app; ServicePrincipal = $sp }
}

function Test-AvdGroupMembership {
  param([Parameter(Mandatory)] $Lz)
  $area = 'Entra ID'
  foreach ($pair in @(@('AVD Users', $Lz.UsersGroupId), @('AVD Admins', $Lz.AdminsGroupId))) {
    if (-not $pair[1]) { continue }
    try {
      $g = Invoke-AvdGraph -Uri "v1.0/groups/$($pair[1])`?`$select=id,displayName,securityEnabled"
      $members = Invoke-AvdGraph -Uri "v1.0/groups/$($pair[1])/members?`$select=id&`$top=1"
      $detail = "$($g.displayName) ($($g.id))"
      if (@($members).Count) { Add-AvdCheckResult $area "$($pair[0]) group has members" 'Pass' -Detail $detail }
      else { Add-AvdCheckResult $area "$($pair[0]) group has members" 'Warn' -Detail $detail -Remediation 'Add at least one user so someone can sign in.' }
    }
    catch { Add-AvdCheckResult $area "$($pair[0]) group readable" 'Fail' -Detail $_.Exception.Message }
  }
}

function Test-AvdIntuneLicense {
  $area = 'Entra ID'
  try {
    $skus = Invoke-AvdGraph -Uri 'v1.0/subscribedSkus'
    $intune = @($skus | ForEach-Object { $_.servicePlans } | Where-Object { $_.servicePlanName -like 'INTUNE_A*' -and $_.provisioningStatus -eq 'Success' })
    if ($intune.Count) { Add-AvdCheckResult $area 'Tenant has Intune licensing' 'Pass' }
    else { Add-AvdCheckResult $area 'Tenant has Intune licensing' 'Warn' -Detail 'Intune enrollment (enrollInIntune = true) will fail without it.' -Remediation 'License Intune, or deploy with enrollInIntune = false.' }
  }
  catch { Add-AvdCheckResult $area 'Tenant Intune licensing' 'Warn' -Detail "Could not read subscribed SKUs: $($_.Exception.Message)" }
}

function Test-AvdStorageAdminConsent {
  <# Post-deployment step 1: admin consent for the storage account's Entra Kerberos app. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 1: admin consent'
  $graphAppId = '00000003-0000-0000-c000-000000000000'
  $graphSp = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection servicePrincipals -Filter "appId eq '$graphAppId'" -Select 'id,oauth2PermissionScopes') | Select-Object -First 1

  # Scopes the app registration asks for on Microsoft Graph (normally openid, profile, User.Read).
  $required = @('openid', 'profile', 'User.Read')
  $rra = @($StorageApp.Application.requiredResourceAccess | Where-Object resourceAppId -eq $graphAppId)
  if ($rra.Count) {
    $ids = @($rra.resourceAccess | Where-Object type -eq 'Scope' | ForEach-Object id)
    $named = @($graphSp.oauth2PermissionScopes | Where-Object { $ids -contains $_.id } | ForEach-Object value)
    if ($named.Count) { $required = $named }
  }

  $grants = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection oauth2PermissionGrants -Filter "clientId eq '$($StorageApp.ServicePrincipal.id)'")
  $grant = @($grants | Where-Object { $_.consentType -eq 'AllPrincipals' -and $_.resourceId -eq $graphSp.id }) | Select-Object -First 1
  $have = if ($grant) { @($grant.scope -split ' ' | Where-Object { $_ }) } else { @() }
  $missing = @($required | Where-Object { $have -notcontains $_ })

  if (-not $missing.Count) {
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Pass' -Detail "Scopes: $($have -join ' ')"
    return
  }
  if ($Fix -and $PSCmdlet.ShouldProcess($StorageApp.Name, "Grant tenant-wide admin consent for $($required -join ' ')")) {
    if ($grant) {
      Invoke-AvdGraph -Method PATCH -Uri "v1.0/oauth2PermissionGrants/$($grant.id)" -Body @{ scope = (@($have) + $missing) -join ' ' } | Out-Null
    }
    else {
      Invoke-AvdGraph -Method POST -Uri 'v1.0/oauth2PermissionGrants' -Body @{
        clientId    = $StorageApp.ServicePrincipal.id
        consentType = 'AllPrincipals'
        resourceId  = $graphSp.id
        scope       = $required -join ' '
      } | Out-Null
    }
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Fixed' -Detail "Granted: $($missing -join ' ')"
  }
  else {
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Fail' -Detail "Missing: $($missing -join ' ')" -Remediation 'Rerun with -Fix (needs Cloud Application Administrator or higher).'
  }
}

function Test-AvdCloudGroupSidTag {
  <# Lets Kerberos tickets for the share carry cloud-only group SIDs, which the profile share ACL uses. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 1: admin consent'
  $tag = 'kdc_enable_cloud_group_sids'
  $tags = @($StorageApp.Application.tags)
  if ($tags -contains $tag) { Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Pass'; return }
  if ($Fix -and $PSCmdlet.ShouldProcess($StorageApp.Name, "Add tag $tag")) {
    Invoke-AvdGraph -Method PATCH -Uri "v1.0/applications/$($StorageApp.Application.id)" -Body @{ tags = @($tags + $tag) } | Out-Null
    Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Fixed'
  }
  else {
    Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Warn' -Detail 'Without it, NTFS entries for cloud-only groups are not honoured.' -Remediation 'Rerun with -Fix.'
  }
}

function Test-AvdConditionalAccessExclusion {
  <# Post-deployment step 2: the storage app must be excluded from MFA-requiring CA policies. #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  param([Parameter(Mandatory)] $Lz, [Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 2: Conditional Access'
  try { $policies = Invoke-AvdGraph -Uri 'v1.0/identity/conditionalAccess/policies' }
  catch {
    Add-AvdCheckResult $area 'Read Conditional Access policies' 'Fail' -Detail $_.Exception.Message -Remediation 'Needs Conditional Access Administrator / Security Reader and the Policy.Read.All scope.'
    return
  }
  $appId = $StorageApp.Application.appId
  $groupIds = @($Lz.UsersGroupId, $Lz.AdminsGroupId) | Where-Object { $_ }
  $relevant = 0
  foreach ($p in @($policies | Where-Object state -ne 'disabled')) {
    $apps = $p.conditions.applications
    $users = $p.conditions.users
    $grant = $p.grantControls
    $allApps = @($apps.includeApplications) -contains 'All'
    $needsMfa = $grant -and ((@($grant.builtInControls) -contains 'mfa') -or $grant.authenticationStrength)
    if (-not ($allApps -and $needsMfa)) { continue }
    $relevant++
    $label = "Policy '$($p.displayName)' excludes the storage app"
    if (@($apps.excludeApplications) -contains $appId) { Add-AvdCheckResult $area $label 'Pass'; continue }

    $hitsAvd = (@($users.includeUsers) -contains 'All') -or (@($users.includeGroups) | Where-Object { $groupIds -contains $_ })
    if (-not $hitsAvd) {
      Add-AvdCheckResult $area $label 'Warn' -Detail 'Requires MFA for all apps for specific users/roles; review whether AVD users are in scope.' -Remediation 'Exclude the storage app if AVD users are covered.'
      continue
    }
    if ($Fix -and $PSCmdlet.ShouldProcess("Conditional Access policy '$($p.displayName)'", "Exclude application $($StorageApp.Name)")) {
      $conditions = $p.conditions
      $conditions.applications.excludeApplications = @(@($apps.excludeApplications) + $appId)
      Invoke-AvdGraph -Method PATCH -Uri "v1.0/identity/conditionalAccess/policies/$($p.id)" -Body @{ conditions = $conditions } | Out-Null
      Add-AvdCheckResult $area $label 'Fixed'
    }
    else {
      Add-AvdCheckResult $area $label 'Fail' -Detail 'Requires MFA for all apps and covers AVD users; Kerberos ticket requests for the share will fail.' -Remediation 'Rerun with -Fix (needs Conditional Access Administrator).'
    }
  }
  if (-not $relevant) { Add-AvdCheckResult $area 'No enabled policy requires MFA for all apps' 'Pass' }
}

# =====================================================================
# Session host helpers (run on a host through Run Command)
# =====================================================================
function Invoke-AvdHostScript {
  <# Runs a script from scripts/ops/host on a session host and returns its JSON result. #>
  param(
    [Parameter(Mandatory)][string] $ResourceGroupName,
    [Parameter(Mandatory)][string] $VMName,
    [Parameter(Mandatory)][string] $ScriptName,
    [hashtable] $Parameter = @{}
  )
  $script = Get-Content -Raw -Path (Join-Path $PSScriptRoot "host/$ScriptName")
  $r = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId RunPowerShellScript `
    -ScriptString $script -Parameter $Parameter -ErrorAction Stop
  $stdout = ($r.Value | Where-Object Code -like 'ComponentStatus/StdOut/*').Message
  $stderr = ($r.Value | Where-Object Code -like 'ComponentStatus/StdErr/*').Message
  if ($stdout -match '(?s)<<<AVDJSON(.*?)AVDJSON>>>') { return $Matches[1] | ConvertFrom-Json }
  throw "No result from $ScriptName on $VMName. StdErr: $stderr"
}

function Get-AvdDesiredShareSddl {
  <#
    FSLogix-recommended root ACL, with inheritance cut from the share default:
      SYSTEM, BUILTIN\Administrators, AVD Admins  Full control (all)
      CREATOR OWNER                                Modify (subfolders and files only)
      AVD Users                                    Modify (this folder only)
  #>
  param([Parameter(Mandatory)][string] $UsersSid, [Parameter(Mandatory)][string] $AdminsSid)
  return "O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$AdminsSid)(A;OICIIO;0x1301bf;;;CO)(A;;0x1301bf;;;$UsersSid)"
}

function Test-AvdAceGrantsWrite {
  param([Parameter(Mandatory)][string] $Rights)
  if ($Rights -match '^0x[0-9a-fA-F]+$') {
    # write data/add file, append/add subdir, write EA, delete child, write attrs, DELETE, WRITE_DAC, WRITE_OWNER
    return (([Convert]::ToUInt32($Rights.Substring(2), 16)) -band 0x000D0156) -ne 0
  }
  $tokens = for ($i = 0; $i -lt $Rights.Length; $i += 2) { $Rights.Substring($i, [Math]::Min(2, $Rights.Length - $i)) }
  return [bool](@($tokens) | Where-Object { $_ -in 'GA', 'GW', 'FA', 'FW', 'SD', 'WD', 'WO', 'CC', 'DC', 'WP', 'DT' })
}

function Test-AvdShareSddl {
  <# Returns the problems with a profile-share root SDDL (empty = compliant). #>
  param([Parameter(Mandatory)][string] $Sddl, [Parameter(Mandatory)][string] $UsersSid, [Parameter(Mandatory)][string] $AdminsSid)
  $issues = [System.Collections.Generic.List[string]]::new()
  $dacl = if ($Sddl -match 'D:([^(]*)((?:\([^)]*\))*)') { $Matches } else { $null }
  if (-not $dacl) { $issues.Add('No DACL found.'); return , $issues.ToArray() }
  if ($dacl[1] -notmatch 'P') { $issues.Add('Inheritance from the share default is not disabled (DACL not protected).') }
  $aces = [regex]::Matches($dacl[2], '\(([^)]*)\)') | ForEach-Object {
    $f = $_.Groups[1].Value -split ';'
    [pscustomobject]@{ Type = $f[0]; Flags = $f[1]; Rights = $f[2]; Sid = $f[5] }
  }
  $broad = @{ AU = 'Authenticated Users'; BU = 'BUILTIN\Users'; WD = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'BUILTIN\Users'; 'S-1-1-0' = 'Everyone' }
  foreach ($a in @($aces | Where-Object { $_.Type -eq 'A' -and $broad.ContainsKey($_.Sid) })) {
    if (Test-AvdAceGrantsWrite $a.Rights) { $issues.Add("$($broad[$a.Sid]) can write to the share root.") }
  }
  if (-not ($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq 'CO' -and $_.Flags -match 'IO' })) {
    $issues.Add('No CREATOR OWNER entry for subfolders and files.')
  }
  $users = @($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq $UsersSid })
  if (-not $users) { $issues.Add('AVD Users group has no entry (users cannot create their profile folder).') }
  elseif ($users | Where-Object { $_.Flags -match 'OI|CI' }) { $issues.Add('AVD Users entry is inherited by subfolders, so users can open each other''s profiles.') }
  if (-not ($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq $AdminsSid -and $_.Rights -in 'FA', 'GA', '0x1f01ff' })) {
    $issues.Add('AVD Admins group does not have full control.')
  }
  return , $issues.ToArray()
}

function Test-AvdProfileShareAcl {
  <#
    Post-deployment step 3: NTFS permissions on the profile share root.
    The share is private and SMB-only, so this runs ON a session host: the
    host's managed identity gets a temporary Storage File Data Privileged
    Reader/Contributor role, reads (and with -Fix, sets) the root ACL through
    the Azure Files REST API with backup intent, and the role is removed again.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Lz,
    [Parameter(Mandatory)][string] $ResourceGroupName,
    [Parameter(Mandatory)][string] $VMName,
    [switch] $Fix
  )
  $area = 'Step 3: NTFS permissions'
  $users = Get-AvdGroupSid -GroupId $Lz.UsersGroupId
  $admins = Get-AvdGroupSid -GroupId $Lz.AdminsGroupId
  $desired = Get-AvdDesiredShareSddl -UsersSid $users.Sid -AdminsSid $admins.Sid

  $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
  $principalId = $vm.Identity.PrincipalId
  if (-not $principalId) { Add-AvdCheckResult $area 'Profile share root ACL' 'Fail' -Detail "$VMName has no managed identity."; return }

  $role = if ($Fix) { 'Storage File Data Privileged Contributor' } else { 'Storage File Data Privileged Reader' }
  $scope = $Lz.StorageAccount.Id
  $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue | Where-Object Scope -eq $scope
  $created = $false
  try {
    if (-not $existing) {
      Write-Host "          granting $VMName temporary '$role' on the storage account" -ForegroundColor DarkGray
      New-AzRoleAssignment -ObjectId $principalId -ObjectType ServicePrincipal -RoleDefinitionName $role -Scope $scope -ErrorAction Stop | Out-Null
      $created = $true
    }
    $sddlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($desired))

    # Read first; role assignments can take several minutes to reach the data plane.
    $result = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
      $result = Invoke-AvdHostScript -ResourceGroupName $ResourceGroupName -VMName $VMName -ScriptName 'Invoke-ProfileShareAcl.ps1' -Parameter @{
        StorageFqdn = $Lz.StorageFqdn; ShareName = $Lz.ProfileShareName; DesiredSddlBase64 = $sddlB64; Apply = 'false'
      }
      if ($result.status -ne 'Forbidden') { break }
      Write-Host "          waiting for the role to propagate (attempt $attempt/12)" -ForegroundColor DarkGray
      Start-Sleep -Seconds 30
    }
    if ($result.status -ne 'ok') {
      Add-AvdCheckResult $area 'Profile share root ACL' 'Fail' -Detail "$($result.status): $($result.error)" -Remediation 'Check the host can resolve and reach the storage private endpoint on 443.'
      return
    }
    $issues = Test-AvdShareSddl -Sddl $result.before -UsersSid $users.Sid -AdminsSid $admins.Sid
    if (-not $issues.Count) { Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Pass'; return }

    if ($Fix -and $PSCmdlet.ShouldProcess("\\$($Lz.StorageFqdn)\$($Lz.ProfileShareName)", 'Replace the root ACL')) {
      $applied = $null
      for ($attempt = 1; $attempt -le 12; $attempt++) {
        $applied = Invoke-AvdHostScript -ResourceGroupName $ResourceGroupName -VMName $VMName -ScriptName 'Invoke-ProfileShareAcl.ps1' -Parameter @{
          StorageFqdn = $Lz.StorageFqdn; ShareName = $Lz.ProfileShareName; DesiredSddlBase64 = $sddlB64; Apply = 'true'
        }
        if ($applied.status -ne 'Forbidden') { break }
        Start-Sleep -Seconds 30
      }
      $after = if ($applied.status -eq 'ok') { Test-AvdShareSddl -Sddl $applied.after -UsersSid $users.Sid -AdminsSid $admins.Sid } else { @('not applied') }
      if ($applied.status -eq 'ok' -and -not $after.Count) {
        Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fixed' -Detail "Users: $($users.DisplayName); Admins: $($admins.DisplayName)"
      }
      else {
        Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fail' -Detail "$($applied.status) $($applied.error) $($after -join ' ')"
      }
    }
    else {
      Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fail' -Detail ($issues -join ' ') -Remediation 'Rerun with -Fix.'
    }
  }
  finally {
    if ($created) {
      Remove-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue | Out-Null
      Write-Host "          removed temporary '$role' from $VMName" -ForegroundColor DarkGray
    }
  }
}

function Get-AvdSessionHost {
  param([Parameter(Mandatory)][string] $HostPoolResourceId)
  $r = Invoke-AvdArm -Path "$HostPoolResourceId/sessionHosts?api-version=2024-04-03"
  return @($r.value)
}

function Get-AvdRunCommandState {
  param([Parameter(Mandatory)][string] $VmResourceId, [Parameter(Mandatory)][string] $Name)
  $r = Invoke-AvdArm -Path "$VmResourceId/runCommands/$Name`?api-version=2024-07-01&`$expand=instanceView" -AllowNotFound
  if (-not $r) { return $null }
  return $r.properties.instanceView
}

# =====================================================================
# Orchestrated readiness (used by the preflight and the demo script)
# =====================================================================
function Invoke-AvdReadinessCheck {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Lz,
    [switch] $Fix,
    [string] $VmSize = 'Standard_D4as_v5',
    [int] $VmCount = 1,
    [switch] $SkipTenant,
    [switch] $SkipNtfs,
    [string] $NtfsHostResourceGroup,
    [string] $NtfsHostName,
    [switch] $AllowHostStart
  )
  Write-AvdSection 'Tooling'
  Test-AvdTooling

  Write-AvdSection 'Subscription'
  Test-AvdCallerPermission -SubscriptionId $Lz.SubscriptionId
  Test-AvdResourceProvider -Fix:$Fix
  if ($Lz.Location) { Test-AvdVmCapacity -Location $Lz.Location -VmSize $VmSize -Count $VmCount }

  Write-AvdSection 'Landing zone'
  Test-AvdLandingZoneResource -Lz $Lz
  Write-AvdSection 'RBAC'
  Test-AvdLandingZoneRbac -Lz $Lz

  $storageApp = $null
  if ($SkipTenant) {
    Add-AvdCheckResult 'Entra ID' 'Tenant checks' 'Skip' -Detail '-SkipTenant'
  }
  elseif (-not $Lz.StorageAccount) {
    Add-AvdCheckResult 'Entra ID' 'Tenant checks' 'Skip' -Detail 'No profile storage account found.'
  }
  else {
    Write-AvdSection 'Entra ID tenant'
    Connect-AvdGraph -Purpose ($(if ($Fix) { 'Fix' } else { 'Read' }))
    Test-AvdGroupMembership -Lz $Lz
    Test-AvdIntuneLicense
    $storageApp = Get-AvdStorageKerberosApp -Lz $Lz
    if (-not $storageApp) {
      Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Fail' -Detail "Not found: [Storage Account] $($Lz.StorageFqdn)" -Remediation 'It is created when Entra Kerberos (AADKERB) is enabled on the account; redeploy the storage module.'
    }
    else {
      Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Pass' -Detail $storageApp.Application.appId
      Test-AvdStorageAdminConsent -StorageApp $storageApp -Fix:$Fix
      Test-AvdCloudGroupSidTag -StorageApp $storageApp -Fix:$Fix
      Write-AvdSection 'Conditional Access'
      Test-AvdConditionalAccessExclusion -Lz $Lz -StorageApp $storageApp -Fix:$Fix
    }
  }

  if ($SkipNtfs) { return }
  Write-AvdSection 'Profile share NTFS permissions'
  if ($SkipTenant -or -not $Lz.StorageAccount -or -not $Lz.UsersGroupId -or -not $Lz.AdminsGroupId) {
    Add-AvdCheckResult 'Step 3: NTFS permissions' 'Profile share root ACL' 'Skip' -Detail 'Needs the storage account, both groups and Graph access.'
    return
  }
  $hostRg = if ($NtfsHostResourceGroup) { $NtfsHostResourceGroup } else { $Lz.ResourceGroups.Hosts }
  $vms = @(Get-AzVM -ResourceGroupName $hostRg -Status -ErrorAction SilentlyContinue)
  $target = if ($NtfsHostName) { $vms | Where-Object Name -eq $NtfsHostName } else { $vms | Where-Object PowerState -eq 'VM running' | Select-Object -First 1 }
  $started = $false
  if (-not $target -and $AllowHostStart -and $vms.Count) {
    $target = $vms[0]
    if ($PSCmdlet.ShouldProcess($target.Name, 'Start session host for the NTFS check')) {
      Start-AzVM -ResourceGroupName $hostRg -Name $target.Name | Out-Null
      $started = $true
    }
  }
  if (-not $target) {
    Add-AvdCheckResult 'Step 3: NTFS permissions' 'Profile share root ACL' 'Skip' -Detail "No running session host in $hostRg." -Remediation 'Use -AllowHostStart, -NtfsHostName, or Deploy-AvdDemo.ps1 (it checks from the demo host).'
    return
  }
  try { Test-AvdProfileShareAcl -Lz $Lz -ResourceGroupName $hostRg -VMName $target.Name -Fix:$Fix }
  finally {
    if ($started) { Stop-AzVM -ResourceGroupName $hostRg -Name $target.Name -Force | Out-Null }
  }
}

Export-ModuleMember -Function *-Avd*
