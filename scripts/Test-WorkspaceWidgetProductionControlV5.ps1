[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-Control {
  param([Parameter(Mandatory = $true)][string]$Action, [Parameter(Mandatory = $true)][string]$StatePath)
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $script:WindowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:ControlPath `
      -Action $Action -HostPath $script:HostPath -StatePath $StatePath -ItemId 'fixture-server' 2>&1
    return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = @($output) }
  } finally {
    $ErrorActionPreference = $oldPreference
  }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$script:ControlPath = Join-Path $ProjectRoot 'scripts\Invoke-WorkspaceWidgetProductionControl.ps1'
$script:WindowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-That (Test-Path -LiteralPath $script:ControlPath -PathType Leaf) 'Production control script was not found.'
Assert-That (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 was not found.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('workspace-widget-production-control-v5-' + [Guid]::NewGuid().ToString('N'))
$releaseRoot = Join-Path $fixtureRoot 'release'
$appRoot = Join-Path $releaseRoot 'app'
$runtimeRoot = Join-Path $fixtureRoot 'runtime-state'
$script:HostPath = Join-Path $releaseRoot 'WorkspaceWidget.NativeFixture.dll'
$startupTarget = Join-Path $fixtureRoot 'server.mjs'
$powerShellTarget = Join-Path $fixtureRoot 'server.ps1'
$stopTarget = Join-Path $appRoot 'managed-stop.mjs'
New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $releaseRoot 'runtime\node') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $releaseRoot 'runtime\pnpm') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $releaseRoot 'runtime\bin\override') -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'app\WidgetExperience.ps1') -Destination (Join-Path $appRoot 'WidgetExperience.ps1') -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1') -Destination (Join-Path $appRoot 'WorkspaceWidget.ps1') -Force
[IO.File]::WriteAllText((Join-Path $releaseRoot 'runtime\node\node.exe'), '', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $releaseRoot 'runtime\pnpm\pnpm.cmd'), '', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($startupTarget, '// fixture only', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($powerShellTarget, '# fixture only', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($stopTarget, '// fixture only', [Text.UTF8Encoding]::new($false))

$fakeNative = @'
using System;
namespace WorkspaceWidget.Native {
  public static class ManagedServiceClient {
    public static string Start(string hostPath, string runtimeRoot, string itemId, string digest, string executable, string arguments, string workingDirectory, string healthUrl, string pathValue) { return "{\"called\":\"Start\"}"; }
    public static string Status(string runtimeRoot, string itemId, string digest, string healthUrl) { return "{\"called\":\"Status\"}"; }
    public static string Stop(string runtimeRoot, string itemId, string digest, string healthUrl, bool force, int timeout) { return "{\"called\":\"Stop\"}"; }
    public static string StartV2(string hostPath, string runtimeRoot, string itemId, string digest, string executable, string arguments, string workingDirectory, string healthUrlsJson, string stopTarget, string stopArgs, string pathValue) { return "{\"called\":\"StartV2\",\"executable\":\"" + System.IO.Path.GetFileName(executable) + "\"}"; }
    public static string StatusV2(string runtimeRoot, string itemId, string digest, string healthUrlsJson) { return "{\"called\":\"StatusV2\"}"; }
    public static string StopV2(string runtimeRoot, string itemId, string digest, string healthUrlsJson, string stopTarget, string stopArgs, bool force, int timeout) { return "{\"called\":\"StopV2\",\"stopArgs\":\"" + stopArgs + "\"}"; }
  }
}
'@
Add-Type -TypeDefinition $fakeNative -Language CSharp -OutputAssembly $script:HostPath

$v5StatePath = Join-Path $runtimeRoot 'state-v5.json'
$v5State = [ordered]@{
  schemaVersion = 5
  window = [ordered]@{}
  items = @([ordered]@{
    id = 'fixture-server'
    registrationType = 'server'
    startupTarget = $startupTarget
    startupArgs = '--port 43115'
    workingDirectory = $fixtureRoot
    health = 'http://127.0.0.1:43115/health'
    healthChecks = @([ordered]@{ name = 'Primary'; url = 'http://127.0.0.1:43115/health' })
    stopTarget = $stopTarget
    stopArgs = '--fixture'
  })
}
[IO.File]::WriteAllText($v5StatePath, ($v5State | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))

foreach ($action in @('Status','Start','Stop')) {
  $result = Invoke-Control -Action $action -StatePath $v5StatePath
  Assert-That ($result.exitCode -eq 0) ("V5 $action failed: " + (($result.output | Out-String).Trim()))
  $json = (($result.output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
  Assert-That ($json.called -ceq ($action + 'V2')) "V5 $action did not select the V2 API."
  if ($action -eq 'Start') { Assert-That ($json.executable -ceq 'node.exe') 'V5 .mjs start did not use the bundled Node executable.' }
  if ($action -eq 'Stop') { Assert-That ($json.stopArgs -ceq '--fixture') 'V5 stop did not bind configured stop arguments.' }
}

$powerShellStatePath = Join-Path $runtimeRoot 'state-v5-powershell.json'
$powerShellState = $v5State | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$powerShellState.items[0].startupTarget = $powerShellTarget
[IO.File]::WriteAllText($powerShellStatePath, ($powerShellState | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
$powerShellResult = Invoke-Control -Action 'Start' -StatePath $powerShellStatePath
Assert-That ($powerShellResult.exitCode -eq 0) ('V5 PowerShell Start failed: ' + (($powerShellResult.output | Out-String).Trim()))
$powerShellJson = (($powerShellResult.output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
Assert-That ($powerShellJson.called -ceq 'StartV2' -and $powerShellJson.executable -ceq 'powershell.exe') 'V5 .ps1 start did not use fixed Windows PowerShell.'

$v1StatePath = Join-Path $runtimeRoot 'state-v4.json'
$v1State = [ordered]@{
  schemaVersion = 4
  items = @([ordered]@{
    id = 'fixture-server'
    startupTarget = $startupTarget
    startupArgs = ''
    workingDirectory = $fixtureRoot
    health = 'http://127.0.0.1:43115/health'
  })
}
[IO.File]::WriteAllText($v1StatePath, ($v1State | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
$v1Result = Invoke-Control -Action 'Status' -StatePath $v1StatePath
Assert-That ($v1Result.exitCode -eq 0) ('Legacy Status failed: ' + (($v1Result.output | Out-String).Trim()))
$v1Json = (($v1Result.output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
Assert-That ($v1Json.called -ceq 'Status') 'Legacy schema did not retain the v1 Status API.'

$projectStatePath = Join-Path $runtimeRoot 'state-v5-project.json'
$projectRoot = Join-Path $fixtureRoot 'fixture-project'
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $projectRoot 'package.json'), '{"scripts":{"fixture-start":"node server.mjs"}}', [Text.UTF8Encoding]::new($false))
$projectState = $v5State | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$projectState.items[0].startupTarget = $projectRoot
$projectState.items[0].startupArgs = 'fixture-start'
[IO.File]::WriteAllText($projectStatePath, ($projectState | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
$projectResult = Invoke-Control -Action 'Start' -StatePath $projectStatePath
Assert-That ($projectResult.exitCode -eq 0) ('V5 project Start failed: ' + (($projectResult.output | Out-String).Trim()))
$projectJson = (($projectResult.output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
Assert-That ($projectJson.called -ceq 'StartV2' -and $projectJson.executable -ceq 'cmd.exe') 'V5 project start did not use the trusted package runner wrapper.'

$futureStatePath = Join-Path $runtimeRoot 'state-v6.json'
$futureState = $v5State | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$futureState.schemaVersion = 6
[IO.File]::WriteAllText($futureStatePath, ($futureState | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
$futureResult = Invoke-Control -Action 'Status' -StatePath $futureStatePath
Assert-That ($futureResult.exitCode -ne 0) 'Unsupported schema 6 was accepted.'
Assert-That ((($futureResult.output | Out-String) -notmatch '"called"')) 'Unsupported schema 6 reached a native lifecycle API.'

[pscustomobject]@{
  success = $true
  assertions = 16
  fixtureRoot = $fixtureRoot
} | ConvertTo-Json -Compress
