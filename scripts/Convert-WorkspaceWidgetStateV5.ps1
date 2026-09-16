[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourceStatePath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [Parameter(Mandatory = $true)][string]$InstalledRoot,
  [string[]]$HideItemIds = @(),
  [switch]$WriteOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-ProductionFunction {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)

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

function Test-JsonObject { param($Value) return $null -ne $Value -and $Value -is [pscustomobject] }
function Test-JsonArray {
  param($Value)
  return $null -ne $Value -and $Value -is [Collections.IEnumerable] -and -not ($Value -is [string]) -and -not (Test-JsonObject $Value)
}

function Assert-OriginalValuesPreserved {
  param(
    [AllowNull()][AllowEmptyCollection()][Parameter(Mandatory = $true)]$Source,
    [AllowNull()][AllowEmptyCollection()][Parameter(Mandatory = $true)]$Migrated,
    [AllowEmptyString()][Parameter(Mandatory = $true)][string]$Path,
    [AllowEmptyCollection()][Parameter(Mandatory = $true)][Collections.Generic.HashSet[string]]$HiddenIds
  )

  if (Test-JsonObject $Source) {
    if (-not (Test-JsonObject $Migrated)) { throw "Migration changed object '$Path' into a non-object." }
    $sourceNames = @($Source.PSObject.Properties.Name)
    $migratedNames = @($Migrated.PSObject.Properties.Name)
    $lastIndex = -1
    foreach ($name in $sourceNames) {
      $index = [array]::IndexOf($migratedNames, $name)
      if ($index -lt 0 -or $index -le $lastIndex) { throw "Migration did not preserve field order at '$Path.$name'." }
      $lastIndex = $index
      $sourceValue = $Source.PSObject.Properties[$name].Value
      $migratedValue = $Migrated.PSObject.Properties[$name].Value
      $itemId = if ($Source.PSObject.Properties.Name -contains 'id') { [string]$Source.id } else { '' }
      if ($Path -eq '/items' -and $name -eq 'hidden' -and $HiddenIds.Contains($itemId)) { continue }
      if ($Path -eq '' -and $name -eq 'schemaVersion') { continue }
      Assert-OriginalValuesPreserved -Source $sourceValue -Migrated $migratedValue -Path "$Path/$name" -HiddenIds $HiddenIds
    }
    return
  }
  if (Test-JsonArray $Source) {
    if (-not (Test-JsonArray $Migrated) -or @($Source).Count -ne @($Migrated).Count) {
      throw "Migration changed array length at '$Path'."
    }
    for ($index = 0; $index -lt @($Source).Count; $index++) {
      $entryPath = if ($Path -eq '/items') { '/items' } else { "$Path/$index" }
      Assert-OriginalValuesPreserved -Source @($Source)[$index] -Migrated @($Migrated)[$index] -Path $entryPath -HiddenIds $HiddenIds
    }
    return
  }
  if ($Source -is [string] -or $Migrated -is [string]) {
    if ([string]$Source -cne [string]$Migrated) { throw "Migration changed string value at '$Path'." }
    return
  }
  if ($Source -ne $Migrated) { throw "Migration changed value at '$Path'." }
}

function Assert-OnlyAllowedNewFields {
  param([AllowNull()][AllowEmptyCollection()][Parameter(Mandatory = $true)]$Source, [AllowNull()][AllowEmptyCollection()][Parameter(Mandatory = $true)]$Migrated, [AllowEmptyString()][Parameter(Mandatory = $true)][string]$Path)

  if (Test-JsonObject $Source) {
    $allowed = if ($Path -eq '/window') {
      @('language','reduceMotion','edgeSnap')
    } elseif ($Path -eq '/items') {
      @('registrationType','healthChecks','stopTarget','stopArgs')
    } else { @() }
    foreach ($name in @($Migrated.PSObject.Properties.Name)) {
      if ($Source.PSObject.Properties.Name -contains $name) { continue }
      if ($allowed -notcontains $name) { throw "Migration introduced an unapproved field '$Path/$name'." }
    }
    foreach ($name in @($Source.PSObject.Properties.Name)) {
      Assert-OnlyAllowedNewFields -Source $Source.PSObject.Properties[$name].Value -Migrated $Migrated.PSObject.Properties[$name].Value -Path "$Path/$name"
    }
    return
  }
  if (Test-JsonArray $Source) {
    for ($index = 0; $index -lt @($Source).Count; $index++) {
      $entryPath = if ($Path -eq '/items') { '/items' } else { "$Path/$index" }
      Assert-OnlyAllowedNewFields -Source @($Source)[$index] -Migrated @($Migrated)[$index] -Path $entryPath
    }
  }
}

$SourceStatePath = [IO.Path]::GetFullPath($SourceStatePath)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$InstalledRoot = [IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\')
if ([string]::Equals($SourceStatePath, $OutputPath, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'OutputPath must be a new path and cannot equal SourceStatePath.'
}
if (-not (Test-Path -LiteralPath $SourceStatePath -PathType Leaf)) { throw 'SourceStatePath was not found.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'OutputPath already exists; migration never overwrites a file.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputPath) -PathType Container)) { throw 'OutputPath parent directory was not found.' }
$managedStopPath = Join-Path $InstalledRoot 'app\managed-stop.mjs'
if (-not (Test-Path -LiteralPath $managedStopPath -PathType Leaf)) { throw 'InstalledRoot has no app\managed-stop.mjs.' }

$sourceBytes = [IO.File]::ReadAllBytes($SourceStatePath)
$sourceHash = (Get-FileHash -LiteralPath $SourceStatePath -Algorithm SHA256).Hash
$sourceText = [IO.File]::ReadAllText($SourceStatePath, [Text.UTF8Encoding]::new($false, $true))
$source = $sourceText | ConvertFrom-Json
if ($null -eq $source -or [int]$source.schemaVersion -ne 4) { throw 'Only schemaVersion 4 input is accepted; existing v5 state is refused.' }
if ($null -eq $source.window -or @($source.items).Count -eq 0) { throw 'The v4 state document is incomplete.' }

$scriptRoot = Join-Path $InstalledRoot 'app'
Import-ProductionFunction -Path (Join-Path $scriptRoot 'WidgetExperience.ps1') -Name 'Initialize-ExperienceState'
Import-ProductionFunction -Path (Join-Path $scriptRoot 'WidgetExperience.ps1') -Name 'Initialize-ServerRegistration'
$migrated = ($source | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
$hiddenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($id in @($HideItemIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { $hiddenIds.Add([string]$id) | Out-Null }
$knownIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in @($migrated.items)) { $knownIds.Add([string]$item.id) | Out-Null }
foreach ($id in $hiddenIds) { if (-not $knownIds.Contains($id)) { throw "HideItemIds contains an unknown item id: $id" } }

Set-StrictMode -Off
try {
  Initialize-ExperienceState -WindowState $migrated.window
  foreach ($item in @($migrated.items)) {
    Initialize-ServerRegistration -Item $item
    if ($hiddenIds.Contains([string]$item.id)) { $item.hidden = $true }
  }
} finally {
  Set-StrictMode -Version Latest
}
$migrated.schemaVersion = 5
Assert-OriginalValuesPreserved -Source $source -Migrated $migrated -Path '' -HiddenIds $hiddenIds
Assert-OnlyAllowedNewFields -Source $source -Migrated $migrated -Path ''

$outputText = $migrated | ConvertTo-Json -Depth 30
$previewHash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($outputText))).Replace('-', '')
$result = [ordered]@{
  success = $true
  dryRun = -not [bool]$WriteOutput
  sourceStatePath = $SourceStatePath
  outputPath = $OutputPath
  sourceSha256 = $sourceHash
  outputSha256 = $previewHash
  sourceSchemaVersion = 4
  outputSchemaVersion = 5
  itemCount = @($migrated.items).Count
  hiddenItemIds = @($hiddenIds | Sort-Object)
  installedManagedStopPath = $managedStopPath
}
if ($WriteOutput) {
  $outputStream = $null
  $outputWriter = $null
  try {
    $outputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $outputWriter = [IO.StreamWriter]::new($outputStream, [Text.UTF8Encoding]::new($true))
    $outputWriter.Write($outputText)
  } finally {
    if ($null -ne $outputWriter) { $outputWriter.Dispose() }
    elseif ($null -ne $outputStream) { $outputStream.Dispose() }
  }
  $readbackText = [IO.File]::ReadAllText($OutputPath, [Text.UTF8Encoding]::new($false, $true))
  if ($readbackText -cne $outputText) { throw 'The v5 output text did not survive strict UTF-8 readback.' }
  $readback = $readbackText | ConvertFrom-Json
  if ([int]$readback.schemaVersion -ne 5 -or @($readback.items).Count -ne @($source.items).Count) {
    throw 'The v5 output did not survive strict schema/count readback.'
  }
  Assert-OriginalValuesPreserved -Source $source -Migrated $readback -Path '' -HiddenIds $hiddenIds
  Assert-OnlyAllowedNewFields -Source $source -Migrated $readback -Path ''
  $result.outputSha256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
}
[pscustomobject]$result | ConvertTo-Json -Compress
