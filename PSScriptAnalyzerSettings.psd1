# PSScriptAnalyzer settings for this repo (used by CI and locally).
@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # The ops scripts are interactive console tools; colored Write-Host output is intended.
    'PSAvoidUsingWriteHost'
  )
}
