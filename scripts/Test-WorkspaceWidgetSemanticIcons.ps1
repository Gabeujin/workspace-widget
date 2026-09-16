[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

Add-Type -AssemblyName PresentationCore

$iconRoot = Join-Path $ProjectRoot 'assets\semantic-icons'
$manifestPath = Join-Path $iconRoot 'manifest.json'
$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$defaultStatePath = Join-Path $ProjectRoot 'app\default-state.json'
$publicDefaultStatePath = Join-Path $ProjectRoot 'app\public-default-state.json'
$expectedIds = @(
  'launch',
  'service',
  'people',
  'workspace',
  'web',
  'data',
  'automation',
  'lab',
  'folder',
  'code',
  'terminal',
  'database',
  'document',
  'image',
  'video',
  'tools',
  'calendar',
  'settings'
)
$blockingFailures = [System.Collections.Generic.List[string]]::new()
$checks = [ordered]@{}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Semantic icon manifest was not found: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$appContent = Get-Content -LiteralPath $appPath -Raw
$defaultState = Get-Content -LiteralPath $defaultStatePath -Raw | ConvertFrom-Json
$publicDefaultState = Get-Content -LiteralPath $publicDefaultStatePath -Raw |
  ConvertFrom-Json
$iconResolutionProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $appPath `
  -ProjectRoot $ProjectRoot `
  -IconResolutionProbe | ConvertFrom-Json
$icons = @($manifest.icons)
$ids = @($icons | ForEach-Object { [string]$_.id })

$checks.manifestSchema = (
  ($manifest.schemaVersion -is [int] -or $manifest.schemaVersion -is [long]) -and
  [long]$manifest.schemaVersion -eq 1 -and
  $appContent -match '\$schemaVersionIsInteger' -and
  $appContent -match "contains a non-string field"
)
$checks.originalWorkProvenance = (
  [string]$manifest.provenance.type -eq 'original-work' -and
  [string]$manifest.license -eq 'MIT'
)
$checks.canonicalTaxonomy = (
  $ids.Count -eq $expectedIds.Count -and
  @($ids | Select-Object -Unique).Count -eq $expectedIds.Count -and
  @($expectedIds | Where-Object { $_ -notin $ids }).Count -eq 0
)
$checks.geometryContract = (
  [string]$manifest.geometry.viewBox -eq '0 0 24 24' -and
  [double]$manifest.geometry.strokeWidth -eq 1.75 -and
  [int]$manifest.geometry.safeInset -eq 2 -and
  [int]$manifest.geometry.rasterSize -eq 256
)
$customResolutionIndex = $appContent.IndexOf(
  '$customIcon = Get-CustomIconSource -Item $Item',
  [System.StringComparison]::Ordinal
)
$semanticResolutionIndex = $appContent.IndexOf(
  '$semanticIcon = Get-SemanticIconSource -Item $Item',
  [System.StringComparison]::Ordinal
)
$checks.losslessResolutionOrder = (
  $customResolutionIndex -ge 0 -and
  $semanticResolutionIndex -gt $customResolutionIndex -and
  $appContent -match '\$shellIcon = \[WorkspaceWidgetNative\]::GetShellIcon' -and
  $appContent -match '\$glyph = if \(\[string\]::IsNullOrWhiteSpace'
)
$checks.runtimeIntegration = (
  $appContent -match 'function Get-WorkspaceSemanticIconDefinitions' -and
  $appContent -match 'function Get-SemanticIconSource' -and
  $appContent -match 'iconPreset = \$iconPreset' -and
  $appContent -match '\$ExistingItem\.iconPreset = \$iconPreset' -and
  $appContent -match 'semanticIcons = @\(Get-WorkspaceSemanticIconDefinitions\)\.Count -gt 0'
)
$checks.runtimeResolutionProof = (
  $iconResolutionProbe.success -and
  @($iconResolutionProbe.results).Count -eq 4 -and
  @($iconResolutionProbe.results | Where-Object { -not $_.matched }).Count -eq 0 -and
  (@($iconResolutionProbe.results.actualKind) -join '>') -eq 'Custom>Semantic>Shell>None' -and
  $iconResolutionProbe.accessibility.matched
)
$checks.themeAwareForeground = (
  $appContent -match '\$maskHost\.OpacityMask = \$maskBrush' -and
  $appContent -match 'Convert-ToBrush \$script:themePalette\.text' -and
  $appContent -match '\[System\.Windows\.SystemParameters\]::HighContrast' -and
  $appContent -match '\[System\.Windows\.SystemColors\]::ControlTextBrush'
)
$checks.healthAccessibility = (
  $appContent -match 'function Set-LauncherCardHealthPresentation' -and
  $appContent -match "Get-WidgetText 'Open \{0\}\. Status: \{1\}\.'" -and
  $appContent -match 'AutomationLiveSetting\]::Polite' -and
  $appContent -match 'AutomationEvents\]::LiveRegionChanged'
)
$checks.accessibleSelector = (
  $appContent -match 'SetName\(\s*\r?\n\s*\$semanticIconBox,\s*\r?\n\s*''Built-in icon''' -and
  $appContent -match 'SetHelpText\(\s*\$semanticIconBox' -and
  $appContent -match 'Custom icons take priority'
)
$checks.backwardCompatibleState = (
  [int]$defaultState.schemaVersion -eq 4 -and
  [int]$publicDefaultState.schemaVersion -eq 4 -and
  @($defaultState.items).Count -eq 0 -and
  @($publicDefaultState.items).Count -eq 0
)

$assetChecks = foreach ($icon in $icons) {
  $id = [string]$icon.id
  $svgPath = Join-Path $iconRoot ([string]$icon.svg)
  $pngPath = Join-Path $iconRoot ([string]$icon.png)
  $svgValid = $false
  $pngValid = $false
  $transparent = $false
  $safeBounds = $false
  $smallSizeVisible = $false

  if (Test-Path -LiteralPath $svgPath -PathType Leaf) {
    $svg = Get-Content -LiteralPath $svgPath -Raw
    $svgValid = (
      [string]$icon.svg -eq "$id.svg" -and
      $svg -match 'viewBox="0 0 24 24"' -and
      $svg -match 'fill="none"' -and
      $svg -match 'stroke="currentColor"' -and
      $svg -match 'stroke-width="1\.75"' -and
      $svg -notmatch '<(?:script|image|foreignObject|style)\b' -and
      $svg -notmatch '(?:href|xlink:href|on\w+)\s*=' -and
      $svg -notmatch 'url\s*\('
    )
  }

  if (Test-Path -LiteralPath $pngPath -PathType Leaf) {
    $stream = [System.IO.File]::OpenRead($pngPath)
    try {
      $decoder = [System.Windows.Media.Imaging.PngBitmapDecoder]::new(
        $stream,
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      )
      $frame = $decoder.Frames[0]
      $pngValid = (
        [string]$icon.png -eq "$id.png" -and
        $frame.PixelWidth -eq 256 -and
        $frame.PixelHeight -eq 256
      )
      $converted = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new(
        $frame,
        [System.Windows.Media.PixelFormats]::Bgra32,
        $null,
        0
      )
      $stride = $converted.PixelWidth * 4
      $pixels = [byte[]]::new($stride * $converted.PixelHeight)
      $converted.CopyPixels($pixels, $stride, 0)
      $alpha = for ($index = 3; $index -lt $pixels.Length; $index += 4) {
        $pixels[$index]
      }
      $transparent = (($alpha | Measure-Object -Minimum).Minimum -eq 0) -and
        (($alpha | Measure-Object -Maximum).Maximum -gt 0)
      $visiblePixels = [System.Collections.Generic.List[object]]::new()
      for ($pixelIndex = 0; $pixelIndex -lt $alpha.Count; $pixelIndex++) {
        if ([int]$alpha[$pixelIndex] -gt 8) {
          $visiblePixels.Add([pscustomobject]@{
              x = $pixelIndex % $converted.PixelWidth
              y = [math]::Floor($pixelIndex / $converted.PixelWidth)
            })
        }
      }
      if ($visiblePixels.Count -gt 0) {
        $minimumX = ($visiblePixels.x | Measure-Object -Minimum).Minimum
        $maximumX = ($visiblePixels.x | Measure-Object -Maximum).Maximum
        $minimumY = ($visiblePixels.y | Measure-Object -Minimum).Minimum
        $maximumY = ($visiblePixels.y | Measure-Object -Maximum).Maximum
        $safeBounds = (
          $minimumX -ge 16 -and $minimumY -ge 16 -and
          $maximumX -le 239 -and $maximumY -le 239
        )
      }

      $smallBitmap = [System.Windows.Media.Imaging.TransformedBitmap]::new(
        $frame,
        [System.Windows.Media.ScaleTransform]::new(0.0625, 0.0625)
      )
      $smallConverted = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new(
        $smallBitmap,
        [System.Windows.Media.PixelFormats]::Bgra32,
        $null,
        0
      )
      $smallStride = $smallConverted.PixelWidth * 4
      $smallPixels = [byte[]]::new($smallStride * $smallConverted.PixelHeight)
      $smallConverted.CopyPixels($smallPixels, $smallStride, 0)
      $smallVisible = 0
      $smallEdgeVisible = 0
      for ($offset = 3; $offset -lt $smallPixels.Length; $offset += 4) {
        if ([int]$smallPixels[$offset] -le 8) {
          continue
        }
        $smallVisible++
        $smallPixelIndex = [math]::Floor($offset / 4)
        $smallX = $smallPixelIndex % $smallConverted.PixelWidth
        $smallY = [math]::Floor($smallPixelIndex / $smallConverted.PixelWidth)
        if (
          $smallX -eq 0 -or $smallY -eq 0 -or
          $smallX -eq ($smallConverted.PixelWidth - 1) -or
          $smallY -eq ($smallConverted.PixelHeight - 1)
        ) {
          $smallEdgeVisible++
        }
      }
      $smallSizeVisible = (
        $smallConverted.PixelWidth -eq 16 -and
        $smallConverted.PixelHeight -eq 16 -and
        $smallVisible -ge 6 -and
        $smallEdgeVisible -eq 0
      )
    } finally {
      $stream.Dispose()
    }
  }

  if (-not $svgValid) { $blockingFailures.Add("$id SVG contract") }
  if (-not $pngValid) { $blockingFailures.Add("$id PNG dimensions") }
  if (-not $transparent) { $blockingFailures.Add("$id PNG transparency") }
  if (-not $safeBounds) { $blockingFailures.Add("$id safe inset") }
  if (-not $smallSizeVisible) { $blockingFailures.Add("$id 16px visibility") }
  [pscustomobject][ordered]@{
    id = $id
    svgValid = $svgValid
    pngValid = $pngValid
    transparent = $transparent
    safeBounds = $safeBounds
    smallSizeVisible = $smallSizeVisible
  }
}

$checks.assetContracts = @($assetChecks | Where-Object {
    -not $_.svgValid -or -not $_.pngValid -or -not $_.transparent -or
    -not $_.safeBounds -or -not $_.smallSizeVisible
  }).Count -eq 0
$checks.stateDotSeparation = @(
  Get-ChildItem -LiteralPath $iconRoot -Filter '*.svg' -File |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '#(?:35DE8F|FF697D|7D91AE)' }
).Count -eq 0

foreach ($entry in $checks.GetEnumerator()) {
  if (-not [bool]$entry.Value) {
    $blockingFailures.Add([string]$entry.Key)
  }
}

$score = if ($blockingFailures.Count -eq 0) { 100.0 } else { 0.0 }
[pscustomobject][ordered]@{
  success = $blockingFailures.Count -eq 0
  score = $score
  gate = if ($blockingFailures.Count -eq 0) { '9.9 PASS' } else { 'FAIL CLOSED' }
  iconCount = $icons.Count
  checks = $checks
  assets = @($assetChecks)
  iconResolutionProbe = $iconResolutionProbe
  blockingFailures = @($blockingFailures)
} | ConvertTo-Json -Depth 8

if ($blockingFailures.Count -gt 0) {
  exit 1
}
