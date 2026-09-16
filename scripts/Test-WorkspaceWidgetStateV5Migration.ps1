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

function Read-JsonStrict {
  param([Parameter(Mandatory = $true)][string]$Path)
  $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
  return $text | ConvertFrom-Json
}

function Convert-CodePointsToString {
  param([Parameter(Mandatory = $true)][int[]]$CodePoints)
  return [string]::new([char[]]$CodePoints)
}

function Invoke-Converter {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $script:WindowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:ConverterPath @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
  } finally {
    $ErrorActionPreference = $oldPreference
  }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$script:ConverterPath = Join-Path $ProjectRoot 'scripts\Convert-WorkspaceWidgetStateV5.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$script:WindowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-That (Test-Path -LiteralPath $script:ConverterPath -PathType Leaf) 'Migration converter was not found.'
Assert-That (Test-Path -LiteralPath $experiencePath -PathType Leaf) 'Production WidgetExperience.ps1 was not found.'
Assert-That (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 was not found.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('workspace-widget-v5-migration-' + [Guid]::NewGuid().ToString('N'))
$installedRoot = Join-Path $fixtureRoot 'installed'
$sourcePath = Join-Path $fixtureRoot 'state-v4.json'
$outputDirectory = Join-Path $fixtureRoot 'output'
$outputPath = Join-Path $outputDirectory 'state-v5.json'
New-Item -ItemType Directory -Path (Join-Path $installedRoot 'app') -Force | Out-Null
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Copy-Item -LiteralPath $experiencePath -Destination (Join-Path $installedRoot 'app\WidgetExperience.ps1') -Force
[IO.File]::WriteAllText((Join-Path $installedRoot 'app\managed-stop.mjs'), "// isolated fixture only`n", [Text.UTF8Encoding]::new($false))
$windowText = Convert-CodePointsToString @(0xCC3D,0xC0C1,0xD0DC,0xBCF4,0xC874)
$ordinaryName = Convert-CodePointsToString @(0xC815,0xB82C,0xBCF4,0xC874,0x0020,0xBA54,0xBAA8)
$ordinaryCustomText = Convert-CodePointsToString @(0xAC00,0xB098,0xB2E4)
$serverName = Convert-CodePointsToString @(0xD55C,0xAD6D,0xC5B4,0x0020,0xC11C,0xBC84)
$preservedValue = Convert-CodePointsToString @(0xBCF4,0xC874,0x0020,0xAC12)
$hangulValue = Convert-CodePointsToString @(0xD55C,0xAE00)
$testOwner = Convert-CodePointsToString @(0xD14C,0xC2A4,0xD2B8)
$legacyName = Convert-CodePointsToString @(0xD638,0xCD9C,0xC790,0xAC00,0x0020,0xC228,0xAE38,0x0020,0xD56D,0xBAA9)

$source = [ordered]@{
  schemaVersion = 4
  window = [ordered]@{
    left = 122
    top = 56
    width = 448
    height = 612
    customWindowField = $windowText
  }
  items = @(
    [ordered]@{
      id = 'ordinary-note'
      name = $ordinaryName
      target = 'C:\Fixture\note.txt'
      arguments = ''
      workingDirectory = 'C:\Fixture'
      hidden = $false
      custom = [ordered]@{ text = $ordinaryCustomText; enabled = $true }
      nullable = $null
      emptyList = @()
    },
    [ordered]@{
      id = 'server-korean'
      name = $serverName
      target = 'C:\Fixture\start.cmd'
      arguments = ('--label "' + $preservedValue + '"')
      workingDirectory = 'C:\Fixture\server'
      startupTarget = 'C:\Fixture\start.cmd'
      startupArgs = '--port 43115'
      health = ('http://127.0.0.1:43115/health?name=' + $hangulValue)
      hidden = $false
      metadata = [ordered]@{ owner = $testOwner; order = 2 }
    },
    [ordered]@{
      id = 'localdock-legacy'
      name = $legacyName
      target = 'C:\Fixture\legacy.lnk'
      arguments = ''
      workingDirectory = 'C:\Fixture'
      hidden = $false
    }
  )
}
$sourceJson = [pscustomobject]$source | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($sourcePath, $sourceJson, [Text.UTF8Encoding]::new($true))
$sourceHashBefore = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$sourceTextBefore = [IO.File]::ReadAllText($sourcePath, [Text.UTF8Encoding]::new($false, $true))

$preview = Invoke-Converter -Arguments @('-SourceStatePath', $sourcePath, '-OutputPath', $outputPath, '-InstalledRoot', $installedRoot)
Assert-That ($preview.ExitCode -eq 0) ('Preview failed: ' + (($preview.Output | Out-String).Trim()))
Assert-That (-not (Test-Path -LiteralPath $outputPath)) 'Default preview wrote an output file.'
$previewResult = (($preview.Output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
Assert-That ($previewResult.dryRun -eq $true) 'Preview did not report dryRun=true.'
Assert-That ($previewResult.sourceSha256 -eq $sourceHashBefore) 'Preview source hash differed from the fixture source.'
Assert-That ($previewResult.outputSchemaVersion -eq 5) 'Preview did not report schema 5.'

$write = Invoke-Converter -Arguments @('-SourceStatePath', $sourcePath, '-OutputPath', $outputPath, '-InstalledRoot', $installedRoot, '-HideItemIds', 'localdock-legacy', '-WriteOutput')
Assert-That ($write.ExitCode -eq 0) ('Write failed: ' + (($write.Output | Out-String).Trim()))
Assert-That (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Explicit WriteOutput did not create a new output file.'
$writeResult = (($write.Output | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
Assert-That ($writeResult.dryRun -eq $false) 'Write did not report dryRun=false.'
Assert-That ($writeResult.sourceSha256 -eq $sourceHashBefore) 'Write source hash differed from the fixture source.'
Assert-That ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq $sourceHashBefore) 'Migration changed the source state file.'
Assert-That ([IO.File]::ReadAllText($sourcePath, [Text.UTF8Encoding]::new($false, $true)) -ceq $sourceTextBefore) 'Migration changed source state text.'

$migrated = Read-JsonStrict -Path $outputPath
Assert-That ($migrated.schemaVersion -eq 5) 'Output schemaVersion was not 5.'
Assert-That (@($migrated.items).Count -eq 3) 'Migration changed the item count.'
Assert-That ((@($migrated.items | ForEach-Object id) -join '|') -ceq 'ordinary-note|server-korean|localdock-legacy') 'Migration changed item order.'
Assert-That ($migrated.window.customWindowField -ceq $windowText) 'Migration changed a Unicode window value.'
Assert-That ($migrated.window.language -ceq 'ko-KR' -and $migrated.window.reduceMotion -eq $false -and $migrated.window.edgeSnap -eq $true) 'Window defaults were not added.'

$ordinary = @($migrated.items | Where-Object id -eq 'ordinary-note')[0]
Assert-That ($ordinary.name -ceq $ordinaryName -and $ordinary.custom.text -ceq $ordinaryCustomText) 'Migration changed ordinary Unicode metadata.'
Assert-That ($ordinary.registrationType -eq 'ordinary' -and @($ordinary.healthChecks).Count -eq 0 -and $ordinary.stopTarget -eq '' -and $ordinary.stopArgs -eq '') 'Ordinary registration defaults were incorrect.'

$server = @($migrated.items | Where-Object id -eq 'server-korean')[0]
Assert-That ($server.registrationType -eq 'server') 'Server registration type was incorrect.'
Assert-That (@($server.healthChecks).Count -eq 1 -and $server.healthChecks[0].url -ceq ('http://127.0.0.1:43115/health?name=' + $hangulValue)) 'Server health check was not preserved/derived.'
Assert-That ($server.stopTarget -ceq (Join-Path $installedRoot 'app\managed-stop.mjs') -and $server.stopArgs -eq '') 'Server stop target was not bound to InstalledRoot.'
Assert-That ($server.arguments -ceq ('--label "' + $preservedValue + '"') -and $server.metadata.owner -ceq $testOwner) 'Migration changed server metadata.'

$legacy = @($migrated.items | Where-Object id -eq 'localdock-legacy')[0]
Assert-That ($legacy.hidden -eq $true) 'Only caller-requested legacy item was not hidden.'
Assert-That ($ordinary.hidden -eq $false -and $server.hidden -eq $false) 'Migration hid an item not requested by the caller.'

$repeat = Invoke-Converter -Arguments @('-SourceStatePath', $sourcePath, '-OutputPath', $outputPath, '-InstalledRoot', $installedRoot, '-WriteOutput')
Assert-That ($repeat.ExitCode -ne 0) 'Converter overwrote an existing output path.'

$v5SourcePath = Join-Path $fixtureRoot 'already-v5.json'
$v5Source = Read-JsonStrict -Path $outputPath
$v5Source.schemaVersion = 5
[IO.File]::WriteAllText($v5SourcePath, ($v5Source | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true))
$v5Output = Join-Path $outputDirectory 'v5-rejected.json'
$v5Attempt = Invoke-Converter -Arguments @('-SourceStatePath', $v5SourcePath, '-OutputPath', $v5Output, '-InstalledRoot', $installedRoot, '-WriteOutput')
Assert-That ($v5Attempt.ExitCode -ne 0) 'Converter accepted schemaVersion 5 input.'
Assert-That (-not (Test-Path -LiteralPath $v5Output)) 'Rejected schema 5 input created output.'

[pscustomobject]@{
  success = $true
  fixtureRoot = $fixtureRoot
  assertions = 28
  sourceSha256 = $sourceHashBefore
  outputSha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
} | ConvertTo-Json -Compress
