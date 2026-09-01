[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$StageRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '0.1.3',
  [string]$PackageVersion,
  [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')]
  [string]$PackageIdentityName = 'WorkspaceWidget.Development',
  [string]$Publisher = 'CN=WorkspaceWidgetDevelopment',
  [string]$PublisherDisplayName = 'Workspace Widget Contributors',
  [string]$DisplayName = 'Workspace Widget',
  [string]$IdentityFile,
  [string]$StageManifestPath,
  [string]$SourceRevision,
  [string]$OutputRoot,
  [string]$MakeAppxPath,
  [string]$CompilerPath,
  [string]$SystemRuntimeFacadePath,
  [switch]$StoreSubmission
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')

$versionParts = @($Version.Split('.'))
if (
  $versionParts.Count -ne 3 -or
  @(
    $versionParts |
      Where-Object { $_ -notmatch '^\d{1,5}$' -or [int]$_ -gt 65535 }
  ).Count -gt 0
) {
  throw 'Version segments must be integers between 0 and 65535.'
}
if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
  $PackageVersion = "$Version.0"
}
$packageVersionParts = @($PackageVersion.Split('.'))
if (
  $packageVersionParts.Count -ne 4 -or
  @(
    $packageVersionParts |
      Where-Object { $_ -notmatch '^\d{1,5}$' -or [int]$_ -gt 65535 }
  ).Count -gt 0
) {
  throw 'PackageVersion must contain four integer segments from 0 to 65535.'
}
if (
  $StoreSubmission -and (
    [int]$packageVersionParts[0] -eq 0 -or
    [int]$packageVersionParts[3] -ne 0
  )
) {
  throw (
    'Microsoft Store package versions require a nonzero first segment and ' +
    'a zero fourth segment. Pass a value such as -PackageVersion 1.0.0.0.'
  )
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $buildBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    [System.IO.Path]::GetTempPath()
  } else {
    $env:LOCALAPPDATA
  }
  $outputParent = if ($StoreSubmission) {
    Join-Path $buildBase 'WorkspaceWidget\StoreBuilds'
  } else {
    Join-Path $buildBase 'WorkspaceWidget\MsixBuilds'
  }
  $OutputRoot = Join-Path $outputParent (
    'WorkspaceWidget-' +
    $Version +
    '-' +
    (Get-Date -Format 'yyyyMMdd-HHmmssfff')
  )
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')

if ($StoreSubmission) {
  $projectPrefix = $ProjectRoot + '\'
  if (
    [string]::Equals(
      $OutputRoot,
      $ProjectRoot,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $OutputRoot.StartsWith(
      $projectPrefix,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw (
      'StoreSubmission OutputRoot must be outside ProjectRoot so build output ' +
      'cannot change the clean source-tree status.'
    )
  }
  if (Test-Path -LiteralPath $OutputRoot) {
    throw (
      'StoreSubmission requires a fresh, non-existing OutputRoot: ' +
      $OutputRoot
    )
  }
} else {
  if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    throw 'StageRoot is required for development MSIX validation builds.'
  }
  $StageRoot = [System.IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
    throw "StageRoot was not found: $StageRoot"
  }
}

if ($StoreSubmission -and [string]::IsNullOrWhiteSpace($IdentityFile)) {
  throw (
    'StoreSubmission requires IdentityFile with the exact Partner Center ' +
    'Product identity values.'
  )
}
if (
  $StoreSubmission -and (
    -not [string]::IsNullOrWhiteSpace($StageRoot) -or
    -not [string]::IsNullOrWhiteSpace($StageManifestPath)
  )
) {
  throw (
    'StoreSubmission rebuilds its own stage from the clean Git checkout. ' +
    'Do not pass StageRoot or StageManifestPath.'
  )
}

if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
  $resolvedIdentityFile = [System.IO.Path]::GetFullPath($IdentityFile)
  if (-not (Test-Path -LiteralPath $resolvedIdentityFile -PathType Leaf)) {
    throw "IdentityFile was not found: $resolvedIdentityFile"
  }
  $identity = Get-Content -LiteralPath $resolvedIdentityFile -Raw |
    ConvertFrom-Json
  foreach ($propertyName in @(
      'packageIdentityName',
      'publisher',
      'publisherDisplayName'
    )) {
    if (
      -not ($identity.PSObject.Properties.Name -contains $propertyName) -or
      [string]::IsNullOrWhiteSpace([string]$identity.$propertyName)
    ) {
      throw "IdentityFile is missing '$propertyName'."
    }
  }
  $PackageIdentityName = [string]$identity.packageIdentityName
  $Publisher = [string]$identity.publisher
  $PublisherDisplayName = [string]$identity.publisherDisplayName
}

if ($PackageIdentityName -notmatch '^[A-Za-z0-9.-]{3,50}$') {
  throw 'PackageIdentityName is not a valid MSIX package identity name.'
}
if (
  [string]::IsNullOrWhiteSpace($Publisher) -or
  [string]::IsNullOrWhiteSpace($PublisherDisplayName)
) {
  throw 'Publisher and PublisherDisplayName are required.'
}
if (
  $StoreSubmission -and (
    $PackageIdentityName -eq 'WorkspaceWidget.Development' -or
    $Publisher -eq 'CN=WorkspaceWidgetDevelopment' -or
    $PublisherDisplayName -eq 'Workspace Widget Contributors' -or
    $PackageIdentityName -match
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE' -or
    $Publisher -match
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE' -or
    $PublisherDisplayName -match
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE'
  )
) {
  throw (
    'StoreSubmission requires the exact Identity Name, Publisher, and ' +
    'PublisherDisplayName values from Partner Center Product identity.'
  )
}

$gitMetadataPath = Join-Path $ProjectRoot '.git'
$preBuildSourceClean = $null
$postBuildSourceClean = $null
$sourceBuildRoot = $null
if ($StoreSubmission) {
  if (-not (Test-Path -LiteralPath $gitMetadataPath)) {
    throw (
      'StoreSubmission requires a Git checkout so the exact source revision ' +
      'can be bound to the package receipt.'
    )
  }
  $git = Get-Command git.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrWhiteSpace($git)) {
    throw 'StoreSubmission requires git.exe to verify the source revision.'
  }
  $detectedRevision = (& $git -C $ProjectRoot rev-parse HEAD 2>$null) -join ''
  if ($LASTEXITCODE -ne 0 -or $detectedRevision -notmatch '^[0-9a-fA-F]{40,64}$') {
    throw 'The Store source revision could not be resolved from Git.'
  }
  $detectedRevision = $detectedRevision.ToLowerInvariant()
  if (
    -not [string]::IsNullOrWhiteSpace($SourceRevision) -and
    -not [string]::Equals(
      $SourceRevision,
      $detectedRevision,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw 'SourceRevision does not match the checked-out Git HEAD.'
  }
  $SourceRevision = $detectedRevision
  $sourceStatus = (& $git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw 'The Git working-tree state could not be inspected.'
  }
  if (-not [string]::IsNullOrWhiteSpace($sourceStatus)) {
    throw 'StoreSubmission requires a clean Git working tree.'
  }
  $preBuildSourceClean = $true

  $sourceBuildScript = Join-Path `
    $ProjectRoot `
    'scripts\Build-WorkspaceWidget.ps1'
  if (-not (Test-Path -LiteralPath $sourceBuildScript -PathType Leaf)) {
    throw "The source-stage build script was not found: $sourceBuildScript"
  }
  $sourceBuildRoot = Join-Path $OutputRoot 'source-build'
  $sourceBuildParameters = @{
    ProjectRoot = $ProjectRoot
    Version = $Version
    OutputRoot = $sourceBuildRoot
    SourceRevision = $SourceRevision
    SkipInstaller = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($CompilerPath)) {
    $sourceBuildParameters.CompilerPath = $CompilerPath
  }
  if (-not [string]::IsNullOrWhiteSpace($SystemRuntimeFacadePath)) {
    $sourceBuildParameters.SystemRuntimeFacadePath =
      $SystemRuntimeFacadePath
  }
  $sourceBuildRaw = & $sourceBuildScript @sourceBuildParameters
  $sourceBuildResult = ($sourceBuildRaw -join [Environment]::NewLine) |
    ConvertFrom-Json
  if (
    -not [bool]$sourceBuildResult.success -or
    [string]::IsNullOrWhiteSpace([string]$sourceBuildResult.stageRoot) -or
    [string]::IsNullOrWhiteSpace([string]$sourceBuildResult.manifest)
  ) {
    throw 'The clean-source Store stage build did not report valid outputs.'
  }
  $StageRoot = [System.IO.Path]::GetFullPath(
    [string]$sourceBuildResult.stageRoot
  ).TrimEnd('\')
  $StageManifestPath = [System.IO.Path]::GetFullPath(
    [string]$sourceBuildResult.manifest
  )

  $postBuildRevision = (
    & $git -C $ProjectRoot rev-parse HEAD 2>$null
  ) -join ''
  $postBuildRevisionExitCode = $LASTEXITCODE
  $postBuildStatus = (
    & $git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null
  ) -join "`n"
  $postBuildStatusExitCode = $LASTEXITCODE
  if (
    $postBuildRevisionExitCode -ne 0 -or
    $postBuildStatusExitCode -ne 0 -or
    -not [string]::Equals(
      $postBuildRevision,
      $SourceRevision,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    -not [string]::IsNullOrWhiteSpace($postBuildStatus)
  ) {
    throw (
      'The Git HEAD or working tree changed while the Store stage was being ' +
      'rebuilt. Use a new OutputRoot after restoring a clean checkout.'
    )
  }
  $postBuildSourceClean = $true
} else {
  if ([string]::IsNullOrWhiteSpace($StageManifestPath)) {
    $buildBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
      [System.IO.Path]::GetTempPath()
    } else {
      $env:LOCALAPPDATA
    }
    $StageManifestPath = Join-Path `
      $buildBase `
      "WorkspaceWidget\Builds\$Version\WorkspaceWidget-$Version-manifest.json"
  }
  $StageManifestPath = [System.IO.Path]::GetFullPath($StageManifestPath)
}

if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
  throw "StageRoot was not found: $StageRoot"
}
if (-not (Test-Path -LiteralPath $StageManifestPath -PathType Leaf)) {
  throw (
    'The paired stage manifest was not found. Build the stage with ' +
    'Build-WorkspaceWidget.ps1 or pass StageManifestPath explicitly: ' +
    $StageManifestPath
  )
}

$requiredStageFiles = @(
  'WorkspaceWidget.exe',
  'app\WorkspaceWidget.ps1',
  'app\default-state.json',
  'runtime\node\node.exe',
  'runtime\node\WORKSPACE-WIDGET-RUNTIME-MANIFEST.json',
  'lib\webview2\Microsoft.Web.WebView2.Core.dll',
  'lib\webview2\Microsoft.Web.WebView2.Wpf.dll',
  'WebView2Loader.dll',
  'LICENSE',
  'PRIVACY.md',
  'THIRD-PARTY-NOTICES.md'
)
foreach ($relativePath in $requiredStageFiles) {
  $requiredPath = Join-Path $StageRoot $relativePath
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "The Store package stage is incomplete: $requiredPath"
  }
}

