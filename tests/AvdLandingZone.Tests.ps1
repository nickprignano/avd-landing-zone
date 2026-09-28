#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the pure (no Azure) functions in scripts/ops/AvdLandingZone.psm1.
# Run: Invoke-Pester ./tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../scripts/ops/AvdLandingZone.psm1') -Force
}

Describe 'ConvertTo-AvdEntraSid' {
  It 'matches the Microsoft-published object ID to SID example' {
    ConvertTo-AvdEntraSid '73d664e4-0886-4a73-b745-c694da45ddb4' |
      Should -Be 'S-1-12-1-1943430372-1249052806-2496021943-3034400218'
  }
}

Describe 'Profile share ACL evaluation' {
  BeforeAll {
    $users = 'S-1-12-1-1-2-3-4'
    $admins = 'S-1-12-1-5-6-7-8'
    $desired = Get-AvdDesiredShareSddl -UsersSid $users -AdminsSid $admins
    # Typical root ACL of a new Azure Files share.
    $default = 'O:SYG:SYD:(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1301bf;;;AU)(A;OICIIO;SDGXGWGR;;;AU)(A;OICI;0x1200a9;;;BU)'
  }

  It 'accepts the ACL it generates' {
    (Test-AvdShareSddl -Sddl $desired -UsersSid $users -AdminsSid $admins).Count | Should -Be 0
  }

  It 'flags the default share ACL' {
    $issues = Test-AvdShareSddl -Sddl $default -UsersSid $users -AdminsSid $admins
    $issues | Should -Contain 'Inheritance from the share default is not disabled (DACL not protected).'
    $issues | Should -Contain 'Authenticated Users can write to the share root.'
    ($issues -join ' ') | Should -Match 'AVD Users group has no entry'
    ($issues -join ' ') | Should -Match 'AVD Admins group does not have full control'
    ($issues -join ' ') | Should -Not -Match 'BUILTIN'
  }

  It 'flags a users entry that inherits into profile folders' {
    $leaky = $desired.Replace("(A;;0x1301bf;;;$users)", "(A;OICI;0x1301bf;;;$users)")
    (Test-AvdShareSddl -Sddl $leaky -UsersSid $users -AdminsSid $admins) -join ' ' | Should -Match 'each other'
  }
}

Describe 'Test-AvdAceGrantsWrite' {
  It '<Rights> grants write: <Expected>' -TestCases @(
    @{ Rights = '0x1301bf'; Expected = $true }
    @{ Rights = '0x1200a9'; Expected = $false }
    @{ Rights = 'GXGR'; Expected = $false }
    @{ Rights = 'SDGXGWGR'; Expected = $true }
    @{ Rights = 'FA'; Expected = $true }
  ) {
    Test-AvdAceGrantsWrite $Rights | Should -Be $Expected
  }
}

Describe 'Get-AvdRandomPassword' {
  It 'returns a read-only 24-character SecureString meeting Windows complexity' {
    $pw = Get-AvdRandomPassword
    $pw.IsReadOnly() | Should -BeTrue
    $plain = [System.Net.NetworkCredential]::new('', $pw).Password
    $plain.Length | Should -Be 24
    $plain | Should -MatchExactly '[A-Z]'
    $plain | Should -MatchExactly '[a-z]'
    $plain | Should -Match '\d'
    $plain | Should -Match '[^A-Za-z0-9]'
  }
  It 'differs between calls' {
    $a = [System.Net.NetworkCredential]::new('', (Get-AvdRandomPassword)).Password
    $b = [System.Net.NetworkCredential]::new('', (Get-AvdRandomPassword)).Password
    $a | Should -Not -Be $b
  }
}

Describe 'Get-AvdGraphFilterUri' {
  It 'URL-encodes the filter' {
    Get-AvdGraphFilterUri -Collection applications -Filter "displayName eq '[Storage Account] st1.file.core.windows.net'" -Select 'id,appId' |
      Should -Be 'v1.0/applications?$filter=displayName%20eq%20%27%5BStorage%20Account%5D%20st1.file.core.windows.net%27&$select=id,appId'
  }
}

Describe 'Check result reporting' {
  It 'counts failures in the summary' {
    Clear-AvdCheckResult
    Add-AvdCheckResult 'A' 'one' 'Pass' 6>$null
    Add-AvdCheckResult 'A' 'two' 'Fail' -Remediation 'do x' 6>$null
    $summary = Write-AvdSummary 6>$null
    $summary.Failed | Should -Be 1
    $summary.Results.Count | Should -Be 2
  }
}

