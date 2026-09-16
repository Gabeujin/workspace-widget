#requires -PSEdition Desktop
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StageRoot,
  [string]$ProjectRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$StageRoot = [IO.Path]::GetFullPath($StageRoot)
$fixtureSource = Join-Path $ProjectRoot 'tests\fixtures\node-health-app\server.js'
$probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WWI-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeRoot | Out-Null
$results = [ordered]@{}
foreach ($mode in @('direct', 'package')) {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $probePort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  $nonce = [guid]::NewGuid().ToString('N')
  $target = $fixtureSource
  $probeArguments = "$probePort $nonce"
  if ($mode -eq 'package') {
    $target = Join-Path $probeRoot 'pkg'
    New-Item -ItemType Directory -Path $target | Out-Null
    Copy-Item -LiteralPath $fixtureSource -Destination (Join-Path $target 'server.js')
    $package = [ordered]@{
      name = 'widget-isolated-startup-test'; private = $true
      scripts = [ordered]@{ start = "node server.js $probePort $nonce" }
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $target 'package.json'), $package, [Text.UTF8Encoding]::new($false, $true))
    $probeArguments = 'start'
  }
  $output = @(& powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
    -File (Join-Path $StageRoot 'app\WorkspaceWidget.ps1') -ProjectRoot $StageRoot `
    -StatePath (Join-Path $probeRoot "$mode\state.json") -StartupProbe `
    -StartupProbeTarget $target -StartupProbeHealth "http://127.0.0.1:$probePort/health" `
    -StartupProbeArgs $probeArguments -StartupProbeExpectedToken $nonce)
  $probeExitCode = $LASTEXITCODE
  $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
  $results[$mode] = $result
  if ($probeExitCode -ne 0 -or -not [bool]$result.success) {
    $result | ConvertTo-Json -Depth 7
    throw "Isolated $mode startup/health/stop failed; evidence preserved under $probeRoot."
  }
}
[ordered]@{ success = $true; retainedEvidenceRoot = $probeRoot; probes = $results } | ConvertTo-Json -Depth 7
