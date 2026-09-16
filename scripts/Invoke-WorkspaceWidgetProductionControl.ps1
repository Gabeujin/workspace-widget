[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('Start', 'Status', 'Stop')][string]$Action,
  [Parameter(Mandatory = $true)][string]$HostPath,
  [Parameter(Mandatory = $true)][string]$ItemId,
  [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'),
  [ValidateRange(1000, 60000)][int]$GracefulTimeoutMs = 15000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$HostPath = [IO.Path]::GetFullPath($HostPath)
$StatePath = [IO.Path]::GetFullPath($StatePath)

if (-not (Test-Path -LiteralPath $HostPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
  throw 'The requested Widget host or state file was not found.'
}

function Import-ProductionFunction {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if (@($errors).Count -ne 0) { throw "Production helper source did not parse: $Path" }
  $definition = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1)
  if ($definition.Count -ne 1) { throw "Production helper '$Name' was not found." }
  $body = $definition[0].Body.Extent.Text
  Set-Item -Path ("Function:script:$Name") -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

function Invoke-V5ProductionControl {
  param([Parameter(Mandatory = $true)]$State)

  $releaseRoot = Split-Path -Parent $HostPath
  $experiencePath = Join-Path $releaseRoot 'app\WidgetExperience.ps1'
  $widgetPath = Join-Path $releaseRoot 'app\WorkspaceWidget.ps1'
  if (-not (Test-Path -LiteralPath $experiencePath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $widgetPath -PathType Leaf)) {
    throw 'The selected v5 Widget release does not contain its production lifecycle helpers.'
  }
  Import-ProductionFunction -Path $experiencePath -Name 'Get-ItemHealthUrls'
  Import-ProductionFunction -Path $experiencePath -Name 'Get-ItemHealthJson'
  Import-ProductionFunction -Path $widgetPath -Name 'Get-NodePackageScript'
  Import-ProductionFunction -Path $widgetPath -Name 'Resolve-NodeStartupConfiguration'
  Import-ProductionFunction -Path $widgetPath -Name 'Get-LocalServerContractDigest'

  $item = @($State.items | Where-Object { [string]$_.id -ceq $ItemId }) | Select-Object -First 1
  if ($null -eq $item -or [string]$item.registrationType -cne 'server') {
    throw 'The requested v5 item is not a registered managed server.'
  }
  $healthUrlsJson = Get-ItemHealthJson -Item $item
  if (@(Get-ItemHealthUrls -Item $item).Count -lt 1) {
    throw 'The requested v5 item does not expose a managed health contract.'
  }
  $digest = Get-LocalServerContractDigest -Item $item
  [void][Reflection.Assembly]::LoadFrom($HostPath)
  $client = [WorkspaceWidget.Native.ManagedServiceClient]
  foreach ($methodName in @('StartV2','StatusV2','StopV2')) {
    if ($null -eq $client.GetMethod($methodName)) {
      throw 'The selected Widget host does not expose the required v5 lifecycle API.'
    }
  }
  $runtimeRoot = Split-Path -Parent $StatePath

  if ($Action -eq 'Status') {
    [Console]::Out.WriteLine($client::StatusV2($runtimeRoot, [string]$item.id, $digest, $healthUrlsJson))
    return
  }
  if ($Action -eq 'Stop') {
    [Console]::Out.WriteLine($client::StopV2($runtimeRoot, [string]$item.id, $digest, $healthUrlsJson,
      [string]$item.stopTarget, [string]$item.stopArgs, $false, $GracefulTimeoutMs))
    return
  }

  $configuredWorkingDirectory = if ($item.PSObject.Properties.Name -contains 'workingDirectory') {
    [string]$item.workingDirectory
  } else { '' }
  $startup = Resolve-NodeStartupConfiguration -Target ([string]$item.startupTarget) `
    -Arguments ([string]$item.startupArgs) -WorkingDirectory $configuredWorkingDirectory
  $nodePath = Join-Path $releaseRoot 'runtime\node\node.exe'
  if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    throw 'The selected Widget release does not contain its required Node runtime.'
  }
  $executable = $nodePath
  $argumentLine = '"' + [string]$startup.target + '"'
  if ([IO.Path]::GetExtension([string]$startup.target) -ieq '.ps1') {
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
      throw 'The supported Windows PowerShell runtime is unavailable.'
    }
    $argumentLine = '-NoLogo -NoProfile -NonInteractive -File "' + [string]$startup.target + '"'
  }
  if ($startup.kind -eq 'project') {
    $packageRunnerPath = Join-Path $releaseRoot 'runtime\pnpm\pnpm.cmd'
    if (-not (Test-Path -LiteralPath $packageRunnerPath -PathType Leaf)) {
      $packageRunnerPath = Join-Path $releaseRoot 'runtime\node\npm.cmd'
    }
    if (-not (Test-Path -LiteralPath $packageRunnerPath -PathType Leaf)) {
      throw 'The selected Widget release does not contain its required npm or pnpm package runner.'
    }
    if ($packageRunnerPath -match '[\x00"%&|<>^!()\r\n]' -or
        ([string]$startup.workingDirectory) -match '[\x00"%&|<>^!()\r\n]') {
      throw 'Managed package startup contains unsupported shell characters.'
    }
    $trustedPackageRunners = @(
      (Join-Path $releaseRoot 'runtime\node\npm.cmd'),
      (Join-Path $releaseRoot 'runtime\pnpm\pnpm.cmd')
    )
    if ($trustedPackageRunners -notcontains [IO.Path]::GetFullPath($packageRunnerPath)) {
      throw 'Managed package startup requires the package-local npm or pnpm runner.'
    }
    $executable = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
      throw 'The supported cmd runtime is unavailable.'
    }
    $argumentLine = '/d /s /c ""' + $packageRunnerPath + '" run "' + [string]$startup.arguments + '""'
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$startup.arguments)) {
    $argumentLine += ' ' + [string]$startup.arguments
  }
  $pathValue = (Split-Path -Parent $nodePath) + ';' +
    (Join-Path $releaseRoot 'runtime\bin\override') + ';' + $env:PATH
  [Console]::Out.WriteLine($client::StartV2($HostPath, $runtimeRoot, [string]$item.id,
    $digest, $executable, $argumentLine, [string]$startup.workingDirectory, $healthUrlsJson,
    [string]$item.stopTarget, [string]$item.stopArgs, $pathValue))
}

$state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
$schemaVersion = [int]$state.schemaVersion
if ($schemaVersion -eq 5) {
  Invoke-V5ProductionControl -State $state
  exit 0
}
if ($schemaVersion -ne 4) {
  throw 'Only schemaVersion 4 legacy state and schemaVersion 5 managed state are supported.'
}
$item = @($state.items | Where-Object { [string]$_.id -ceq $ItemId }) | Select-Object -First 1
if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.health)) {
  throw 'The requested state item does not expose a managed health contract.'
}

$workingDirectory = if ([string]::IsNullOrWhiteSpace([string]$item.workingDirectory)) { '' } else {
  [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$item.workingDirectory).Trim()))
}
$contract = [ordered]@{
  version = 1
  startupTarget = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$item.startupTarget).Trim())).ToLowerInvariant()
  arguments = ([string]$item.startupArgs).Trim()
  workingDirectory = if ([string]::IsNullOrWhiteSpace($workingDirectory)) { '' } else { $workingDirectory.ToLowerInvariant() }
  health = ([uri][string]$item.health).AbsoluteUri
}
$hasher = [Security.Cryptography.SHA256]::Create()
try {
  $digest = ([BitConverter]::ToString($hasher.ComputeHash(
    [Text.Encoding]::UTF8.GetBytes(($contract | ConvertTo-Json -Compress))
  ))).Replace('-', '').ToLowerInvariant()
} finally { $hasher.Dispose() }

[void][Reflection.Assembly]::LoadFrom($HostPath)
$client = [WorkspaceWidget.Native.ManagedServiceClient]
$runtimeRoot = Split-Path -Parent $StatePath

if ($Action -eq 'Status') {
  [Console]::Out.WriteLine($client::Status($runtimeRoot, [string]$item.id, $digest, [string]$item.health))
  exit 0
}
if ($Action -eq 'Stop') {
  [Console]::Out.WriteLine($client::Stop($runtimeRoot, [string]$item.id, $digest, [string]$item.health, $false, $GracefulTimeoutMs))
  exit 0
}

$target = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$item.startupTarget).Trim()))
if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
    -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
  throw 'The state item startup target or working directory is unavailable.'
}
$nodePath = Join-Path (Split-Path -Parent $HostPath) 'runtime\node\node.exe'
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
  throw 'The selected Widget release does not contain its required Node runtime.'
}
$argumentLine = '"' + $target + '"'
if (-not [string]::IsNullOrWhiteSpace([string]$item.startupArgs)) {
  $argumentLine += ' ' + [string]$item.startupArgs
}
$releaseRoot = Split-Path -Parent $HostPath
$pathValue = (Split-Path -Parent $nodePath) + ';' +
  (Join-Path $releaseRoot 'runtime\bin\override') + ';' + $env:PATH
[Console]::Out.WriteLine($client::Start($HostPath, $runtimeRoot, [string]$item.id,
  $digest, $nodePath, $argumentLine, $workingDirectory, ([uri][string]$item.health).AbsoluteUri,
  $pathValue))