Describe 'Invoke-AvdGraph' {
  BeforeAll {
    # Stand-in so Pester can mock it without the Microsoft.Graph module installed.
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
  }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'follows nextLink and returns a flat list that @() does not nest' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest {
      if ($Uri -eq 'v1.0/things') { [pscustomobject]@{ value = @([pscustomobject]@{ n = 1 }, [pscustomobject]@{ n = 2 }); '@odata.nextLink' = 'page2' } }
      else { [pscustomobject]@{ value = @([pscustomobject]@{ n = 3 }) } }
    }
    $items = @(Invoke-AvdGraph -Uri 'v1.0/things')
    $items.Count | Should -Be 3
    ($items | ForEach-Object n) -join ',' | Should -Be '1,2,3'
    @(Invoke-AvdGraph -Uri 'v1.0/things' | Where-Object n -gt 1).Count | Should -Be 2
  }

  It 'returns nothing (not a nested empty array) for an empty collection' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { [pscustomobject]@{ value = @() } }
    @(Invoke-AvdGraph -Uri 'v1.0/empty').Count | Should -Be 0
  }

  It 'throws instead of looping when a page request fails' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { }
    { Invoke-AvdGraph -Uri 'v1.0/groups' } | Should -Throw
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -Times 1 -Exactly
  }
}

Describe 'Get-AvdProviderState' {
  BeforeAll {
    function global:Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub' } } }
    function global:Get-AzResourceProvider { param($ProviderNamespace, $ErrorAction) }
  }
  AfterAll { 'Get-AzContext', 'Get-AzResourceProvider' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue } }

  It 'reads every namespace from one provider list call' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      [pscustomobject]@{ value = @(
          [pscustomobject]@{ namespace = 'Microsoft.Compute'; registrationState = 'Registered' }
          [pscustomobject]@{ namespace = 'Microsoft.KeyVault'; registrationState = 'NotRegistered' }
        ) }
    }
    Mock -ModuleName AvdLandingZone Get-AzResourceProvider { }
    $s = Get-AvdProviderState -Namespace 'Microsoft.Compute', 'Microsoft.KeyVault'
    $s['Microsoft.Compute'] | Should -Be 'Registered'
    $s['Microsoft.KeyVault'] | Should -Be 'NotRegistered'
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -Times 1 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Get-AzResourceProvider -Times 0 -Exactly
  }

  It 'falls back to per-namespace lookups when the list call fails' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { throw 'ARM GET failed (500)' }
    Mock -ModuleName AvdLandingZone Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'Registering' } }
    (Get-AvdProviderState -Namespace 'Microsoft.Network')['Microsoft.Network'] | Should -Be 'Registering'
  }
}

Describe 'Test-AvdGraphToken' {
  BeforeAll { function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) } }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'is false when the sign-in cannot produce a token' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { throw 'DeviceCodeCredential authentication failed: Object reference not set to an instance of an object.' }
    Test-AvdGraphToken | Should -BeFalse
  }

  It 'is true on a permission error, which still proves a token was issued' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { throw 'Response status code does not indicate success: Forbidden (Forbidden).' }
    Test-AvdGraphToken | Should -BeTrue
  }

  It 'is true when the request succeeds' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'org' }) } }
    Test-AvdGraphToken | Should -BeTrue
  }
}

Describe 'Test-AvdHostPoolRegion' {
  BeforeEach {
    Clear-AvdCheckResult
    # Shape of GET /subscriptions/{id}/providers/Microsoft.DesktopVirtualization
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      [pscustomobject]@{ resourceTypes = @(
          [pscustomobject]@{ resourceType = 'workspaces'; locations = @('Brazil South') }
          [pscustomobject]@{ resourceType = 'hostpools'; locations = @('North Central US', 'West US 2') }
        ) }
    }
  }

  It 'passes for a host pool region given by its ARM name' {
    Test-AvdHostPoolRegion -Location 'westus2' -SubscriptionId 'sub'
    (Get-AvdCheckResult).Status | Should -Be 'Pass'
  }

  It 'warns instead of failing when the provider cannot be read' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { throw 'ARM GET failed (403)' }
    Test-AvdHostPoolRegion -Location 'westus2' -SubscriptionId 'sub'
    (Get-AvdCheckResult).Status | Should -Be 'Warn'
  }

  It 'fails for a region without host pools and lists the ones that have them' {
    Test-AvdHostPoolRegion -Location 'brazilsouth' -SubscriptionId 'sub'
    $r = Get-AvdCheckResult
    $r.Status | Should -Be 'Fail'
    $r.Detail | Should -BeLike '*northcentralus, westus2*'
  }
}