$stageManifest = Get-Content -LiteralPath $StageManifestPath -Raw |
  ConvertFrom-Json
if (
  -not ($stageManifest.PSObject.Properties.Name -contains 'version') -or
  [string]$stageManifest.version -ne $Version -or
  -not ($stageManifest.PSObject.Properties.Name -contains 'files')
) {
  throw 'The paired stage manifest version or file list is invalid.'
}

$manifestRevision = 'unversioned'
$manifestDirty = $null
if (
  $stageManifest.PSObject.Properties.Name -contains 'source' -and
  $null -ne $stageManifest.source
) {
  if ($stageManifest.source.PSObject.Properties.Name -contains 'revision') {
    $manifestRevision = [string]$stageManifest.source.revision
  }
  if ($stageManifest.source.PSObject.Properties.Name -contains 'dirty') {
    $manifestDirty = $stageManifest.source.dirty
  }
}

if ($StoreSubmission) {
  if (
    $manifestRevision -eq 'unversioned' -or
    -not [string]::Equals(
      $manifestRevision,
      $SourceRevision,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $manifestDirty -ne $false
  ) {
    throw (
      'The stage manifest is not bound to the clean checked-out source ' +
      'revision. Rebuild the stage from this Git HEAD.'
    )
  }
  if (
    -not ($stageManifest.PSObject.Properties.Name -contains 'toolchain') -or
    $null -eq $stageManifest.toolchain -or
    -not (
      $stageManifest.toolchain.PSObject.Properties.Name -contains
        'deterministic'
    ) -or
    -not [bool]$stageManifest.toolchain.deterministic
  ) {
    throw (
      'StoreSubmission requires a stage built by a compiler with deterministic ' +
      'output enabled. Install a current Roslyn toolchain and rebuild.'
    )
  }
} elseif ([string]::IsNullOrWhiteSpace($SourceRevision)) {
  $SourceRevision = $manifestRevision
}

$declaredStageFiles = @{}
foreach ($entry in @($stageManifest.files)) {
  $declaredPath = ([string]$entry.path -replace '/', '\').TrimStart('\')
  if (
    [string]::IsNullOrWhiteSpace($declaredPath) -or
    [System.IO.Path]::IsPathRooted($declaredPath) -or
    $declaredPath -match '(^|\\)\.\.(\\|$)' -or
    $declaredStageFiles.ContainsKey($declaredPath)
  ) {
    throw "The stage manifest contains an invalid or duplicate path: $declaredPath"
  }
  if (
    -not ($entry.PSObject.Properties.Name -contains 'size') -or
    -not ($entry.PSObject.Properties.Name -contains 'sha256') -or
    [string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$'
  ) {
    throw "The stage manifest entry is incomplete: $declaredPath"
  }
  $declaredStageFiles[$declaredPath] = $entry
}

$stageFiles = @(
  Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force |
    Sort-Object FullName
)
$actualStagePaths = @{}
foreach ($sourceFile in $stageFiles) {
  $relativePath = $sourceFile.FullName.Substring($StageRoot.Length).TrimStart('\')
  $actualStagePaths[$relativePath] = $sourceFile
}
$unexpectedStagePaths = @(
  $actualStagePaths.Keys |
    Where-Object { -not $declaredStageFiles.ContainsKey($_) } |
    Sort-Object
)
$missingStagePaths = @(
  $declaredStageFiles.Keys |
    Where-Object { -not $actualStagePaths.ContainsKey($_) } |
    Sort-Object
)
if ($unexpectedStagePaths.Count -gt 0 -or $missingStagePaths.Count -gt 0) {
  throw (
    "The stage does not match its allowlisted manifest.`n" +
    "Unexpected:`n" +
    ($unexpectedStagePaths -join [Environment]::NewLine) +
    "`nMissing:`n" +
    ($missingStagePaths -join [Environment]::NewLine)
  )
}
foreach ($relativePath in $declaredStageFiles.Keys) {
  $sourceFile = $actualStagePaths[$relativePath]
  $entry = $declaredStageFiles[$relativePath]
  if (
    [int64]$entry.size -ne $sourceFile.Length -or
    -not [string]::Equals(
      [string]$entry.sha256,
      (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw "The stage file differs from its allowlisted manifest: $relativePath"
  }
}

$reparsePoints = @(
  Get-ChildItem -LiteralPath $StageRoot -Recurse -Force |
    Where-Object {
      ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    }
)
if ($reparsePoints.Count -gt 0) {
  throw (
    'The Store package stage contains reparse points. Packaging was refused: ' +
    ($reparsePoints.FullName -join ', ')
  )
}

$sensitiveStageFiles = @(
  Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force |
    Where-Object {
      $_.Name -match '(?i)\.(pfx|p12|pem|key)$' -or
      $_.Name -match '(?i)^(state\.json|runtime\.log|host\.log)$'
    }
)
if ($sensitiveStageFiles.Count -gt 0) {
  throw (
    'The Store package stage contains private or mutable files: ' +
    ($sensitiveStageFiles.FullName -join ', ')
  )
}

$stagePrefix = $StageRoot.TrimEnd('\') + '\'
if (
  [string]::Equals(
    $OutputRoot,
    $StageRoot,
    [System.StringComparison]::OrdinalIgnoreCase
  ) -or
  $OutputRoot.StartsWith(
    $stagePrefix,
    [System.StringComparison]::OrdinalIgnoreCase
  )
) {
  throw 'OutputRoot must not be StageRoot or a directory below StageRoot.'
}
$layoutRoot = Join-Path $OutputRoot 'layout'
$packageFileVersion = if ($StoreSubmission) { $PackageVersion } else { $Version }
$packagePath = Join-Path `
  $OutputRoot `
  "WorkspaceWidget-$packageFileVersion-x64.msix"
$receiptPath = Join-Path $OutputRoot 'store-package-receipt.json'

foreach ($newPath in @($layoutRoot, $packagePath, $receiptPath)) {
  if (Test-Path -LiteralPath $newPath) {
    throw (
      "The output path already exists. Use a new output directory so a " +
      "previous package is never overwritten: $newPath"
    )
  }
}
New-Item -ItemType Directory -Path $layoutRoot -Force | Out-Null

$legacyOnlyPaths = @(
  'scripts\Set-WorkspaceWidgetAutostart.ps1'
)
foreach ($sourceFile in $stageFiles) {
  $relativePath = $sourceFile.FullName.Substring($StageRoot.Length).TrimStart('\')
  if ($relativePath -in $legacyOnlyPaths) {
    continue
  }
  $destinationPath = Join-Path $layoutRoot $relativePath
  $destinationDirectory = Split-Path -Parent $destinationPath
  New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
  Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath
}

function New-StoreImage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,
    [Parameter(Mandatory = $true)]
    [int]$Width,
    [Parameter(Mandatory = $true)]
    [int]$Height
  )

  $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
  $bitmap = [System.Drawing.Bitmap]::new(
    $Width,
    $Height,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.CompositingQuality =
      [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode =
      [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode =
      [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.PixelOffsetMode =
      [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $padding = [Math]::Max(2, [int]([Math]::Min($Width, $Height) * 0.1))
    $availableWidth = $Width - (2 * $padding)
    $availableHeight = $Height - (2 * $padding)
    $scale = [Math]::Min(
      $availableWidth / [double]$sourceImage.Width,
      $availableHeight / [double]$sourceImage.Height
    )
    $drawWidth = [Math]::Max(1, [int]($sourceImage.Width * $scale))
    $drawHeight = [Math]::Max(1, [int]($sourceImage.Height * $scale))
    $left = [int](($Width - $drawWidth) / 2)
    $top = [int](($Height - $drawHeight) / 2)
    $graphics.DrawImage(
      $sourceImage,
      [System.Drawing.Rectangle]::new($left, $top, $drawWidth, $drawHeight)
    )
    $bitmap.Save(
      $DestinationPath,
      [System.Drawing.Imaging.ImageFormat]::Png
    )
  }
  finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    $sourceImage.Dispose()
  }
}

Add-Type -AssemblyName System.Drawing
$sourceLogo = Join-Path $ProjectRoot 'assets\workspace-widget-logo.png'
if (-not (Test-Path -LiteralPath $sourceLogo -PathType Leaf)) {
  throw "The Store logo source was not found: $sourceLogo"
}
$packageAssets = Join-Path $layoutRoot 'assets'
New-Item -ItemType Directory -Path $packageAssets -Force | Out-Null
New-StoreImage -SourcePath $sourceLogo `
  -DestinationPath (Join-Path $packageAssets 'StoreLogo.png') `
  -Width 50 -Height 50
New-StoreImage -SourcePath $sourceLogo `
  -DestinationPath (Join-Path $packageAssets 'Square44x44Logo.png') `
  -Width 44 -Height 44
New-StoreImage -SourcePath $sourceLogo `
  -DestinationPath (Join-Path $packageAssets 'Square150x150Logo.png') `
  -Width 150 -Height 150
New-StoreImage -SourcePath $sourceLogo `
  -DestinationPath (Join-Path $packageAssets 'Wide310x150Logo.png') `
  -Width 310 -Height 150

function ConvertTo-XmlValue {
  param([Parameter(Mandatory = $true)][string]$Value)
  return [System.Security.SecurityElement]::Escape($Value)
}

$manifestTemplatePath = Join-Path `
  $ProjectRoot `
  'packaging\msix\AppxManifest.template.xml'
if (-not (Test-Path -LiteralPath $manifestTemplatePath -PathType Leaf)) {
  throw "The MSIX manifest template was not found: $manifestTemplatePath"
}
$manifestContent = Get-Content -LiteralPath $manifestTemplatePath -Raw
$manifestContent = $manifestContent.
  Replace(
    '@@PACKAGE_IDENTITY_NAME@@',
    (ConvertTo-XmlValue -Value $PackageIdentityName)
  ).
  Replace(
    '@@PUBLISHER@@',
    (ConvertTo-XmlValue -Value $Publisher)
  ).
  Replace(
    '@@PUBLISHER_DISPLAY_NAME@@',
    (ConvertTo-XmlValue -Value $PublisherDisplayName)
  ).
  Replace(
    '@@DISPLAY_NAME@@',
    (ConvertTo-XmlValue -Value $DisplayName)
  ).
  Replace('@@PACKAGE_VERSION@@', $PackageVersion)
if ($manifestContent -match '@@[A-Z0-9_]+@@') {
  throw 'The generated AppxManifest.xml still contains an unresolved token.'
}
$manifestPath = Join-Path $layoutRoot 'AppxManifest.xml'
[System.IO.File]::WriteAllText(
  $manifestPath,
  $manifestContent,
  [System.Text.UTF8Encoding]::new($false)
)

if ([string]::IsNullOrWhiteSpace($MakeAppxPath)) {
  $MakeAppxPath = Get-ChildItem `
    -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') `
    -Recurse `
    -Filter 'makeappx.exe' `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\makeappx\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
if (
  [string]::IsNullOrWhiteSpace($MakeAppxPath) -or
  -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)
) {
  throw 'makeappx.exe was not found. Install the Windows 11 SDK or pass MakeAppxPath.'
}

$makeAppxOutput = & $MakeAppxPath `
  pack `
  /d $layoutRoot `
  /p $packagePath `
  /o 2>&1
if ($LASTEXITCODE -ne 0) {
  throw (
    "MakeAppx failed with exit code $LASTEXITCODE.`n" +
    ($makeAppxOutput -join [Environment]::NewLine)
  )
}
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
  throw "MakeAppx completed without producing '$packagePath'."
}

$finalSourceClean = $null
if ($StoreSubmission) {
  $finalRevision = (& $git -C $ProjectRoot rev-parse HEAD 2>$null) -join ''
  $finalRevisionExitCode = $LASTEXITCODE
  $finalStatus = (
    & $git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null
  ) -join "`n"
  $finalStatusExitCode = $LASTEXITCODE
  if (
    $finalRevisionExitCode -ne 0 -or
    $finalStatusExitCode -ne 0 -or
    -not [string]::Equals(
      $finalRevision,
      $SourceRevision,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    -not [string]::IsNullOrWhiteSpace($finalStatus)
  ) {
    throw (
      'The Git HEAD or working tree changed before the Store package receipt ' +
      'was sealed. Discard this output and rebuild into a new OutputRoot.'
    )
  }
  $finalSourceClean = $true
}

$packageFiles = @(
  Get-ChildItem -LiteralPath $layoutRoot -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      [ordered]@{
        path = $_.FullName.Substring($layoutRoot.Length).TrimStart('\')
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    }
)
$receipt = [ordered]@{
  schemaVersion = 4
  product = 'Workspace Widget'
  version = $Version
  packageVersion = $PackageVersion
  generatedAt = (Get-Date).ToString('o')
  distribution = if ($StoreSubmission) {
    'Microsoft Store MSIX submission'
  } else {
    'MSIX development validation'
  }
  storeSubmission = [bool]$StoreSubmission
  source = [ordered]@{
    revision = $SourceRevision
    stageManifestSha256 = (
      Get-FileHash -LiteralPath $StageManifestPath -Algorithm SHA256
    ).Hash
    stageFileCount = $stageFiles.Count
    toolchain = if (
      $stageManifest.PSObject.Properties.Name -contains 'toolchain'
    ) {
      $stageManifest.toolchain
    } else {
      $null
    }
  }
  provenance = [ordered]@{
    mode = if ($StoreSubmission) {
      'clean-git-rebuild'
    } else {
      'external-stage-validation'
    }
    sourceRebuilt = [bool]$StoreSubmission
    preBuildSourceClean = $preBuildSourceClean
    postBuildSourceClean = $postBuildSourceClean
    finalSourceClean = $finalSourceClean
  }
  packageSigned = $false
  signingDisposition = (
    'Unsigned producer artifact. Microsoft Store re-signs accepted MSIX ' +
    'submissions. Sideloading requires a separately trusted signature.'
  )
  identity = [ordered]@{
    name = $PackageIdentityName
    publisher = $Publisher
    publisherDisplayName = $PublisherDisplayName
  }
  startupTaskId = 'WorkspaceWidgetStartup'
  restrictedCapabilities = @('runFullTrust')
  packageFile = [System.IO.Path]::GetFileName($packagePath)
  packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
  packageSize = (Get-Item -LiteralPath $packagePath).Length
  fileCount = $packageFiles.Count
  files = $packageFiles
  packagingTool = [ordered]@{
    name = 'makeappx.exe'
    version = (
      [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
        $MakeAppxPath
      ).FileVersion
    )
  }
  buildInputs = [ordered]@{
    msixBuilderSha256 = (
      Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256
    ).Hash
    sourceBuilderSha256 = (
      Get-FileHash `
        -LiteralPath (
          Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidget.ps1'
        ) `
        -Algorithm SHA256
    ).Hash
    candidateVerifierSha256 = (
      Get-FileHash `
        -LiteralPath (
          Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidgetMsix.ps1'
        ) `
        -Algorithm SHA256
    ).Hash
    manifestTemplateSha256 = (
      Get-FileHash -LiteralPath $manifestTemplatePath -Algorithm SHA256
    ).Hash
  }
}
[System.IO.File]::WriteAllText(
  $receiptPath,
  ($receipt | ConvertTo-Json -Depth 8),
  [System.Text.UTF8Encoding]::new($false)
)

$candidateVerified = $false
if ($StoreSubmission) {
  $candidateVerifierPath = Join-Path `
    $ProjectRoot `
    'scripts\Test-WorkspaceWidgetMsix.ps1'
  $verificationOutput = & powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $candidateVerifierPath `
    -PackagePath $packagePath `
    -ReceiptPath $receiptPath `
    -IdentityFile $resolvedIdentityFile `
    -ProjectRoot $ProjectRoot `
    -StageManifestPath $StageManifestPath `
    -StoreCandidate 2>&1
  $verificationExitCode = $LASTEXITCODE
  if ($verificationExitCode -ne 0) {
    throw (
      'The independently invoked Store-candidate verifier rejected the ' +
      "package.`n" +
      ($verificationOutput -join [Environment]::NewLine)
    )
  }
  $verificationResult = (
    $verificationOutput -join [Environment]::NewLine
  ) | ConvertFrom-Json
  if (-not [bool]$verificationResult.success) {
    throw 'The Store-candidate verifier did not report success.'
  }
  $candidateVerified = $true
}

[pscustomobject]@{
  success = $true
  storeSubmission = [bool]$StoreSubmission
  candidateVerified = $candidateVerified
  package = $packagePath
  packageSha256 = $receipt.packageSha256
  receipt = $receiptPath
  identity = $receipt.identity
  fileCount = $packageFiles.Count
  signed = $false
} | ConvertTo-Json -Depth 5
