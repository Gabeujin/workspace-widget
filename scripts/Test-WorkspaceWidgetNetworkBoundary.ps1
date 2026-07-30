[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$appScript = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
if (-not (Test-Path -LiteralPath $appScript -PathType Leaf)) {
  throw "Workspace Widget source was not found: $appScript"
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $probeRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('WorkspaceWidgetNetworkBoundary-' + [Guid]::NewGuid().ToString('N'))
  $StatePath = Join-Path $probeRoot 'state.json'
}

$output = @(
  & powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $appScript `
    -ProjectRoot $ProjectRoot `
    -StatePath $StatePath `
    -NetworkBoundaryProbe 2>&1
)
$exitCode = $LASTEXITCODE
$outputText = [string]::Join(
  [Environment]::NewLine,
  @($output | ForEach-Object { [string]$_ })
)
if ($exitCode -ne 0) {
  throw "Network boundary probe failed with exit code $exitCode.`n$outputText"
}
try {
  $result = $outputText | ConvertFrom-Json
} catch {
  throw "Network boundary probe returned invalid JSON.`n$outputText"
}
if (
  $null -eq $result -or
  -not [bool]$result.success -or
  @($result.failedChecks).Count -gt 0
) {
  throw "Network boundary checks failed.`n$outputText"
}

$result | ConvertTo-Json -Depth 6
