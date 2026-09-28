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
