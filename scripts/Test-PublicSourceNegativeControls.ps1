[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$scannerPath = Join-Path $ProjectRoot 'scripts\Test-PublicSource.ps1'
if (-not (Test-Path -LiteralPath $scannerPath -PathType Leaf)) {
  throw 'The public-source scanner was not found.'
}

function Invoke-GitHistoryNegativeControl {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('fail', 'empty')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string[]]$ExpectedRules
  )

  $env:WW_PUBLIC_SOURCE_NEGATIVE_SCANNER = $scannerPath
  $env:WW_PUBLIC_SOURCE_NEGATIVE_ROOT = $ProjectRoot
  $env:WW_PUBLIC_SOURCE_NEGATIVE_MODE = $Mode
  try {
    $childScript = @'
$scannerPath = $env:WW_PUBLIC_SOURCE_NEGATIVE_SCANNER
$projectRoot = $env:WW_PUBLIC_SOURCE_NEGATIVE_ROOT
$mode = $env:WW_PUBLIC_SOURCE_NEGATIVE_MODE
$realGit = (Get-Command git.exe -ErrorAction Stop).Source

function global:git {
  if ($args -contains 'log') {
    if ($mode -eq 'fail') {
      & $env:ComSpec /d /c 'exit 73'
      return
    }
    & $env:ComSpec /d /c 'exit 0'
    return
  }
  & $realGit @args
}

& $scannerPath -ProjectRoot $projectRoot
'@
    $output = @(
      & powershell.exe `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -Command $childScript 2>&1
    )
    $exitCode = $LASTEXITCODE
  } finally {
    Remove-Item Env:WW_PUBLIC_SOURCE_NEGATIVE_SCANNER `
      -ErrorAction SilentlyContinue
    Remove-Item Env:WW_PUBLIC_SOURCE_NEGATIVE_ROOT `
      -ErrorAction SilentlyContinue
    Remove-Item Env:WW_PUBLIC_SOURCE_NEGATIVE_MODE `
      -ErrorAction SilentlyContinue
  }

  $outputText = [string]::Join(
    "`n",
    @($output | ForEach-Object { [string]$_ })
  )
  if ($exitCode -ne 1) {
    throw "The '$Mode' history fixture exited $exitCode instead of 1."
  }
  try {
    $fixtureResult = $outputText | ConvertFrom-Json
  } catch {
    throw "The '$Mode' history fixture did not return scanner JSON."
  }
  $reportedRules = @(
    $fixtureResult.findings |
      ForEach-Object { [string]$_.rule }
  )
  foreach ($expectedRule in $ExpectedRules) {
    if ($expectedRule -notin $reportedRules) {
      throw "The '$Mode' history fixture did not report '$expectedRule'."
    }
  }

  return [pscustomobject][ordered]@{
    mode = $Mode
    exitCode = $exitCode
    expectedRules = @($ExpectedRules)
    reportedRules = @($reportedRules)
  }
}

$tests = @(
  Invoke-GitHistoryNegativeControl `
    -Mode 'fail' `
    -ExpectedRules @(
      'git-history-enumeration-failed',
      'empty-git-history'
    )
  Invoke-GitHistoryNegativeControl `
    -Mode 'empty' `
    -ExpectedRules @('empty-git-history')
)

[pscustomobject][ordered]@{
  success = $true
  testCount = $tests.Count
  tests = @($tests)
} | ConvertTo-Json -Depth 6

$global:LASTEXITCODE = 0