Describe 'Test-AvdResourceProvider -Fix' {
  BeforeAll {
    # Stand-ins so Pester can mock them without the Az modules installed.
    function global:Get-AzProviderFeature { param($ProviderNamespace, $FeatureName, $ErrorAction) }
    function global:Register-AzProviderFeature { param($ProviderNamespace, $FeatureName) }
  }
  AfterAll {
    'Get-AzProviderFeature', 'Register-AzProviderFeature' |
      ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
  }
  BeforeEach {
    Clear-AvdCheckResult
    $global:AvdTestPolls = 0
    Mock -ModuleName AvdLandingZone Start-Sleep { $global:AvdTestPolls++ }
    Mock -ModuleName AvdLandingZone Register-AvdResourceProvider { }
    Mock -ModuleName AvdLandingZone Register-AzProviderFeature { }
    # Everything turns Registered after the first poll.
    Mock -ModuleName AvdLandingZone Get-AvdProviderState {
      $s = [ordered]@{}; foreach ($ns in $Namespace) { $s[$ns] = $(if ($global:AvdTestPolls) { 'Registered' } else { 'NotRegistered' }) }; $s
    }
    Mock -ModuleName AvdLandingZone Get-AzProviderFeature { [pscustomobject]@{ RegistrationState = $(if ($global:AvdTestPolls) { 'Registered' } else { 'NotRegistered' }) } }
  }
  AfterEach { Remove-Variable AvdTestPolls -Scope Global -ErrorAction SilentlyContinue }

  It 'waits for the registrations, reports Fixed and re-registers Microsoft.Compute' {
    Test-AvdResourceProvider -Namespace 'Microsoft.KeyVault' -Fix 6>$null
    $r = Get-AvdCheckResult
    ($r | Where-Object Check -like 'Provider*').Status | Should -Be 'Fixed'
    ($r | Where-Object Check -like 'Feature*').Status | Should -Be 'Fixed'
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -ParameterFilter { $Namespace -eq 'Microsoft.Compute' } -Times 1 -Exactly
  }

  It 'warns and does not re-register Compute when the feature is still registering at the timeout' {
    Mock -ModuleName AvdLandingZone Get-AzProviderFeature { [pscustomobject]@{ RegistrationState = 'Registering' } }
    Test-AvdResourceProvider -Namespace @() -Fix -WaitMinutes 0 6>$null
    $r = Get-AvdCheckResult
    ($r | Where-Object Check -like 'Feature*').Status | Should -Be 'Warn'
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -Times 0 -Exactly
  }

  It 'only reports in check mode' {
    Test-AvdResourceProvider -Namespace 'Microsoft.KeyVault' 6>$null
    $r = Get-AvdCheckResult
    @($r | Where-Object Status -eq 'Fail').Count | Should -Be 2
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -Times 0 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Start-Sleep -Times 0 -Exactly
  }
}

Describe 'Add-AvdCallerToGroup' {
  BeforeAll { function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) } }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'adds the signed-in user only to groups they are not already in' {
    Clear-AvdCheckResult
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest {
      if ($Method -eq 'POST') { return }
      if ($Uri.StartsWith('v1.0/me?')) { return [pscustomobject]@{ id = 'me1'; userPrincipalName = 'alex@contoso.com' } }
      [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g-admins' }) }
    }
    Add-AvdCallerToGroup -Group @(
      @('AVD Users', [pscustomobject]@{ id = 'g-users'; displayName = 'AVD Users' }),
      @('AVD Admins', [pscustomobject]@{ id = 'g-admins'; displayName = 'AVD Admins' })
    )
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } -Times 1 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'v1.0/groups/g-users/members/$ref' } -Times 1 -Exactly
    (Get-AvdCheckResult).Status -join ',' | Should -Be 'Fixed,Pass'
  }
}
