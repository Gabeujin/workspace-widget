[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$fixturePath = Join-Path $ProjectRoot 'tests\fixtures\node-health-app\server.js'
$script:checks = [ordered]@{}
$script:failures = [System.Collections.Generic.List[string]]::new()

function Add-Check {
  param([int]$Number, [string]$Name, [bool]$Passed, [string]$Failure)

  $key = '{0:D2}-{1}' -f $Number, $Name
  $script:checks[$key] = $Passed
  if (-not $Passed) { $script:failures.Add("${key}: $Failure") }
}

function Import-AstFunction {
  param([string]$Path, [string]$Name)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$tokens, [ref]$errors
  )
  if (@($errors).Count -gt 0) {
    throw "Cannot import '$Name' because '$Path' has parse errors."
  }
  $definition = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
      }, $true) | Select-Object -First 1)
  if ($definition.Count -ne 1) { throw "Function '$Name' was not found in '$Path'." }
  $bodyText = $definition[0].Body.Extent.Text
  $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
  Set-Item -Path ("Function:script:$Name") -Value ([scriptblock]::Create($bodyText))
}

try {
  Add-Type -AssemblyName PresentationFramework
  foreach ($path in @($appPath, $experiencePath, $fixturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required test input is missing: $path"
    }
  }
  $scriptRoot = Split-Path -Parent $appPath
  $appContent = [System.IO.File]::ReadAllText($appPath, [System.Text.UTF8Encoding]::new($false))

  foreach ($function in @(
      'Initialize-ServerRegistration', 'Get-ItemHealthUrls', 'Get-ItemHealthJson'
    )) {
    Import-AstFunction -Path $experiencePath -Name $function
  }
  foreach ($function in @(
      'Get-NodePackageScript', 'Resolve-NodeStartupConfiguration',
      'Get-LocalServerContractDigest'
    )) {
    Import-AstFunction -Path $appPath -Name $function
  }

  Add-Check 1 'source-ast-parses' $true ''
  Add-Check 2 'all-registration-helpers-present' $true ''

  $server = [pscustomobject][ordered]@{
    id = 'legacy-server'
    name = '한글 순서 보존'
    target = 'http://127.0.0.1:4520/'
    health = 'http://127.0.0.1:4520/상태?이름=값'
    startupTarget = $fixturePath
    startupArgs = '--port=4520'
    workingDirectory = Split-Path -Parent $fixturePath
  }
  Initialize-ServerRegistration -Item $server
  Add-Check 3 'legacy-startup-migrates-to-server' ($server.registrationType -eq 'server') 'Legacy startup target did not migrate to server.'
  Add-Check 4 'legacy-health-becomes-primary-check' (
    @($server.healthChecks).Count -eq 1 -and
    [string]$server.healthChecks[0].name -eq 'Primary' -and
    [string]$server.healthChecks[0].url -eq [string]$server.health
  ) 'Legacy health did not become exactly one primary check.'
  Add-Check 5 'server-stop-default-is-present' (
    -not [string]::IsNullOrWhiteSpace([string]$server.stopTarget) -and
    [string]$server.stopArgs -eq ''
  ) 'Server stop defaults are incomplete.'

  $orderedServer = [pscustomobject][ordered]@{
    id = 'ordered-server'; name = '정렬 보존'; target = 'http://127.0.0.1:4520/'
    registrationType = 'server'; startupTarget = $fixturePath; startupArgs = '--port=4520'
    workingDirectory = Split-Path -Parent $fixturePath; stopTarget = $fixturePath; stopArgs = '--graceful'
    health = 'http://127.0.0.1:4520/상태?이름=값'
    healthChecks = @(
      [pscustomobject][ordered]@{ name = '첫 번째'; url = 'http://127.0.0.1:4520/상태?이름=값' },
      [pscustomobject][ordered]@{ name = '두 번째'; url = 'http://127.0.0.1:4521/health?order=2' }
    )
  }
  $urls = @(Get-ItemHealthUrls -Item $orderedServer)
  $healthJson = Get-ItemHealthJson -Item $orderedServer
  $parsedHealthJson = $healthJson | ConvertFrom-Json
  # Windows PowerShell 5.1 materializes a top-level JSON array as a wrapper
  # with a `value` property; PowerShell 7 returns the array directly.
  $roundTripUrls = if (
    $null -ne $parsedHealthJson -and
    $parsedHealthJson.PSObject.Properties.Name -contains 'value'
  ) { @($parsedHealthJson.value) } else { @($parsedHealthJson) }
  Add-Check 6 'health-url-order-is-preserved' (($urls -join '|') -eq ($roundTripUrls -join '|')) 'Health JSON changed URL order.'
  Add-Check 7 'health-unicode-is-preserved' ([string]$roundTripUrls[0] -ceq [string]$orderedServer.healthChecks[0].url) 'Health JSON changed Unicode text.'
  Add-Check 8 'health-json-is-an-array' ($healthJson.TrimStart().StartsWith('[')) 'Health JSON is not an array.'

  $ordinary = [pscustomobject][ordered]@{
    id = 'ordinary'; registrationType = 'ordinary'; health = 'http://127.0.0.1:4520/health'
    healthChecks = @([pscustomobject]@{ name = 'must-not-start'; url = 'http://127.0.0.1:4520/health' })
    startupTarget = $fixturePath; startupArgs = '--ignored'; stopTarget = ''; stopArgs = ''
  }
  Initialize-ServerRegistration -Item $ordinary
  Add-Check 9 'ordinary-has-no-health-contract' (@(Get-ItemHealthUrls -Item $ordinary).Count -eq 0) 'Ordinary registration exposed a health contract.'
  $unknownRegistrationRejected = $false
  try {
    $invalid = [pscustomobject]@{ registrationType = 'remote'; health = '' }
    Initialize-ServerRegistration -Item $invalid
  } catch {
    $unknownRegistrationRejected = $true
  }
  Add-Check 10 'unknown-registration-is-rejected' $unknownRegistrationRejected 'Unknown registration type was accepted.'

  $digestOne = Get-LocalServerContractDigest -Item $orderedServer
  $digestTwo = Get-LocalServerContractDigest -Item $orderedServer
  $reorderedServer = $orderedServer | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $reorderedServer.healthChecks = @($reorderedServer.healthChecks[1], $reorderedServer.healthChecks[0])
  $digestReordered = Get-LocalServerContractDigest -Item $reorderedServer
  $changedStop = $orderedServer | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $changedStop.stopArgs = '--force'
  Add-Check 11 'contract-digest-is-stable' ($digestOne -ceq $digestTwo -and $digestOne -match '^[0-9a-f]{64}$') 'Digest is unstable or malformed.'
  Add-Check 12 'contract-digest-binds-health-order' ($digestOne -cne $digestReordered) 'Digest did not bind health-check order.'
  Add-Check 13 'contract-digest-binds-stop-arguments' ($digestOne -cne (Get-LocalServerContractDigest -Item $changedStop)) 'Digest did not bind stop arguments.'

  $fileConfiguration = Resolve-NodeStartupConfiguration -Target $fixturePath -Arguments '--port=4520' -WorkingDirectory (Split-Path -Parent $fixturePath)
  Add-Check 14 'node-file-configuration-is-local' (
    $fileConfiguration.kind -eq 'file' -and
    [string]$fileConfiguration.target -eq [System.IO.Path]::GetFullPath($fixturePath) -and
    [string]$fileConfiguration.workingDirectory -eq (Split-Path -Parent $fixturePath)
  ) 'Expected local Node file configuration was not resolved.'
  $networkTargetRejected = $false
  try { Resolve-NodeStartupConfiguration -Target '\\server\share\app.js' -Arguments '' -WorkingDirectory '' } catch { $networkTargetRejected = $true }
  Add-Check 15 'node-network-target-is-rejected' $networkTargetRejected 'Network Node target was accepted.'

  # A malformed current v5 file must be preserved by either a recoverable backup
  # or a fail-closed read that leaves it untouched; returning defaults is unsafe
  # because the later Save-State would overwrite the original user data.
  $preservesRejectedV5 = (
    ($appContent -match '(?is)(backup|quarantine|preserv).{0,240}(reject|invalid|malformed|state)') -or
    ($appContent -match 'existing state is invalid and was left unchanged' -and
      $appContent -match 'State read stopped to preserve a newer schema' -and
      $appContent -match 'catch \[System\.NotSupportedException\]')
  )
  Add-Check 16 'malformed-v5-state-is-preserved-before-fallback' $preservesRejectedV5 'Malformed current v5 state can fall back and later be overwritten.'
} catch {
  $script:failures.Add($_.Exception.Message)
}

[pscustomobject][ordered]@{
  success = $script:failures.Count -eq 0 -and $script:checks.Count -eq 16
  checkCount = $script:checks.Count
  checks = $script:checks
  failures = @($script:failures)
} | ConvertTo-Json -Depth 6

if ($script:failures.Count -gt 0 -or $script:checks.Count -ne 16) { exit 1 }
