[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'),
  [switch]$Probe,
  [switch]$StateLifecycleProbe,
  [switch]$StartupProbe,
  [string]$StartupProbeTarget,
  [string]$StartupProbeHealth,
  [string]$StartupProbeArgs,
  [string]$StartupProbeExpectedToken,
  [switch]$StartupTargetProbe,
  [string]$ShortcutProbePath,
  [switch]$GeometryProbe,
  [switch]$MediaProbe,
  [switch]$IconResolutionProbe,
  [string]$RemoteAssetProbeSource,
  [switch]$NetworkBoundaryProbe,
  [double]$GeometryProbeLeft = 1000000,
  [double]$GeometryProbeTop = 1000000,
  [double]$GeometryProbeWidth = 430,
  [double]$GeometryProbeHeight = 1000,
  [double]$GeometryProbeActualWidth = 96,
  [double]$GeometryProbeActualHeight = 1000,
  [switch]$NoDesktopAttach,
  [string]$CapturePath,
  [int]$CaptureDelayMs = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $scriptRoot
}

$defaultStatePath = Join-Path $scriptRoot 'default-state.json'
$nativeHostPath = if (
  -not [string]::IsNullOrWhiteSpace($env:WORKSPACE_WIDGET_HOST_PATH) -and
  (Test-Path -LiteralPath $env:WORKSPACE_WIDGET_HOST_PATH -PathType Leaf)
) {
  [System.IO.Path]::GetFullPath($env:WORKSPACE_WIDGET_HOST_PATH)
} else {
  Join-Path $ProjectRoot 'WorkspaceWidget.exe'
}
$runtimeRoot = Split-Path -Parent $StatePath
$runtimeLog = Join-Path $runtimeRoot 'runtime.log'
$projectRuntimeRoot = Join-Path $ProjectRoot 'runtime'
$script:maximumStateBytes = 4MB
$script:maximumShortcutCount = 250
$script:maximumRuntimeLogBytes = 4MB
$script:maximumManagedCacheBytes = 128MB
$script:maximumLocalImageBytes = 64MB
$script:maximumLocalVideoBytes = 2GB
$script:maximumGifFrames = 240
$script:maximumGifAggregatePixels = 256000000
$script:semanticIconRoot = Join-Path $ProjectRoot 'assets\semantic-icons'
$script:semanticIconManifestPath = Join-Path $script:semanticIconRoot 'manifest.json'
$script:semanticIconDefinitionsInitialized = $false
$script:semanticIconDefinitions = @()
$script:semanticIconFailureLogged = $false
$script:invalidSemanticIconIds = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)

$packageNodePath = Join-Path $projectRuntimeRoot 'node\node.exe'
$packageNpmPath = Join-Path $projectRuntimeRoot 'node\npm.cmd'
$packagePnpmPath = Join-Path $projectRuntimeRoot 'pnpm\pnpm.cmd'
$expectedPackageHostPath = Join-Path $ProjectRoot 'WorkspaceWidget.exe'
$packageRuntimeEnforced = Test-Path `
  -LiteralPath $expectedPackageHostPath `
  -PathType Leaf
if ($packageRuntimeEnforced) {
  $nodeCandidates = @($packageNodePath)
  $pnpmCandidates = @($packagePnpmPath)
  $npmCandidates = @($packageNpmPath)
  $nodeRuntimeSource = if (Test-Path -LiteralPath $packageNodePath -PathType Leaf) {
    'PackageLocal'
  } else {
    'PackageLocalMissing'
  }
} else {
  $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  $systemPnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
  $systemNpm = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
  $nodeCandidates = @(
    $packageNodePath,
    $env:WORKSPACE_WIDGET_NODE,
    $(if ($null -ne $systemNode) { $systemNode.Source } else { $null })
  )
  $pnpmCandidates = @(
    $packagePnpmPath,
    $env:WORKSPACE_WIDGET_PNPM,
    $(if ($null -ne $systemPnpm) { $systemPnpm.Source } else { $null })
  )
  $npmCandidates = @(
    $packageNpmPath,
    $env:WORKSPACE_WIDGET_NPM,
    $(if ($null -ne $systemNpm) { $systemNpm.Source } else { $null })
  )
  $nodeRuntimeSource = 'Unavailable'
}
$bundledNodePath = $nodeCandidates |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
  Select-Object -First 1
$bundledPnpmPath = $pnpmCandidates |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
  Select-Object -First 1
$bundledNpmPath = $npmCandidates |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
  Select-Object -First 1
if (-not $packageRuntimeEnforced -and -not [string]::IsNullOrWhiteSpace($bundledNodePath)) {
  if ([string]::Equals(
      [System.IO.Path]::GetFullPath($bundledNodePath),
      [System.IO.Path]::GetFullPath($packageNodePath),
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    $nodeRuntimeSource = 'ProjectLocal'
  } elseif (
    -not [string]::IsNullOrWhiteSpace($env:WORKSPACE_WIDGET_NODE) -and
    (Test-Path -LiteralPath $env:WORKSPACE_WIDGET_NODE -PathType Leaf) -and
    [string]::Equals(
      [System.IO.Path]::GetFullPath($bundledNodePath),
      [System.IO.Path]::GetFullPath($env:WORKSPACE_WIDGET_NODE),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    $nodeRuntimeSource = 'DevelopmentOverride'
  } else {
    $nodeRuntimeSource = 'SystemPath'
  }
}
function Write-RuntimeLog {
  param([string]$Message)

  try {
    if (-not (Test-Path -LiteralPath $runtimeRoot)) {
      New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    }
    if (
      (Test-Path -LiteralPath $runtimeLog -PathType Leaf) -and
      (Get-Item -LiteralPath $runtimeLog).Length -ge $script:maximumRuntimeLogBytes
    ) {
      return
    }
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    [System.IO.File]::AppendAllText($runtimeLog, $line + [Environment]::NewLine)
  } catch {
    # Logging must never take the widget down.
  }
}

function Get-WorkspaceSemanticIconDefinitions {
  if ($script:semanticIconDefinitionsInitialized) {
    return @($script:semanticIconDefinitions)
  }

  $script:semanticIconDefinitionsInitialized = $true
  try {
    if (-not (Test-Path -LiteralPath $script:semanticIconManifestPath -PathType Leaf)) {
      throw 'The semantic icon manifest is missing.'
    }
    $manifestFile = Get-Item -LiteralPath $script:semanticIconManifestPath
    if ($manifestFile.Length -gt 64KB) {
      throw 'The semantic icon manifest is larger than 64 KiB.'
    }
    $manifest = Get-Content -LiteralPath $script:semanticIconManifestPath -Raw |
      ConvertFrom-Json
    $schemaVersionValue = $manifest.PSObject.Properties['schemaVersion'].Value
    $schemaVersionIsInteger = (
      $schemaVersionValue -is [int] -or
      $schemaVersionValue -is [long]
    )
    if (-not $schemaVersionIsInteger -or [long]$schemaVersionValue -ne 1) {
      throw 'The semantic icon manifest schema is unsupported.'
    }
    if (
      [string]$manifest.provenance.type -ne 'original-work' -or
      [string]$manifest.license -ne 'MIT'
    ) {
      throw 'The semantic icon manifest has no accepted provenance.'
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($script:semanticIconRoot).TrimEnd('\') + '\'
    $definitions = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($icon in @($manifest.icons)) {
      if (
        $icon.id -isnot [string] -or
        $icon.png -isnot [string] -or
        $icon.name -isnot [string] -or
        $icon.description -isnot [string]
      ) {
        throw 'A semantic icon entry contains a non-string field.'
      }
      $id = ([string]$icon.id).Trim().ToLowerInvariant()
      $pngName = ([string]$icon.png).Trim()
      $name = ([string]$icon.name).Trim()
      $description = ([string]$icon.description).Trim()
      if ($id -notmatch '^[a-z][a-z0-9-]{1,31}$') {
        throw "Semantic icon id '$id' is invalid."
      }
      if (-not $seenIds.Add($id)) {
        throw "Semantic icon id '$id' is duplicated."
      }
      if (
        [string]::IsNullOrWhiteSpace($name) -or
        $name.Length -gt 32 -or
        $name -match '[\x00-\x1F\x7F]'
      ) {
        throw "Semantic icon '$id' has an invalid display name."
      }
      if (
        [string]::IsNullOrWhiteSpace($description) -or
        $description.Length -gt 180 -or
        $description -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'
      ) {
        throw "Semantic icon '$id' has an invalid description."
      }
      if (-not [string]::Equals($pngName, "$id.png", [System.StringComparison]::Ordinal)) {
        throw "Semantic icon '$id' does not use its canonical PNG filename."
      }
      $pngPath = [System.IO.Path]::GetFullPath((Join-Path $script:semanticIconRoot $pngName))
      if (
        -not $pngPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $pngPath -PathType Leaf)
      ) {
        throw "Semantic icon '$id' has no trusted PNG asset."
      }
      $pngFile = Get-Item -LiteralPath $pngPath
      if ($pngFile.Length -gt 2MB) {
        throw "Semantic icon '$id' is larger than 2 MiB."
      }
      $definitions.Add([pscustomobject][ordered]@{
          id = $id
          name = $name
          description = $description
          pngPath = $pngPath
        })
    }
    if ($definitions.Count -lt 1 -or $definitions.Count -gt 24) {
      throw 'The semantic icon manifest must contain between 1 and 24 icons.'
    }
    $script:semanticIconDefinitions = @($definitions)
  } catch {
    $script:semanticIconDefinitions = @()
    if (-not $script:semanticIconFailureLogged) {
      Write-RuntimeLog "Semantic icon library was disabled. $($_.Exception.Message)"
      $script:semanticIconFailureLogged = $true
    }
  }
  return @($script:semanticIconDefinitions)
}

function Get-WorkspaceWidgetInstanceNames {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $normalizedPath = [System.IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($Path)
  ).Trim().ToLowerInvariant()
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString(
      $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
    ).Replace('-', '').ToLowerInvariant().Substring(0, 24)
  } finally {
    $hasher.Dispose()
  }
  $prefix = "Local\WorkspaceServiceWidget-$hash"
  return [pscustomobject][ordered]@{
    mutex = "$prefix-Mutex-v3"
    requestMutex = "$prefix-PresentationRequest-v2"
    ready = "$prefix-Ready-v2"
    show = "$prefix-Show-v3"
    presented = "$prefix-Presented-v2"
  }
}

$instanceNames = Get-WorkspaceWidgetInstanceNames -Path $StatePath

function Resolve-ShortcutRegistration {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
  $extension = [System.IO.Path]::GetExtension($expandedPath)
  $result = [ordered]@{
    success = $true
    kind = 'direct'
    originalPath = $Path
    target = $expandedPath
    launchArguments = ''
    workingDirectory = ''
    iconLocation = ''
    sourceShortcut = ''
    shortcutResolved = $false
    launchWindowStyle = 1
  }

  if ($extension -ieq '.url') {
    $result.kind = 'url'
    $result.sourceShortcut = $expandedPath
    try {
      $urlLine = Get-Content -LiteralPath $expandedPath |
        Where-Object { $_ -match '^URL=' } |
        Select-Object -First 1
      if ($null -eq $urlLine -or [string]::IsNullOrWhiteSpace($urlLine.Substring(4))) {
        throw 'The URL entry is missing.'
      }
      $result.target = $urlLine.Substring(4).Trim()
      $result.shortcutResolved = $true
    } catch {
      $result.success = $false
      Write-RuntimeLog "Could not resolve URL shortcut '$expandedPath'. $($_.Exception.Message)"
    }
    return [pscustomobject]$result
  }

  if ($extension -ine '.lnk') {
    return [pscustomobject]$result
  }

  $result.kind = 'lnk'
  $result.success = $false
  $result.sourceShortcut = $expandedPath
  $shell = $null
  $shortcut = $null
  try {
    if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
      throw 'The shortcut file does not exist.'
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($expandedPath)
    $targetPath = [Environment]::ExpandEnvironmentVariables(
      ([string]$shortcut.TargetPath).Trim()
    )
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
      throw 'The shortcut does not expose a target path.'
    }
    if (-not (Test-Path -LiteralPath $targetPath)) {
      throw "The shortcut target does not exist: $targetPath"
    }

    $workingDirectory = [Environment]::ExpandEnvironmentVariables(
      ([string]$shortcut.WorkingDirectory).Trim()
    )

    $result.target = $targetPath
    $result.launchArguments = [Environment]::ExpandEnvironmentVariables(
      ([string]$shortcut.Arguments).Trim()
    )
    $result.workingDirectory = $workingDirectory
    $result.iconLocation = [Environment]::ExpandEnvironmentVariables(
      ([string]$shortcut.IconLocation).Trim()
    )
    $result.launchWindowStyle = [int]$shortcut.WindowStyle
    $result.shortcutResolved = $true
    $result.success = $true
  } catch {
    Write-RuntimeLog "Could not resolve shell shortcut '$expandedPath'. $($_.Exception.Message)"
  } finally {
    if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
      [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
    }
    if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
      [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
  }

  return [pscustomobject]$result
}

function Initialize-ItemLaunchMetadata {
  param(
    [Parameter(Mandatory = $true)]
    $Item
  )

  $defaults = [ordered]@{
    startupTarget = ''
    startupArgs = ''
    launchArguments = ''
    workingDirectory = ''
    iconLocation = ''
    sourceShortcut = ''
    launchWindowStyle = 1
    customIcon = ''
    customIconCache = ''
    iconPreset = ''
    hoverMedia = ''
    hoverMediaKind = 'auto'
    hoverMediaMuted = $true
  }
  foreach ($entry in $defaults.GetEnumerator()) {
    if ($Item.PSObject.Properties.Name -notcontains $entry.Key) {
      $Item | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
  }
}

function Initialize-AppearanceState {
  param(
    [Parameter(Mandatory = $true)]
    $WindowState
  )

  $appearanceDefaults = [ordered]@{
    theme = 'Midnight'
    accentColor = '#FF3E8BFF'
    panelColor = '#EE09162B'
    cardColor = '#E80F203B'
    cardHoverColor = '#F2162F56'
    textColor = '#FFF6F9FF'
    backgroundMedia = ''
    backgroundMediaKind = 'auto'
    backgroundMediaOpacity = 0.42
    backgroundVideoMuted = $true
  }
  if ($WindowState.PSObject.Properties.Name -notcontains 'appearance') {
    $WindowState | Add-Member `
      -NotePropertyName appearance `
      -NotePropertyValue ([pscustomobject]$appearanceDefaults)
    return
  }

  foreach ($entry in $appearanceDefaults.GetEnumerator()) {
    if ($WindowState.appearance.PSObject.Properties.Name -notcontains $entry.Key) {
      $WindowState.appearance |
        Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
    }
  }
}

function Get-EffectiveWindowDimension {
  param(
    [double]$Configured,
    [double]$Actual
  )

  if (
    -not [double]::IsNaN($Configured) -and
    -not [double]::IsInfinity($Configured) -and
    $Configured -gt 1
  ) {
    return $Configured
  }
  if (
    -not [double]::IsNaN($Actual) -and
    -not [double]::IsInfinity($Actual) -and
    $Actual -gt 1
  ) {
    return $Actual
  }
  throw 'Neither the configured nor actual window dimension is valid.'
}

function Get-NormalizedWorkingDirectory {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }
  $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
  try {
    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    while (
      $fullPath.Length -gt $root.Length -and
      ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))
    ) {
      $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
  } catch {
    return $expanded
  }
}

function Resolve-VisibleWindowGeometry {
  param(
    [double]$Left,
    [double]$Top,
    [double]$Width,
    [double]$Height,
    [double]$MinWidth,
    [double]$MinHeight,
    [double]$MinimumVisibleWidth = 48.0,
    [double]$MinimumVisibleHeight = 48.0,
    [Parameter(Mandatory = $true)]
    [object[]]$WorkingAreas
  )

  foreach ($value in @($Left, $Top, $Width, $Height, $MinWidth, $MinHeight)) {
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) {
      throw 'Window geometry contains an invalid value.'
    }
  }
  if ($Width -le 1 -or $Height -le 1) {
    throw 'Window geometry must have a positive size.'
  }
  if ($WorkingAreas.Count -eq 0) {
    throw 'Windows did not report an active display.'
  }

  foreach ($area in $WorkingAreas) {
    $visibleWidth = [math]::Max(
      0.0,
      [math]::Min($Left + $Width, [double]$area.right) -
        [math]::Max($Left, [double]$area.left)
    )
    $visibleHeight = [math]::Max(
      0.0,
      [math]::Min($Top + $Height, [double]$area.bottom) -
        [math]::Max($Top, [double]$area.top)
    )
    if (
      $visibleWidth -ge [math]::Min($MinimumVisibleWidth, $Width) -and
      $visibleHeight -ge [math]::Min($MinimumVisibleHeight, $Height)
    ) {
      return [pscustomobject][ordered]@{
        adjusted = $false
        left = $Left
        top = $Top
        width = $Width
        height = $Height
        deviceName = [string]$area.deviceName
      }
    }
  }

  $centerX = $Left + ($Width / 2.0)
  $centerY = $Top + ($Height / 2.0)
  $targetArea = $null
  $targetDistance = [double]::PositiveInfinity
  foreach ($area in $WorkingAreas) {
    $nearestX = [math]::Max(
      [double]$area.left,
      [math]::Min([double]$area.right, $centerX)
    )
    $nearestY = [math]::Max(
      [double]$area.top,
      [math]::Min([double]$area.bottom, $centerY)
    )
    $distance = [math]::Pow($centerX - $nearestX, 2) +
      [math]::Pow($centerY - $nearestY, 2)
    if ($distance -lt $targetDistance) {
      $targetDistance = $distance
      $targetArea = $area
    }
  }
  if ($null -eq $targetArea) {
    throw 'No visible work area could be selected.'
  }

  $margin = 8.0
  $availableWidth = [math]::Max(1.0, [double]$targetArea.width - ($margin * 2.0))
  $availableHeight = [math]::Max(1.0, [double]$targetArea.height - ($margin * 2.0))
  $minimumWidth = [math]::Min([math]::Max(1.0, $MinWidth), $availableWidth)
  $minimumHeight = [math]::Min([math]::Max(1.0, $MinHeight), $availableHeight)
  $recoveredWidth = [math]::Min(
    $availableWidth,
    [math]::Max($minimumWidth, $Width)
  )
  $recoveredHeight = [math]::Min(
    $availableHeight,
    [math]::Max($minimumHeight, $Height)
  )
  $maximumLeft = [double]$targetArea.right - $recoveredWidth - $margin
  $maximumTop = [double]$targetArea.bottom - $recoveredHeight - $margin
  $recoveredLeft = [math]::Max(
    [double]$targetArea.left + $margin,
    [math]::Min($maximumLeft, $Left)
  )
  $recoveredTop = [math]::Max(
    [double]$targetArea.top + $margin,
    [math]::Min($maximumTop, $Top)
  )

  return [pscustomobject][ordered]@{
    adjusted = $true
    left = $recoveredLeft
    top = $recoveredTop
    width = $recoveredWidth
    height = $recoveredHeight
    deviceName = [string]$targetArea.deviceName
  }
}

if (-not [string]::IsNullOrWhiteSpace($ShortcutProbePath)) {
  $shortcutProbe = Resolve-ShortcutRegistration -Path $ShortcutProbePath
  $shortcutProbe | ConvertTo-Json -Depth 5
  if (-not $shortcutProbe.success) {
    exit 1
  }
  exit 0
}

if (-not (Test-Path -LiteralPath $defaultStatePath -PathType Leaf)) {
  throw "Default state not found at '$defaultStatePath'."
}

function Get-ValidatedStateDocument {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CandidatePaths
  )

  foreach ($candidate in $CandidatePaths) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    try {
      $candidateLength = (Get-Item -LiteralPath $candidate).Length
      if ($candidateLength -gt $script:maximumStateBytes) {
        throw "State document exceeds the $($script:maximumStateBytes)-byte limit."
      }
      $candidateState = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
      if (
        $null -ne $candidateState -and
        $candidateState.PSObject.Properties.Name -contains 'schemaVersion' -and
        [int]$candidateState.schemaVersion -gt 4
      ) {
        throw [System.NotSupportedException]::new(
          "State schema $($candidateState.schemaVersion) is newer than the supported schema 4. " +
          'The state file was left unchanged. Upgrade Workspace Widget before opening it.'
        )
      }
      if (
        $null -eq $candidateState -or
        $candidateState.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        [int]$candidateState.schemaVersion -lt 2
      ) {
        throw 'Unsupported state schema.'
      }
      if (@($candidateState.items).Count -gt $script:maximumShortcutCount) {
        throw "State contains more than $($script:maximumShortcutCount) shortcuts."
      }
      return [pscustomobject][ordered]@{
        state = $candidateState
        sourcePath = $candidate
      }
    } catch [System.NotSupportedException] {
      Write-RuntimeLog "State candidate '$candidate' requires a newer Workspace Widget. $($_.Exception.Message)"
      throw
    } catch {
      Write-RuntimeLog "State candidate '$candidate' could not be read. $($_.Exception.Message)"
    }
  }
  throw 'No valid state document was available.'
}

if ($Probe) {
  $stateSelection = Get-ValidatedStateDocument -CandidatePaths @(
    $StatePath,
    "$StatePath.previous",
    $defaultStatePath
  )
  $state = $stateSelection.state

  [pscustomobject]@{
    success = $true
    projectRoot = $ProjectRoot
    defaultStatePath = $defaultStatePath
    statePath = $StatePath
    stateSourcePath = [string]$stateSelection.sourcePath
    stateExists = Test-Path -LiteralPath $StatePath -PathType Leaf
    schemaVersion = $state.schemaVersion
    itemCount = @($state.items).Count
    visibleItemCount = @($state.items | Where-Object { -not $_.hidden }).Count
    hasSixServices = @($state.items | Where-Object { -not [string]::IsNullOrWhiteSpace($_.health) }).Count -ge 6
    defaultOpacity = [double]$state.window.opacity
    hoverBrightness = [bool]$state.window.hoverBrightness
    alwaysOnTop = (
      $state.window.PSObject.Properties.Name -contains 'alwaysOnTop' -and
      [bool]$state.window.alwaysOnTop
    )
    minUiMode = (
      $state.window.PSObject.Properties.Name -contains 'minUiMode' -and
      [bool]$state.window.minUiMode
    )
    attachToDesktop = [bool]$state.window.attachToDesktop
    bundledNodePath = $bundledNodePath
    nodeRuntimeSource = $nodeRuntimeSource
    packageRuntimeEnforced = $packageRuntimeEnforced
    bundledNodeAvailable = -not [string]::IsNullOrWhiteSpace($bundledNodePath) -and
      (Test-Path -LiteralPath $bundledNodePath -PathType Leaf)
    bundledPackageRunner = if (
      -not [string]::IsNullOrWhiteSpace($bundledPnpmPath)
    ) {
      $bundledPnpmPath
    } else {
      $bundledNpmPath
    }
    supports = [ordered]@{
      dragWindow = $true
      resizeWindow = $true
      dragDropFiles = $true
      dragDropUrls = $true
      smoothWheel = $true
      addEditHideSort = $true
      urlPortSubtitle = $true
      healthEndpoint = $true
      bundledNodeStartup = $true
      offlineServerRecovery = $true
      statePersistence = $true
      capture = $true
      trayLifecycle = $true
      minUiMode = $true
      autostartSetting = $true
      startupReadiness = $true
      lnkTargetResolution = $true
      visibleWorkAreaRecovery = $true
      mediaCustomization = $true
      semanticIcons = @(Get-WorkspaceSemanticIconDefinitions).Count -gt 0
      customThemes = $true
      youtubeHoverPreview = $true
    }
  } | ConvertTo-Json -Depth 7
  exit 0
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Windows.Forms

if ($null -eq ('WorkspaceWidgetPinnedHttpsClient' -as [type])) {
  $pinnedHttpsSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

public sealed class WorkspaceWidgetPinnedHttpsResponse
{
    public int StatusCode { get; set; }
    public IDictionary<string, string> Headers { get; set; }
    public byte[] Body { get; set; }
    public string RemoteAddress { get; set; }
}

public static class WorkspaceWidgetPinnedHttpsClient
{
    private const int MaximumHeaderBytes = 65536;
    private const int MaximumChunkMetadataBytes = 65536;

    public static WorkspaceWidgetPinnedHttpsResponse Get(
        Uri uri,
        IPAddress address,
        long maximumBytes,
        int connectTimeoutMilliseconds,
        int timeoutMilliseconds)
    {
        if (uri == null)
        {
            throw new ArgumentNullException("uri");
        }
        if (address == null)
        {
            throw new ArgumentNullException("address");
        }
        if (!String.Equals(
                uri.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Only HTTPS is supported.");
        }
        if (maximumBytes < 1 || maximumBytes > 67108864)
        {
            throw new ArgumentOutOfRangeException("maximumBytes");
        }
        if (timeoutMilliseconds < 1000 || timeoutMilliseconds > 60000)
        {
            throw new ArgumentOutOfRangeException("timeoutMilliseconds");
        }
        if (
            connectTimeoutMilliseconds < 250 ||
            connectTimeoutMilliseconds > timeoutMilliseconds)
        {
            throw new ArgumentOutOfRangeException(
                "connectTimeoutMilliseconds");
        }

        Stopwatch requestTimer = Stopwatch.StartNew();
        TcpClient client = new TcpClient(address.AddressFamily);
        try
        {
            IAsyncResult connect = client.BeginConnect(
                address,
                uri.Port,
                null,
                null);
            try
            {
                int connectWait = Math.Min(
                    connectTimeoutMilliseconds,
                    GetRemainingMilliseconds(
                        requestTimer,
                        timeoutMilliseconds));
                if (!connect.AsyncWaitHandle.WaitOne(connectWait))
                {
                    throw new TimeoutException(
                        "The pinned HTTPS connection timed out.");
                }
                client.EndConnect(connect);
            }
            finally
            {
                connect.AsyncWaitHandle.Close();
            }

            client.NoDelay = true;
            NetworkStream network = client.GetStream();
            int networkTimeout = GetRemainingMilliseconds(
                requestTimer,
                timeoutMilliseconds);
            network.ReadTimeout = networkTimeout;
            network.WriteTimeout = networkTimeout;
            using (
                SslStream tls = new SslStream(
                    network,
                    false,
                    delegate(
                        object sender,
                        X509Certificate certificate,
                        X509Chain chain,
                        SslPolicyErrors sslPolicyErrors)
                    {
                        return ValidateRemoteCertificate(
                            chain,
                            sslPolicyErrors);
                    }))
            {
                int tlsTimeout = GetRemainingMilliseconds(
                    requestTimer,
                    timeoutMilliseconds);
                tls.ReadTimeout = tlsTimeout;
                tls.WriteTimeout = tlsTimeout;
                IAsyncResult authenticate =
                    tls.BeginAuthenticateAsClient(
                    uri.IdnHost,
                    null,
                    SslProtocols.None,
                    true,
                    null,
                    null);
                try
                {
                    int authenticateWait = GetRemainingMilliseconds(
                        requestTimer,
                        timeoutMilliseconds);
                    if (!authenticate.AsyncWaitHandle.WaitOne(authenticateWait))
                    {
                        throw new TimeoutException(
                            "The pinned HTTPS TLS handshake timed out.");
                    }
                    tls.EndAuthenticateAsClient(authenticate);
                }
                finally
                {
                    authenticate.AsyncWaitHandle.Close();
                }

                string path = uri.PathAndQuery;
                if (String.IsNullOrEmpty(path))
                {
                    path = "/";
                }
                if (path.IndexOf('\r') >= 0 || path.IndexOf('\n') >= 0)
                {
                    throw new InvalidOperationException(
                        "The HTTPS request path is invalid.");
                }

                string host = uri.IdnHost;
                if (uri.HostNameType == UriHostNameType.IPv6)
                {
                    host = "[" + host + "]";
                }
                if (!uri.IsDefaultPort)
                {
                    host += ":" + uri.Port.ToString(
                        CultureInfo.InvariantCulture);
                }

                string request =
                    "GET " + path + " HTTP/1.1\r\n" +
                    "Host: " + host + "\r\n" +
                    "User-Agent: WorkspaceWidget/0.1\r\n" +
                    "Accept: image/png,image/jpeg,image/gif,image/bmp," +
                    "image/x-icon,image/vnd.microsoft.icon,image/svg+xml\r\n" +
                    "Accept-Encoding: identity\r\n" +
                    "Connection: close\r\n\r\n";
                byte[] requestBytes = Encoding.ASCII.GetBytes(request);
                tls.WriteTimeout = GetRemainingMilliseconds(
                    requestTimer,
                    timeoutMilliseconds);
                tls.Write(requestBytes, 0, requestBytes.Length);
                tls.Flush();

                WorkspaceWidgetPinnedHttpsResponse response =
                    ReadResponse(
                        tls,
                        maximumBytes,
                        requestTimer,
                        timeoutMilliseconds);
                response.RemoteAddress = address.ToString();
                return response;
            }
        }
        finally
        {
            client.Close();
        }
    }

    public static WorkspaceWidgetPinnedHttpsResponse ParseResponseForProbe(
        byte[] responseBytes,
        long maximumBytes,
        int timeoutMilliseconds)
    {
        if (responseBytes == null)
        {
            throw new ArgumentNullException("responseBytes");
        }
        using (MemoryStream stream = new MemoryStream(responseBytes, false))
        {
            return ReadResponse(
                stream,
                maximumBytes,
                Stopwatch.StartNew(),
                timeoutMilliseconds);
        }
    }

    public static bool DeadlineExpiresForProbe(int timeoutMilliseconds)
    {
        Stopwatch timer = Stopwatch.StartNew();
        Thread.Sleep(timeoutMilliseconds + 25);
        try
        {
            GetRemainingMilliseconds(timer, timeoutMilliseconds);
            return false;
        }
        catch (TimeoutException)
        {
            return true;
        }
    }

    public static bool TlsHandshakeTimesOutForProbe(
        int timeoutMilliseconds)
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        Thread serverThread = null;
        listener.Start();
        try
        {
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            serverThread = new Thread(
                delegate()
                {
                    try
                    {
                        using (
                            TcpClient accepted =
                                listener.AcceptTcpClient())
                        {
                            Thread.Sleep(timeoutMilliseconds + 500);
                        }
                    }
                    catch
                    {
                    }
                });
            serverThread.IsBackground = true;
            serverThread.Start();

            Stopwatch timer = Stopwatch.StartNew();
            try
            {
                Get(
                    new Uri(
                        "https://localhost:" +
                        port.ToString(CultureInfo.InvariantCulture) +
                        "/"),
                    IPAddress.Loopback,
                    16,
                    250,
                    timeoutMilliseconds);
                return false;
            }
            catch (TimeoutException)
            {
                return timer.ElapsedMilliseconds <=
                    timeoutMilliseconds + 500;
            }
        }
        finally
        {
            listener.Stop();
            if (serverThread != null)
            {
                serverThread.Join(2000);
            }
        }
    }

    public static bool EvaluateCertificatePolicyForProbe(
        SslPolicyErrors sslPolicyErrors,
        X509ChainStatusFlags[] chainStatuses)
    {
        return EvaluateCertificatePolicy(
            sslPolicyErrors,
            chainStatuses);
    }

    private static bool ValidateRemoteCertificate(
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors)
    {
        X509ChainStatusFlags[] statuses = null;
        if (chain != null)
        {
            statuses = new X509ChainStatusFlags[chain.ChainStatus.Length];
            for (int index = 0; index < chain.ChainStatus.Length; index++)
            {
                statuses[index] = chain.ChainStatus[index].Status;
            }
        }
        return EvaluateCertificatePolicy(
            sslPolicyErrors,
            statuses);
    }

    private static bool EvaluateCertificatePolicy(
        SslPolicyErrors sslPolicyErrors,
        X509ChainStatusFlags[] chainStatuses)
    {
        if (sslPolicyErrors == SslPolicyErrors.None)
        {
            return true;
        }
        if (
            sslPolicyErrors !=
            SslPolicyErrors.RemoteCertificateChainErrors ||
            chainStatuses == null)
        {
            return false;
        }

        bool sawUnavailableRevocationStatus = false;
        X509ChainStatusFlags unavailableRevocationFlags =
            X509ChainStatusFlags.RevocationStatusUnknown |
            X509ChainStatusFlags.OfflineRevocation;
        foreach (X509ChainStatusFlags status in chainStatuses)
        {
            if (status == X509ChainStatusFlags.NoError)
            {
                continue;
            }
            if (
                (status & unavailableRevocationFlags) != 0 &&
                (status & ~unavailableRevocationFlags) == 0)
            {
                sawUnavailableRevocationStatus = true;
                continue;
            }
            return false;
        }
        return sawUnavailableRevocationStatus;
    }

    private static int GetRemainingMilliseconds(
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        long remaining =
            (long)timeoutMilliseconds - requestTimer.ElapsedMilliseconds;
        if (remaining <= 0)
        {
            throw new TimeoutException(
                "The remote asset request timed out.");
        }
        return (int)Math.Min(Int32.MaxValue, remaining);
    }

    private static void PrepareRead(
        Stream stream,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        if (stream.CanTimeout)
        {
            stream.ReadTimeout = GetRemainingMilliseconds(
                requestTimer,
                timeoutMilliseconds);
        }
    }

    private static WorkspaceWidgetPinnedHttpsResponse ReadResponse(
        Stream stream,
        long maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        string headerText = ReadHeaders(
            stream,
            requestTimer,
            timeoutMilliseconds);
        string[] lines = headerText.Split(
            new string[] { "\r\n" },
            StringSplitOptions.None);
        if (lines.Length == 0)
        {
            throw new InvalidDataException("The HTTPS response is empty.");
        }

        string[] statusParts = lines[0].Split(new char[] { ' ' }, 3);
        int statusCode;
        if (
            !(
                lines[0].StartsWith(
                    "HTTP/1.0 ",
                    StringComparison.Ordinal) ||
                lines[0].StartsWith(
                    "HTTP/1.1 ",
                    StringComparison.Ordinal)
            ) ||
            statusParts.Length < 2 ||
            !Int32.TryParse(
                statusParts[1],
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out statusCode) ||
            statusCode < 100 ||
            statusCode > 599)
        {
            throw new InvalidDataException(
                "The HTTPS response status line is invalid.");
        }

        Dictionary<string, string> headers =
            new Dictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);
        for (int index = 1; index < lines.Length; index++)
        {
            if (
                lines[index].Length == 0 ||
                Char.IsWhiteSpace(lines[index][0]))
            {
                throw new InvalidDataException(
                    "The HTTPS response header format is invalid.");
            }
            int separator = lines[index].IndexOf(':');
            if (separator <= 0)
            {
                throw new InvalidDataException(
                    "The HTTPS response header format is invalid.");
            }
            string name = lines[index].Substring(0, separator).Trim();
            string value = lines[index].Substring(separator + 1).Trim();
            if (
                !IsValidHeaderName(name) ||
                !IsValidHeaderValue(value))
            {
                throw new InvalidDataException(
                    "The HTTPS response header name or value is invalid.");
            }
            string existing;
            if (headers.TryGetValue(name, out existing))
            {
                if (
                    String.Equals(
                        name,
                        "Content-Length",
                        StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(
                        name,
                        "Transfer-Encoding",
                        StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(
                        name,
                        "Content-Type",
                        StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(
                        name,
                        "Content-Encoding",
                        StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(
                        name,
                        "Location",
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "A security-sensitive HTTPS header was repeated.");
                }
                headers[name] = existing + "," + value;
            }
            else
            {
                headers[name] = value;
            }
        }

        string contentEncoding;
        if (
            headers.TryGetValue("Content-Encoding", out contentEncoding) &&
            !String.IsNullOrWhiteSpace(contentEncoding) &&
            !String.Equals(
                contentEncoding.Trim(),
                "identity",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Compressed remote assets are not accepted.");
        }

        byte[] body = new byte[0];
        if (statusCode >= 200 && statusCode < 300)
        {
            string transferEncoding;
            bool hasTransferEncoding = headers.TryGetValue(
                "Transfer-Encoding",
                out transferEncoding);
            if (hasTransferEncoding)
            {
                if (
                    !String.Equals(
                        transferEncoding.Trim(),
                        "chunked",
                        StringComparison.OrdinalIgnoreCase) ||
                    headers.ContainsKey("Content-Length"))
                {
                    throw new InvalidDataException(
                        "The HTTPS response framing is ambiguous or unsupported.");
                }
                body = ReadChunkedBody(
                    stream,
                    maximumBytes,
                    requestTimer,
                    timeoutMilliseconds);
            }
            else
            {
                string contentLengthText;
                long contentLength;
                if (headers.TryGetValue(
                        "Content-Length",
                        out contentLengthText))
                {
                    if (
                        !Int64.TryParse(
                            contentLengthText,
                            NumberStyles.None,
                            CultureInfo.InvariantCulture,
                            out contentLength) ||
                        contentLength < 0)
                    {
                        throw new InvalidDataException(
                            "The HTTPS Content-Length is invalid.");
                    }
                    if (contentLength > maximumBytes)
                    {
                        throw new InvalidDataException(
                            "The remote asset exceeds its size limit.");
                    }
                    body = ReadExactBody(
                        stream,
                        contentLength,
                        maximumBytes,
                        requestTimer,
                        timeoutMilliseconds);
                }
                else
                {
                    body = ReadUntilEnd(
                        stream,
                        maximumBytes,
                        requestTimer,
                        timeoutMilliseconds);
                }
            }
        }

        return new WorkspaceWidgetPinnedHttpsResponse
        {
            StatusCode = statusCode,
            Headers = headers,
            Body = body
        };
    }

    private static bool IsValidHeaderName(string name)
    {
        if (String.IsNullOrEmpty(name))
        {
            return false;
        }
        foreach (char character in name)
        {
            if (
                (character >= 'a' && character <= 'z') ||
                (character >= 'A' && character <= 'Z') ||
                (character >= '0' && character <= '9') ||
                "!#$%&'*+-.^_`|~".IndexOf(character) >= 0)
            {
                continue;
            }
            return false;
        }
        return true;
    }

    private static bool IsValidHeaderValue(string value)
    {
        foreach (char character in value)
        {
            if (
                (character < 32 && character != '\t') ||
                character == 127)
            {
                return false;
            }
        }
        return true;
    }

    private static string ReadHeaders(
        Stream stream,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        byte[] marker = new byte[] { 13, 10, 13, 10 };
        int matched = 0;
        using (MemoryStream headers = new MemoryStream())
        {
            while (headers.Length < MaximumHeaderBytes)
            {
                PrepareRead(
                    stream,
                    requestTimer,
                    timeoutMilliseconds);
                int value = stream.ReadByte();
                if (value < 0)
                {
                    throw new EndOfStreamException(
                        "The HTTPS response headers ended unexpectedly.");
                }
                headers.WriteByte((byte)value);
                if (value == marker[matched])
                {
                    matched++;
                    if (matched == marker.Length)
                    {
                        byte[] bytes = headers.ToArray();
                        return Encoding.GetEncoding(28591).GetString(
                            bytes,
                            0,
                            bytes.Length - marker.Length);
                    }
                }
                else
                {
                    matched = value == marker[0] ? 1 : 0;
                }
            }
        }
        throw new InvalidDataException(
            "The HTTPS response headers are too large.");
    }

    private static byte[] ReadExactBody(
        Stream stream,
        long length,
        long maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        using (MemoryStream body = new MemoryStream())
        {
            CopyExact(
                stream,
                body,
                length,
                maximumBytes,
                requestTimer,
                timeoutMilliseconds);
            return body.ToArray();
        }
    }

    private static byte[] ReadUntilEnd(
        Stream stream,
        long maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        using (MemoryStream body = new MemoryStream())
        {
            byte[] buffer = new byte[16384];
            int read;
            while (true)
            {
                PrepareRead(
                    stream,
                    requestTimer,
                    timeoutMilliseconds);
                read = stream.Read(buffer, 0, buffer.Length);
                if (read <= 0)
                {
                    break;
                }
                if (body.Length + read > maximumBytes)
                {
                    throw new InvalidDataException(
                        "The remote asset exceeds its size limit.");
                }
                body.Write(buffer, 0, read);
            }
            return body.ToArray();
        }
    }

    private static byte[] ReadChunkedBody(
        Stream stream,
        long maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        using (MemoryStream body = new MemoryStream())
        {
            long metadataBytes = 0;
            while (true)
            {
                string sizeLine = ReadAsciiLine(
                    stream,
                    8192,
                    requestTimer,
                    timeoutMilliseconds);
                AddChunkMetadata(
                    ref metadataBytes,
                    sizeLine.Length + 2);
                int extension = sizeLine.IndexOf(';');
                if (extension >= 0)
                {
                    sizeLine = sizeLine.Substring(0, extension);
                }
                long chunkSize;
                if (
                    !Int64.TryParse(
                        sizeLine.Trim(),
                        NumberStyles.HexNumber,
                        CultureInfo.InvariantCulture,
                        out chunkSize) ||
                    chunkSize < 0)
                {
                    throw new InvalidDataException(
                        "The chunked response is invalid.");
                }
                if (chunkSize == 0)
                {
                    while (true)
                    {
                        string trailer = ReadAsciiLine(
                            stream,
                            8192,
                            requestTimer,
                            timeoutMilliseconds);
                        AddChunkMetadata(
                            ref metadataBytes,
                            trailer.Length + 2);
                        if (trailer.Length == 0)
                        {
                            break;
                        }
                    }
                    return body.ToArray();
                }
                CopyExact(
                    stream,
                    body,
                    chunkSize,
                    maximumBytes,
                    requestTimer,
                    timeoutMilliseconds);
                PrepareRead(
                    stream,
                    requestTimer,
                    timeoutMilliseconds);
                if (stream.ReadByte() != 13)
                {
                    throw new InvalidDataException(
                        "The chunk delimiter is invalid.");
                }
                PrepareRead(
                    stream,
                    requestTimer,
                    timeoutMilliseconds);
                if (stream.ReadByte() != 10)
                {
                    throw new InvalidDataException(
                        "The chunk delimiter is invalid.");
                }
                AddChunkMetadata(ref metadataBytes, 2);
            }
        }
    }

    private static void AddChunkMetadata(
        ref long metadataBytes,
        long addedBytes)
    {
        metadataBytes += addedBytes;
        if (metadataBytes > MaximumChunkMetadataBytes)
        {
            throw new InvalidDataException(
                "The chunked response metadata is too large.");
        }
    }

    private static void CopyExact(
        Stream input,
        MemoryStream output,
        long length,
        long maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        if (output.Length + length > maximumBytes)
        {
            throw new InvalidDataException(
                "The remote asset exceeds its size limit.");
        }
        byte[] buffer = new byte[16384];
        long remaining = length;
        while (remaining > 0)
        {
            int requested = (int)Math.Min(buffer.Length, remaining);
            PrepareRead(
                input,
                requestTimer,
                timeoutMilliseconds);
            int read = input.Read(buffer, 0, requested);
            if (read <= 0)
            {
                throw new EndOfStreamException(
                    "The remote asset ended unexpectedly.");
            }
            output.Write(buffer, 0, read);
            remaining -= read;
        }
    }

    private static string ReadAsciiLine(
        Stream stream,
        int maximumBytes,
        Stopwatch requestTimer,
        int timeoutMilliseconds)
    {
        using (MemoryStream line = new MemoryStream())
        {
            while (line.Length < maximumBytes)
            {
                PrepareRead(
                    stream,
                    requestTimer,
                    timeoutMilliseconds);
                int value = stream.ReadByte();
                if (value < 0)
                {
                    throw new EndOfStreamException(
                        "The chunked response ended unexpectedly.");
                }
                if (value == 13)
                {
                    PrepareRead(
                        stream,
                        requestTimer,
                        timeoutMilliseconds);
                    if (stream.ReadByte() != 10)
                    {
                        throw new InvalidDataException(
                            "The response line delimiter is invalid.");
                    }
                    return Encoding.ASCII.GetString(line.ToArray());
                }
                line.WriteByte((byte)value);
            }
        }
        throw new InvalidDataException(
            "The response line is too large.");
    }
}
'@
  Add-Type -TypeDefinition $pinnedHttpsSource -Language CSharp
}

$script:webView2Available = $false
$script:webView2LoadError = $null
$webView2Roots = @(
  (Join-Path $ProjectRoot 'lib\webview2'),
  $(if (-not [string]::IsNullOrWhiteSpace($env:WORKSPACE_WIDGET_WEBVIEW2_ROOT)) {
      $env:WORKSPACE_WIDGET_WEBVIEW2_ROOT
    })
) | Where-Object {
  -not [string]::IsNullOrWhiteSpace($_) -and
  (Test-Path -LiteralPath $_ -PathType Container)
}
foreach ($webView2Root in $webView2Roots) {
  try {
    $coreAssembly = Join-Path $webView2Root 'Microsoft.Web.WebView2.Core.dll'
    $wpfAssembly = Join-Path $webView2Root 'Microsoft.Web.WebView2.Wpf.dll'
    if (
      (Test-Path -LiteralPath $coreAssembly -PathType Leaf) -and
      (Test-Path -LiteralPath $wpfAssembly -PathType Leaf)
    ) {
      Add-Type -Path $coreAssembly
      Add-Type -Path $wpfAssembly
      $script:webView2Available = $null -ne (
        'Microsoft.Web.WebView2.Wpf.WebView2' -as [type]
      )
      if ($script:webView2Available) {
        break
      }
    }
  } catch {
    $script:webView2LoadError = $_.Exception.Message
  }
}

if ($MediaProbe) {
  $controlCreated = $false
  $controlError = $null
  $probeControl = $null
  if ($script:webView2Available) {
    try {
      $probeControl = New-Object Microsoft.Web.WebView2.Wpf.WebView2
      $controlCreated = $null -ne $probeControl
    } catch {
      $controlError = $_.Exception.Message
    } finally {
      if ($null -ne $probeControl) {
        $probeControl.Dispose()
      }
    }
  }
  [pscustomobject]@{
    success = $true
    webView2AssembliesAvailable = $script:webView2Available
    webView2ControlCreated = $controlCreated
    webView2LoadError = $script:webView2LoadError
    webView2ControlError = $controlError
    webView2Roots = @($webView2Roots)
    nativeLoaderAvailable = Test-Path `
      -LiteralPath (Join-Path $ProjectRoot 'WebView2Loader.dll') `
      -PathType Leaf
    supportedImageExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.ico')
    supportedAnimatedImageExtensions = @('.gif')
    supportedVideoExtensions = @('.mp4', '.m4v', '.wmv', '.avi', '.mov')
    youtubePrivacyEnhancedEmbed = $true
    youtubeIdentifiedRequestHeaders = $true
    remoteCustomIconPreview = $true
    remoteCustomIconMaximumBytes = 2097152
    clipboardCustomIconPreview = $true
  } | ConvertTo-Json -Depth 6
  exit 0
}

if ($GeometryProbe) {
  $workingAreas = @(
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
      [pscustomobject]@{
        deviceName = $screen.DeviceName
        left = [double]$screen.WorkingArea.Left
        top = [double]$screen.WorkingArea.Top
        right = [double]$screen.WorkingArea.Right
        bottom = [double]$screen.WorkingArea.Bottom
        width = [double]$screen.WorkingArea.Width
        height = [double]$screen.WorkingArea.Height
      }
    }
  )
  $effectiveWidth = Get-EffectiveWindowDimension `
    -Configured $GeometryProbeWidth `
    -Actual $GeometryProbeActualWidth
  $effectiveHeight = Get-EffectiveWindowDimension `
    -Configured $GeometryProbeHeight `
    -Actual $GeometryProbeActualHeight
  $geometry = Resolve-VisibleWindowGeometry `
    -Left $GeometryProbeLeft `
    -Top $GeometryProbeTop `
    -Width $effectiveWidth `
    -Height $effectiveHeight `
    -MinWidth 430 `
    -MinHeight 500 `
    -WorkingAreas $workingAreas
  [pscustomobject]@{
    success = $true
    configuredWidth = $GeometryProbeWidth
    actualWidth = $GeometryProbeActualWidth
    effectiveWidth = $effectiveWidth
    geometry = $geometry
    workingAreas = $workingAreas
  } | ConvertTo-Json -Depth 6
  exit 0
}

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class WorkspaceWidgetNative
{
    public const int WM_NCHITTEST = 0x0084;
    public const int HTLEFT = 10;
    public const int HTRIGHT = 11;
    public const int HTTOP = 12;
    public const int HTTOPLEFT = 13;
    public const int HTTOPRIGHT = 14;
    public const int HTBOTTOM = 15;
    public const int HTBOTTOMLEFT = 16;
    public const int HTBOTTOMRIGHT = 17;
    public const uint SHGFI_ICON = 0x000000100;
    public const uint SHGFI_LARGEICON = 0x000000000;
    public const uint SHGFI_USEFILEATTRIBUTES = 0x000000010;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    public const int SW_SHOW = 5;
    public const int SW_RESTORE = 9;
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOPMOST = 0x00000008L;
    public const uint GW_OWNER = 4;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }

    private delegate bool MonitorEnumProc(
        IntPtr monitor,
        IntPtr hdc,
        ref NativeRect bounds,
        IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(
        IntPtr hWnd,
        out NativeRect rectangle);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr clip,
        MonitorEnumProc callback,
        IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(
        IntPtr monitor,
        ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(
        IntPtr hWnd,
        uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong32(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int index, int value);

    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);

    public static IntPtr GetWindowLongPtr(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, index)
            : new IntPtr(GetWindowLong32(hWnd, index));
    }

    public static void SetWindowOwner(IntPtr hWnd, IntPtr owner)
    {
        if (IntPtr.Size == 8)
        {
            SetWindowLongPtr64(hWnd, -8, owner);
        }
        else
        {
            SetWindowLong32(hWnd, -8, owner.ToInt32());
        }
    }

    public static IntPtr GetWindowOwner(IntPtr hWnd)
    {
        return GetWindow(hWnd, GW_OWNER);
    }

    public static bool IsTopmostWindow(IntPtr hWnd)
    {
        long extendedStyle = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
        return (extendedStyle & WS_EX_TOPMOST) == WS_EX_TOPMOST;
    }

    public static NativeRect GetPhysicalWindowRect(IntPtr hWnd)
    {
        NativeRect result;
        if (!GetWindowRect(hWnd, out result))
        {
            throw new InvalidOperationException(
                "Windows could not read the widget bounds.");
        }
        return result;
    }

    private static MONITORINFOEX ReadMonitorInfo(IntPtr monitor)
    {
        MONITORINFOEX info = new MONITORINFOEX();
        info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (!GetMonitorInfo(monitor, ref info))
        {
            throw new InvalidOperationException(
                "Windows could not read monitor geometry.");
        }
        return info;
    }

    public static NativeRect GetPhysicalWorkArea(IntPtr hWnd)
    {
        IntPtr monitor = MonitorFromWindow(hWnd, 2);
        if (monitor == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "Windows could not select a monitor for the widget.");
        }
        return ReadMonitorInfo(monitor).Work;
    }

    public static NativeRect[] GetPhysicalWorkAreas()
    {
        List<NativeRect> result = new List<NativeRect>();
        MonitorEnumProc callback = delegate(
            IntPtr monitor,
            IntPtr hdc,
            ref NativeRect bounds,
            IntPtr data)
        {
            result.Add(ReadMonitorInfo(monitor).Work);
            return true;
        };
        if (!EnumDisplayMonitors(
            IntPtr.Zero,
            IntPtr.Zero,
            callback,
            IntPtr.Zero))
        {
            throw new InvalidOperationException(
                "Windows could not enumerate active displays.");
        }
        return result.ToArray();
    }

    public static bool IsWindowPresented(
        IntPtr hWnd,
        int minimumVisibleWidth,
        int minimumVisibleHeight)
    {
        if (hWnd == IntPtr.Zero || !IsWindowVisible(hWnd))
        {
            return false;
        }

        NativeRect window;
        if (!GetWindowRect(hWnd, out window))
        {
            return false;
        }

        foreach (NativeRect workArea in GetPhysicalWorkAreas())
        {
            int visibleWidth = Math.Max(
                0,
                Math.Min(window.Right, workArea.Right) -
                Math.Max(window.Left, workArea.Left));
            int visibleHeight = Math.Max(
                0,
                Math.Min(window.Bottom, workArea.Bottom) -
                Math.Max(window.Top, workArea.Top));
            if (visibleWidth >= minimumVisibleWidth &&
                visibleHeight >= minimumVisibleHeight)
            {
                return true;
            }
        }
        return false;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(
        string pszPath,
        uint dwFileAttributes,
        out SHFILEINFO psfi,
        uint cbFileInfo,
        uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(
        string szFileName,
        int nIconIndex,
        IntPtr[] phiconLarge,
        IntPtr[] phiconSmall,
        uint nIcons);

    private static ImageSource CreateImageSource(IntPtr icon)
    {
        if (icon == IntPtr.Zero)
        {
            return null;
        }
        BitmapSource source = Imaging.CreateBitmapSourceFromHIcon(
            icon,
            Int32Rect.Empty,
            BitmapSizeOptions.FromWidthAndHeight(48, 48));
        source.Freeze();
        return source;
    }

    public static ImageSource GetIconResource(string path, int resourceIndex)
    {
        IntPtr[] largeIcons = new IntPtr[1];
        IntPtr[] smallIcons = new IntPtr[1];
        uint count = ExtractIconEx(
            path,
            resourceIndex,
            largeIcons,
            smallIcons,
            1);
        if (count == 0)
        {
            return null;
        }

        IntPtr selected = largeIcons[0] != IntPtr.Zero
            ? largeIcons[0]
            : smallIcons[0];
        try
        {
            return CreateImageSource(selected);
        }
        finally
        {
            if (largeIcons[0] != IntPtr.Zero)
            {
                DestroyIcon(largeIcons[0]);
            }
            if (
                smallIcons[0] != IntPtr.Zero &&
                smallIcons[0] != largeIcons[0]
            )
            {
                DestroyIcon(smallIcons[0]);
            }
        }
    }

    public static ImageSource GetShellIcon(string path, bool isDirectory)
    {
        SHFILEINFO info;
        uint attributes = isDirectory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        uint flags = SHGFI_ICON | SHGFI_LARGEICON;
        if (!System.IO.File.Exists(path) && !System.IO.Directory.Exists(path))
        {
            flags |= SHGFI_USEFILEATTRIBUTES;
        }

        IntPtr result = SHGetFileInfo(
            path,
            attributes,
            out info,
            (uint)Marshal.SizeOf(typeof(SHFILEINFO)),
            flags);

        if (result == IntPtr.Zero || info.hIcon == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return CreateImageSource(info.hIcon);
        }
        finally
        {
            DestroyIcon(info.hIcon);
        }
    }
}
'@

if (-not ('WorkspaceWidgetNative' -as [type])) {
  Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @(
    'PresentationCore',
    'PresentationFramework',
    'WindowsBase'
  )
}

$mutex = $null
$showEvent = $null
$readyEvent = $null
$presentedEvent = $null
$script:readySignalSent = $false
if (
  -not $StartupProbe -and
  -not $StartupTargetProbe -and
  -not $IconResolutionProbe -and
  [string]::IsNullOrWhiteSpace($RemoteAssetProbeSource) -and
  -not $NetworkBoundaryProbe
) {
  $showEvent = [System.Threading.EventWaitHandle]::new(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    $instanceNames.show
  )
  $readyEvent = [System.Threading.EventWaitHandle]::new(
    $false,
    [System.Threading.EventResetMode]::ManualReset,
    $instanceNames.ready
  )
  $presentedEvent = [System.Threading.EventWaitHandle]::new(
    $false,
    [System.Threading.EventResetMode]::ManualReset,
    $instanceNames.presented
  )

  $createdNew = $false
  $mutex = [System.Threading.Mutex]::new(
    $true,
    $instanceNames.mutex,
    [ref]$createdNew
  )
  if (-not $createdNew) {
    $requestMutex = [System.Threading.Mutex]::new(
      $false,
      $instanceNames.requestMutex
    )
    $requestMutexOwned = $false
    try {
      try {
        $requestMutexOwned = $requestMutex.WaitOne([TimeSpan]::FromSeconds(5))
      } catch [System.Threading.AbandonedMutexException] {
        $requestMutexOwned = $true
      }
      if (-not $requestMutexOwned) {
        throw 'Another Workspace presentation request did not finish in time.'
      }

      $presentedEvent.Reset() | Out-Null
      $showEvent.Set() | Out-Null
      if (-not $presentedEvent.WaitOne([TimeSpan]::FromSeconds(5))) {
        throw 'The running Workspace Widget did not confirm that its window was presented.'
      }
    } catch {
      Write-RuntimeLog "Existing-instance show signal failed. $($_.Exception.Message)"
      throw
    } finally {
      if ($requestMutexOwned) {
        $requestMutex.ReleaseMutex()
      }
      $requestMutex.Dispose()
      $showEvent.Dispose()
      $readyEvent.Dispose()
      $presentedEvent.Dispose()
      $mutex.Dispose()
    }
    exit 0
  }
  $readyEvent.Reset() | Out-Null
  $presentedEvent.Reset() | Out-Null
}

function Show-StartupSplash {
  param([string]$LogoPath)

  if (-not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
    return
  }

  $script:splashWindow = [System.Windows.Window]::new()
  $script:splashWindow.Title = 'Workspace'
  $script:splashWindow.Width = 268
  $script:splashWindow.Height = 210
  $script:splashWindow.WindowStyle = [System.Windows.WindowStyle]::None
  $script:splashWindow.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $script:splashWindow.AllowsTransparency = $true
  $script:splashWindow.Background = [System.Windows.Media.Brushes]::Transparent
  $script:splashWindow.ShowInTaskbar = $false
  $script:splashWindow.Topmost = $true
  $script:splashWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
  $script:splashWindow.Opacity = 0

  $brushConverter = [System.Windows.Media.BrushConverter]::new()
  $outer = [System.Windows.Controls.Border]::new()
  $outer.CornerRadius = [System.Windows.CornerRadius]::new(22)
  $outer.Background = $brushConverter.ConvertFromString('#F309162B')
  $outer.BorderBrush = $brushConverter.ConvertFromString('#A65C8AC6')
  $outer.BorderThickness = [System.Windows.Thickness]::new(1)
  $outer.Padding = [System.Windows.Thickness]::new(24, 20, 24, 18)
  $script:splashWindow.Content = $outer

  $stack = [System.Windows.Controls.StackPanel]::new()
  $stack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $outer.Child = $stack

  $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
  $bitmap.BeginInit()
  $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bitmap.UriSource = [uri]$LogoPath
  $bitmap.EndInit()
  $bitmap.Freeze()

  $image = [System.Windows.Controls.Image]::new()
  $image.Source = $bitmap
  $image.Width = 104
  $image.Height = 104
  $image.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
  $stack.Children.Add($image) | Out-Null

  $title = [System.Windows.Controls.TextBlock]::new()
  $title.Text = 'Workspace'
  $title.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI')
  $title.FontSize = 18
  $title.FontWeight = [System.Windows.FontWeights]::SemiBold
  $title.Foreground = $brushConverter.ConvertFromString('#FFF6F9FF')
  $title.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $stack.Children.Add($title) | Out-Null
  $subtitle = [System.Windows.Controls.TextBlock]::new()
  $subtitle.Text = 'Starting your workspace'
  $subtitle.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI')
  $subtitle.FontSize = 10
  $subtitle.Foreground = $brushConverter.ConvertFromString('#FFA9B9D1')
  $subtitle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $subtitle.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
  $stack.Children.Add($subtitle) | Out-Null

  $script:splashHoldTimer = [System.Windows.Threading.DispatcherTimer]::new()
  $script:splashHoldTimer.Interval = [TimeSpan]::FromMilliseconds(520)
  $script:splashHoldTimer.Add_Tick({
      $script:splashHoldTimer.Stop()
      $fadeOut = [System.Windows.Media.Animation.DoubleAnimation]::new(
        1.0,
        0.0,
        [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(320))
      )
      $fadeOut.EasingFunction = [System.Windows.Media.Animation.CubicEase]::new()
      $fadeOut.Add_Completed({ $script:splashWindow.Close() })
      $script:splashWindow.BeginAnimation(
        [System.Windows.Window]::OpacityProperty,
        $fadeOut
      )
    })

  $script:splashWindow.Add_ContentRendered({
      $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(
        0.0,
        1.0,
        [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(360))
      )
      $fadeIn.EasingFunction = [System.Windows.Media.Animation.CubicEase]::new()
      $fadeIn.Add_Completed({ $script:splashHoldTimer.Start() })
      $script:splashWindow.BeginAnimation(
        [System.Windows.Window]::OpacityProperty,
        $fadeIn
      )
    })
  $script:splashWindow.ShowDialog() | Out-Null
}

if (
  -not $StartupProbe -and
  -not $StartupTargetProbe -and
  -not $StateLifecycleProbe -and
  -not $IconResolutionProbe -and
  [string]::IsNullOrWhiteSpace($CapturePath)
) {
  Show-StartupSplash -LogoPath (Join-Path $ProjectRoot 'assets\workspace-widget-logo.png')
}

function Read-State {
  try {
    $stateSelection = Get-ValidatedStateDocument -CandidatePaths @(
      $StatePath,
      "$StatePath.previous",
      $defaultStatePath
    )
    $loaded = $stateSelection.state
    $selectedPath = [string]$stateSelection.sourcePath
    if (
      -not [string]::Equals(
        $selectedPath,
        $StatePath,
        [System.StringComparison]::OrdinalIgnoreCase
      ) -and
      (Test-Path -LiteralPath $StatePath -PathType Leaf)
    ) {
      Write-RuntimeLog "Recovered widget state from '$selectedPath'."
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'alwaysOnTop') {
      $loaded.window | Add-Member -NotePropertyName alwaysOnTop -NotePropertyValue $false
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'minUiMode') {
      $loaded.window | Add-Member -NotePropertyName minUiMode -NotePropertyValue $false
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'minUiLeft') {
      $loaded.window | Add-Member -NotePropertyName minUiLeft -NotePropertyValue (
        [double]$loaded.window.left
      )
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'minUiTop') {
      $loaded.window | Add-Member -NotePropertyName minUiTop -NotePropertyValue (
        [double]$loaded.window.top
      )
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'minUiHeight') {
      $loaded.window | Add-Member -NotePropertyName minUiHeight -NotePropertyValue (
        [double]$loaded.window.height
      )
    }
    if ($loaded.window.PSObject.Properties.Name -notcontains 'minUiOpacity') {
      $loaded.window | Add-Member -NotePropertyName minUiOpacity -NotePropertyValue 0.35
    }
    Initialize-AppearanceState -WindowState $loaded.window
    foreach ($item in @($loaded.items)) {
      Initialize-ItemLaunchMetadata -Item $item

      if ([System.IO.Path]::GetExtension([string]$item.target) -ieq '.lnk') {
        $registration = Resolve-ShortcutRegistration -Path ([string]$item.target)
        if ($registration.success -and $registration.shortcutResolved) {
          $item.target = [string]$registration.target
          $item.launchArguments = [string]$registration.launchArguments
          $item.workingDirectory = [string]$registration.workingDirectory
          $item.iconLocation = [string]$registration.iconLocation
          $item.sourceShortcut = [string]$registration.sourceShortcut
          $item.launchWindowStyle = [int]$registration.launchWindowStyle
          Write-RuntimeLog "Migrated registered LNK '$($registration.sourceShortcut)' to its launch target."
        }
      }
      $item.subtitle = Get-Subtitle -Target ([string]$item.target)
    }
    $loaded.schemaVersion = 4
    return $loaded
  } catch [System.NotSupportedException] {
    Write-RuntimeLog "State read stopped to preserve a newer schema. $($_.Exception.Message)"
    throw
  } catch {
    Write-RuntimeLog "State read failed; using defaults. $($_.Exception.Message)"
    $fallback = Get-Content -LiteralPath $defaultStatePath -Raw | ConvertFrom-Json
    Initialize-AppearanceState -WindowState $fallback.window
    foreach ($item in @($fallback.items)) {
      Initialize-ItemLaunchMetadata -Item $item
      $item.subtitle = Get-Subtitle -Target ([string]$item.target)
    }
    $fallback.schemaVersion = 4
    return $fallback
  }
}

function Save-State {
  try {
    if (-not (Test-Path -LiteralPath $runtimeRoot)) {
      New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    }

    $script:state.window.minUiMode = [bool]$script:minUiMode
    if ($script:minUiMode) {
      $script:state.window.minUiLeft = [math]::Round($script:window.Left, 1)
      $script:state.window.minUiTop = [math]::Round($script:window.Top, 1)
      $script:state.window.minUiHeight = [math]::Round($script:window.Height, 1)
      $script:state.window.minUiOpacity = [math]::Round([double]$script:baseOpacity, 2)
    } else {
      $script:state.window.left = [math]::Round($script:window.Left, 1)
      $script:state.window.top = [math]::Round($script:window.Top, 1)
      $script:state.window.width = [math]::Round($script:window.Width, 1)
      $script:state.window.height = [math]::Round($script:window.Height, 1)
      $script:state.window.opacity = [math]::Round([double]$script:baseOpacity, 2)
    }
    $script:state.window.hoverBrightness = [bool]$script:hoverBrightness
    $script:state.window.alwaysOnTop = [bool]$script:alwaysOnTop
    $script:state.window.attachToDesktop = [bool]$script:attachToDesktopPreference

    if (@($script:state.items).Count -gt $script:maximumShortcutCount) {
      throw "State contains more than $($script:maximumShortcutCount) shortcuts."
    }
    $json = $script:state | ConvertTo-Json -Depth 10
    $jsonBytes = [System.Text.UTF8Encoding]::new($true).GetByteCount($json)
    if ($jsonBytes -gt $script:maximumStateBytes) {
      throw "State document exceeds the $($script:maximumStateBytes)-byte limit."
    }
    $temporaryStatePath = '{0}.write-{1}-{2}.tmp' -f (
      $StatePath,
      $PID,
      [guid]::NewGuid().ToString('N')
    )
    [System.IO.File]::WriteAllText(
      $temporaryStatePath,
      $json,
      [System.Text.UTF8Encoding]::new($true)
    )
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
      [System.IO.File]::Replace(
        $temporaryStatePath,
        $StatePath,
        "$StatePath.previous",
        $true
      )
    } else {
      [System.IO.File]::Move($temporaryStatePath, $StatePath)
    }
    return $true
  } catch {
    Write-RuntimeLog "State save failed. $($_.Exception.Message)"
    return $false
  }
}

function Convert-ToBrush {
  param([string]$Color)
  return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function New-ButtonTemplate {
  param(
    [string]$HoverBackground = '#FF174A78',
    [string]$PressedBackground = '#FF0F5FAF',
    [string]$HoverBorder = '#FF74AEFF'
  )

  return [System.Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  TargetType="{x:Type Button}">
  <Border
    x:Name="Root"
    CornerRadius="5"
    Background="{TemplateBinding Background}"
    BorderBrush="{TemplateBinding BorderBrush}"
    BorderThickness="{TemplateBinding BorderThickness}"
    Padding="{TemplateBinding Padding}"
    SnapsToDevicePixels="True">
    <ContentPresenter
      x:Name="ContentHost"
      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
      RecognizesAccessKey="True"
      TextElement.Foreground="{TemplateBinding Foreground}" />
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="Root" Property="Background" Value="$HoverBackground" />
      <Setter TargetName="Root" Property="BorderBrush" Value="$HoverBorder" />
      <Setter TargetName="ContentHost" Property="TextElement.Foreground" Value="#FFFFFFFF" />
      <Setter Property="Foreground" Value="#FFFFFFFF" />
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="Root" Property="Background" Value="$PressedBackground" />
      <Setter TargetName="Root" Property="BorderBrush" Value="#FFD9E9FF" />
      <Setter TargetName="ContentHost" Property="TextElement.Foreground" Value="#FFFFFFFF" />
      <Setter Property="Foreground" Value="#FFFFFFFF" />
    </Trigger>
    <Trigger Property="IsKeyboardFocused" Value="True">
      <Setter TargetName="Root" Property="BorderBrush" Value="#FFD9E9FF" />
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter TargetName="Root" Property="Opacity" Value="0.45" />
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@)
}

function New-TextBlock {
  param(
    [string]$Text,
    [double]$Size = 12,
    [string]$Color = '#FFF6F9FF',
    [string]$Weight = 'Normal'
  )

  $textBlock = [System.Windows.Controls.TextBlock]::new()
  $textBlock.Text = $Text
  $textBlock.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI')
  $textBlock.FontSize = $Size
  $textBlock.Foreground = Convert-ToBrush $Color
  $textBlock.FontWeight = [System.Windows.FontWeights]::$Weight
  $textBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  return $textBlock
}

function New-FluentText {
  param(
    [string]$Glyph,
    [double]$Size = 18,
    [string]$Color = '#FFF6F9FF'
  )

  $icon = New-TextBlock -Text $Glyph -Size $Size -Color $Color
  $icon.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons')
  $icon.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  return $icon
}

function New-ToolbarButton {
  param(
    [string]$Glyph,
    [string]$Label,
    [string]$AutomationName
  )

  $button = [System.Windows.Controls.Button]::new()
  $button.Name = "Button$($AutomationName -replace '[^A-Za-z0-9_]', '')"
  $button.Background = [System.Windows.Media.Brushes]::Transparent
  $button.BorderBrush = [System.Windows.Media.Brushes]::Transparent
  $button.BorderThickness = [System.Windows.Thickness]::new(1)
  $button.Foreground = Convert-ToBrush '#FFF6F9FF'
  $button.Focusable = $true
  $button.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
  $button.Margin = [System.Windows.Thickness]::new(2, 0, 0, 0)
  $button.Cursor = [System.Windows.Input.Cursors]::Hand
  $button.ToolTip = $AutomationName
  [System.Windows.Automation.AutomationProperties]::SetName($button, $AutomationName)
  $button.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  TargetType="{x:Type Button}">
  <Border
    x:Name="Root"
    CornerRadius="7"
    Background="{TemplateBinding Background}"
    BorderBrush="{TemplateBinding BorderBrush}"
    BorderThickness="{TemplateBinding BorderThickness}"
    Padding="{TemplateBinding Padding}">
    <ContentPresenter
      HorizontalAlignment="Center"
      VerticalAlignment="Center" />
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsKeyboardFocused" Value="True">
      <Setter TargetName="Root" Property="Background" Value="#FF173A63" />
      <Setter TargetName="Root" Property="BorderBrush" Value="#FFD9E9FF" />
      <Setter TargetName="Root" Property="BorderThickness" Value="2" />
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="Root" Property="Background" Value="#FF0F355E" />
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter TargetName="Root" Property="Opacity" Value="0.45" />
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@)

  $panel = [System.Windows.Controls.StackPanel]::new()
  $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $icon = New-FluentText -Glyph $Glyph -Size 15
  $labelElement = $null
  $icon.Margin = if ([string]::IsNullOrWhiteSpace($Label)) {
    [System.Windows.Thickness]::new(0)
  } else {
    [System.Windows.Thickness]::new(0, 0, 6, 0)
  }
  $panel.Children.Add($icon) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($Label)) {
    $labelElement = New-TextBlock -Text $Label -Size 11 -Color '#FFC6D2E5'
    $panel.Children.Add($labelElement) | Out-Null
  } else {
    $button.Padding = [System.Windows.Thickness]::new(7, 6, 7, 6)
  }
  $button.Content = $panel
  $button.Tag = [pscustomobject]@{
    icon = $icon
    label = $labelElement
  }

  $button.Add_MouseEnter({
      param($sender, $eventArgs)
      $sender.Background = Convert-ToBrush '#242F5D96'
    })
  $button.Add_MouseLeave({
      param($sender, $eventArgs)
      $sender.Background = [System.Windows.Media.Brushes]::Transparent
    })
  return $button
}

function Get-FriendlyName {
  param([string]$Target)

  if ($Target -match '^https?://') {
    try {
      $hostName = ([uri]$Target).Host
      return ($hostName -replace '^www\.', '')
    } catch {
      return 'Web shortcut'
    }
  }

  $trimmed = $Target.TrimEnd('\')
  $name = [System.IO.Path]::GetFileNameWithoutExtension($trimmed)
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = Split-Path -Leaf $trimmed
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    return 'Shortcut'
  }
  return $name
}

function Get-Subtitle {
  param([string]$Target)

  if ($Target -match '^https?://') {
    try {
      $uri = [uri]$Target
      if (-not $uri.IsDefaultPort) {
        return "Port $($uri.Port)"
      }
      return $uri.Host
    } catch {
      return 'Web'
    }
  }

  if (Test-Path -LiteralPath $Target -PathType Container) {
    return 'Folder'
  }
  $extension = [System.IO.Path]::GetExtension($Target)
  if ([string]::IsNullOrWhiteSpace($extension)) {
    return 'Local item'
  }
  return $extension.TrimStart('.').ToUpperInvariant()
}

function Get-DropTargets {
  param([System.Windows.IDataObject]$Data)

  $targets = [System.Collections.Generic.List[string]]::new()
  if ($Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
    foreach ($path in [string[]]$Data.GetData([System.Windows.DataFormats]::FileDrop)) {
      if (-not [string]::IsNullOrWhiteSpace($path)) {
        $targets.Add($path)
      }
    }
  } elseif ($Data.GetDataPresent([System.Windows.DataFormats]::UnicodeText)) {
    $text = [string]$Data.GetData([System.Windows.DataFormats]::UnicodeText)
    foreach ($candidate in ($text -split "(`r`n|`n|`r)")) {
      $trimmed = $candidate.Trim()
      if ($trimmed -match '^https?://' -or (Test-Path -LiteralPath $trimmed)) {
        $targets.Add($trimmed)
      }
    }
  } elseif ($Data.GetDataPresent([System.Windows.DataFormats]::Text)) {
    $text = [string]$Data.GetData([System.Windows.DataFormats]::Text)
    if ($text.Trim() -match '^https?://') {
      $targets.Add($text.Trim())
    }
  }
  return $targets
}

function New-ItemId {
  return ([guid]::NewGuid().ToString('N'))
}

function Show-Toast {
  param([string]$Message)

  $script:toastText.Text = $Message
  $script:toastBorder.Visibility = [System.Windows.Visibility]::Visible
  $script:toastTimer.Stop()
  $script:toastTimer.Start()
}

function Add-Targets {
  param([object[]]$Targets)

  $originalItems = @($script:state.items)
  $added = 0
  $duplicates = 0
  $failed = 0
  foreach ($originalTarget in $Targets) {
    $registration = Resolve-ShortcutRegistration -Path ([string]$originalTarget)
    if (-not $registration.success) {
      $failed++
      Write-RuntimeLog "Add target could not resolve '$originalTarget'."
      continue
    }

    $target = [string]$registration.target
    $launchArguments = [string]$registration.launchArguments
    $workingDirectory = [string]$registration.workingDirectory
    $iconLocation = [string]$registration.iconLocation
    $launchWindowStyle = [int]$registration.launchWindowStyle
    Write-RuntimeLog (
      "Add target original='$originalTarget' resolved='$target' kind=$($registration.kind)"
    )
    $existing = @($script:state.items | Where-Object {
        $existingArguments = if ($_.PSObject.Properties.Name -contains 'launchArguments') {
          [string]$_.launchArguments
        } else {
          ''
        }
        $existingWorkingDirectory = if (
          $_.PSObject.Properties.Name -contains 'workingDirectory'
        ) {
          Get-NormalizedWorkingDirectory -Path ([string]$_.workingDirectory)
        } else {
          ''
        }
        $existingIconLocation = if (
          $_.PSObject.Properties.Name -contains 'iconLocation'
        ) {
          [string]$_.iconLocation
        } else {
          ''
        }
        $existingWindowStyle = if (
          $_.PSObject.Properties.Name -contains 'launchWindowStyle'
        ) {
          [int]$_.launchWindowStyle
        } else {
          1
        }
        [string]::Equals(
          [string]$_.target,
          $target,
          [System.StringComparison]::OrdinalIgnoreCase
        ) -and [string]::Equals(
          $existingArguments,
          $launchArguments,
          [System.StringComparison]::Ordinal
        ) -and [string]::Equals(
          $existingWorkingDirectory,
          (Get-NormalizedWorkingDirectory -Path $workingDirectory),
          [System.StringComparison]::OrdinalIgnoreCase
        ) -and [string]::Equals(
          $existingIconLocation,
          $iconLocation,
          [System.StringComparison]::OrdinalIgnoreCase
        ) -and (
          $existingWindowStyle -eq $launchWindowStyle
        )
      })
    Write-RuntimeLog "Add target existing=$($existing.Count)"
    if ($existing.Count -gt 0) {
      $duplicates++
      continue
    }

    $item = [pscustomobject][ordered]@{
      id = New-ItemId
      name = Get-FriendlyName -Target $originalTarget
      target = $target
      subtitle = Get-Subtitle -Target $target
      health = ''
      startupTarget = ''
      startupArgs = ''
      launchArguments = $launchArguments
      workingDirectory = [string]$registration.workingDirectory
      iconLocation = $iconLocation
      sourceShortcut = [string]$registration.sourceShortcut
      launchWindowStyle = $launchWindowStyle
      customIcon = ''
      customIconCache = ''
      iconPreset = ''
      hoverMedia = ''
      hoverMediaKind = 'auto'
      hoverMediaMuted = $true
      glyph = if ($target -match '^https?://') { '' } else { '' }
      hidden = $false
    }
    $script:state.items += $item
    $added++
    Write-RuntimeLog "Add target staged name='$($item.name)' total=$(@($script:state.items).Count)"
  }

  if ($added -gt 0) {
    if (-not (Save-State)) {
      $script:state.items = $originalItems
      Render-Items
      Show-Toast -Message 'Could not save shortcuts; no registrations were changed'
      return
    }
    Render-Items
    $message = "$added shortcut(s) added"
    if ($failed -gt 0) {
      $message += " · $failed could not be resolved"
    }
    Show-Toast -Message $message
  } elseif ($failed -gt 0) {
    Show-Toast -Message "$failed shortcut(s) could not be resolved"
  } elseif ($duplicates -gt 0) {
    Show-Toast -Message 'Already in Workspace'
  }
}

function Move-Item {
  param(
    [string]$ItemId,
    [int]$Direction
  )

  $items = [System.Collections.ArrayList]::new()
  foreach ($entry in @($script:state.items)) {
    $items.Add($entry) | Out-Null
  }
  $currentIndex = -1
  for ($index = 0; $index -lt $items.Count; $index++) {
    if ($items[$index].id -eq $ItemId) {
      $currentIndex = $index
      break
    }
  }
  $newIndex = $currentIndex + $Direction
  if ($currentIndex -lt 0 -or $newIndex -lt 0 -or $newIndex -ge $items.Count) {
    return
  }
  $moving = $items[$currentIndex]
  $items.RemoveAt($currentIndex)
  $items.Insert($newIndex, $moving)
  $script:state.items = @($items)
  Save-State
  Render-Items
}

function Remove-ItemRegistration {
  param($Item)

  if ($null -eq $Item) {
    return
  }

  $itemName = [string]$Item.name
  $result = [System.Windows.MessageBox]::Show(
    $script:window,
    "Remove '$itemName' from Workspace?`n`nThe original file, application, folder, or URL will not be deleted.",
    'Remove shortcut',
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Warning,
    [System.Windows.MessageBoxResult]::No
  )
  if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
    return
  }

  $itemId = [string]$Item.id
  $previousCount = @($script:state.items).Count
  $script:state.items = @(
    $script:state.items | Where-Object { [string]$_.id -ne $itemId }
  )
  if (@($script:state.items).Count -eq $previousCount) {
    return
  }

  [void]$script:healthStates.Remove($itemId)
  [void]$script:pendingOpen.Remove($itemId)
  Save-State
  Render-Items
  Show-Toast -Message "'$itemName' removed from Workspace"
}

function Show-ItemDialog {
  param(
    $ExistingItem = $null
  )

  $dialog = [System.Windows.Window]::new()
  $dialog.Title = if ($null -eq $ExistingItem) { 'Add shortcut' } else { 'Edit shortcut' }
  $dialog.Owner = $script:window
  $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
  $dialog.WindowStyle = [System.Windows.WindowStyle]::None
  $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $dialog.Width = 430
  $dialog.Height = 330
  $dialog.MaxHeight = [math]::Max(
    420,
    [System.Windows.SystemParameters]::WorkArea.Height - 48
  )
  $dialog.AllowsTransparency = $true
  $dialog.Background = [System.Windows.Media.Brushes]::Transparent
  $dialog.ShowInTaskbar = $false
  $dialog.SizeToContent = [System.Windows.SizeToContent]::Height

  $outer = [System.Windows.Controls.Border]::new()
  $outer.CornerRadius = [System.Windows.CornerRadius]::new(16)
  $outer.Background = Convert-ToBrush '#FF09162B'
  $outer.BorderBrush = Convert-ToBrush '#945C8AC6'
  $outer.BorderThickness = [System.Windows.Thickness]::new(1)
  $outer.Padding = [System.Windows.Thickness]::new(22)
  $dialog.Content = $outer

  $dialogScroll = [System.Windows.Controls.ScrollViewer]::new()
  $dialogScroll.VerticalScrollBarVisibility = (
    [System.Windows.Controls.ScrollBarVisibility]::Auto
  )
  $dialogScroll.HorizontalScrollBarVisibility = (
    [System.Windows.Controls.ScrollBarVisibility]::Disabled
  )
  $dialogScroll.PanningMode = [System.Windows.Controls.PanningMode]::VerticalOnly
  $outer.Child = $dialogScroll
  $stack = [System.Windows.Controls.StackPanel]::new()
  $dialogScroll.Content = $stack
  $title = New-TextBlock -Text $dialog.Title -Size 20 -Weight 'SemiBold'
  $title.Margin = [System.Windows.Thickness]::new(0, 0, 0, 18)
  $stack.Children.Add($title) | Out-Null

  function Add-DialogField {
    param([string]$Label, [string]$Value, [string]$Help)
    $labelBlock = New-TextBlock -Text $Label -Size 11 -Color '#FFA9B9D1'
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
    $stack.Children.Add($labelBlock) | Out-Null
    $box = [System.Windows.Controls.TextBox]::new()
    $box.Text = $Value
    $box.Height = 34
    $box.Padding = [System.Windows.Thickness]::new(9, 6, 9, 6)
    $box.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $box.Background = Convert-ToBrush '#FF0F203B'
    $box.Foreground = Convert-ToBrush '#FFF6F9FF'
    $box.BorderBrush = Convert-ToBrush '#665C8AC6'
    $box.ToolTip = $Help
    [System.Windows.Automation.AutomationProperties]::SetName($box, $Label)
    [System.Windows.Automation.AutomationProperties]::SetHelpText($box, $Help)
    [System.Windows.Automation.AutomationProperties]::SetLabeledBy(
      $box,
      $labelBlock
    )
    $stack.Children.Add($box) | Out-Null
    return $box
  }

  $nameBox = Add-DialogField -Label 'Name' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.name }) -Help 'The label shown on the card.'
  $targetBox = Add-DialogField -Label 'URL or local path' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.target }) -Help 'http, https, application, file, folder, or shortcut.'
  $healthBox = Add-DialogField -Label 'Health URL (optional)' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.health }) -Help 'A URL that returns HTTP 2xx or 3xx when healthy.'
  $startupTargetBox = Add-DialogField -Label 'Node start target (optional)' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.startupTarget }) -Help 'A .js/.mjs/.cjs entry file, or a project folder containing package.json.'
  $startupArgsBox = Add-DialogField -Label 'Start script / arguments (optional)' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.startupArgs }) -Help 'For a folder, enter the package script name. For a JS entry file, enter its arguments.'
  $semanticIconLabel = New-TextBlock `
    -Text 'Built-in icon (optional)' `
    -Size 11 `
    -Color '#FFA9B9D1'
  $semanticIconLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $stack.Children.Add($semanticIconLabel) | Out-Null
  $semanticIconBox = [System.Windows.Controls.ComboBox]::new()
  $semanticIconBox.Height = 42
  $semanticIconBox.Padding = [System.Windows.Thickness]::new(7, 4, 7, 4)
  $semanticIconBox.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
  $semanticIconBox.Background = Convert-ToBrush '#FF0F203B'
  $semanticIconBox.Foreground = Convert-ToBrush '#FFF6F9FF'
  $semanticIconBox.BorderBrush = Convert-ToBrush '#665C8AC6'
  $semanticIconBox.MaxDropDownHeight = 294
  $semanticIconBox.ToolTip = 'Choose an original Workspace Widget semantic icon, or keep automatic target icon resolution.'
  [System.Windows.Automation.AutomationProperties]::SetName(
    $semanticIconBox,
    'Built-in icon'
  )
  [System.Windows.Automation.AutomationProperties]::SetHelpText(
    $semanticIconBox,
    'Custom icons take priority. Automatic uses the Windows target icon or the existing fallback glyph.'
  )
  [System.Windows.Automation.AutomationProperties]::SetLabeledBy(
    $semanticIconBox,
    $semanticIconLabel
  )

  function New-SemanticIconComboItem {
    param(
      [string]$Id,
      [string]$Name,
      [string]$Description,
      [string]$PngPath
    )

    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Tag = $Id
    $item.Padding = [System.Windows.Thickness]::new(5)
    $item.Foreground = Convert-ToBrush '#FFF6F9FF'
    $item.ToolTip = $Description
    $row = [System.Windows.Controls.StackPanel]::new()
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    if (-not [string]::IsNullOrWhiteSpace($PngPath)) {
      $image = [System.Windows.Controls.Image]::new()
      $image.Source = New-MediaBitmap -Source $PngPath -Kind 'image'
      $image.Width = 24
      $image.Height = 24
      $image.Stretch = [System.Windows.Media.Stretch]::Uniform
      $image.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
      [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
        $image,
        [System.Windows.Media.BitmapScalingMode]::HighQuality
      )
      $row.Children.Add($image) | Out-Null
    }
    $text = New-TextBlock -Text $Name -Size 11 -Color '#FFF6F9FF'
    $text.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $row.Children.Add($text) | Out-Null
    $item.Content = $row
    [System.Windows.Automation.AutomationProperties]::SetName(
      $item,
      $(if ([string]::IsNullOrWhiteSpace($Id)) { 'Automatic icon' } else { "$Name icon" })
    )
    [System.Windows.Automation.AutomationProperties]::SetHelpText($item, $Description)
    return $item
  }

  $automaticIconItem = New-SemanticIconComboItem `
    -Id '' `
    -Name 'Automatic' `
    -Description 'Use a verified custom icon, Windows target icon, or the existing fallback glyph.' `
    -PngPath ''
  $semanticIconBox.Items.Add($automaticIconItem) | Out-Null
  foreach ($definition in @(Get-WorkspaceSemanticIconDefinitions)) {
    $semanticIconBox.Items.Add((New-SemanticIconComboItem `
          -Id ([string]$definition.id) `
          -Name ([string]$definition.name) `
          -Description ([string]$definition.description) `
          -PngPath ([string]$definition.pngPath)
      )) | Out-Null
  }
  $existingIconPreset = if (
    $null -ne $ExistingItem -and
    $ExistingItem.PSObject.Properties.Name -contains 'iconPreset'
  ) {
    ([string]$ExistingItem.iconPreset).Trim().ToLowerInvariant()
  } else {
    ''
  }
  $semanticIconBox.SelectedIndex = 0
  for ($index = 0; $index -lt $semanticIconBox.Items.Count; $index++) {
    if ([string]::Equals(
        [string]$semanticIconBox.Items[$index].Tag,
        $existingIconPreset,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      $semanticIconBox.SelectedIndex = $index
      break
    }
  }
  $stack.Children.Add($semanticIconBox) | Out-Null

  $customIconBox = Add-DialogField -Label 'Custom icon image (optional)' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.customIcon }) -Help 'A verified custom icon takes priority over the built-in selection. Use a local image, clipboard image, or public HTTPS PNG, JPG, GIF, ICO, BMP, or static SVG URL.'
  $customIconPreviewRow = [System.Windows.Controls.Grid]::new()
  $customIconPreviewRow.Margin = [System.Windows.Thickness]::new(0, -2, 0, 12)
  $customIconPreviewRow.ColumnDefinitions.Add(
    [System.Windows.Controls.ColumnDefinition]::new()
  ) | Out-Null
  $customIconPreviewInfoColumn = [System.Windows.Controls.ColumnDefinition]::new()
  $customIconPreviewInfoColumn.Width = [System.Windows.GridLength]::new(
    1,
    [System.Windows.GridUnitType]::Star
  )
  $customIconPreviewRow.ColumnDefinitions.Add(
    $customIconPreviewInfoColumn
  ) | Out-Null
  $customIconPreviewBorder = [System.Windows.Controls.Border]::new()
  $customIconPreviewBorder.Width = 72
  $customIconPreviewBorder.Height = 72
  $customIconPreviewBorder.CornerRadius = [System.Windows.CornerRadius]::new(12)
  $customIconPreviewBorder.Background = Convert-ToBrush '#FF0F203B'
  $customIconPreviewBorder.BorderBrush = Convert-ToBrush '#665C8AC6'
  $customIconPreviewBorder.BorderThickness = [System.Windows.Thickness]::new(1)
  $customIconPreviewBorder.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
  $customIconPreviewHost = [System.Windows.Controls.Grid]::new()
  $customIconPreviewBorder.Child = $customIconPreviewHost
  $customIconPreviewImage = [System.Windows.Controls.Image]::new()
  $customIconPreviewImage.Width = 54
  $customIconPreviewImage.Height = 54
  $customIconPreviewImage.Stretch = [System.Windows.Media.Stretch]::Uniform
  $customIconPreviewImage.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $customIconPreviewImage.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $customIconPreviewHost.Children.Add($customIconPreviewImage) | Out-Null
  [System.Windows.Controls.Grid]::SetColumn($customIconPreviewBorder, 0)
  $customIconPreviewRow.Children.Add($customIconPreviewBorder) | Out-Null
  $customIconPreviewInfo = [System.Windows.Controls.StackPanel]::new()
  [System.Windows.Controls.Grid]::SetColumn($customIconPreviewInfo, 1)
  $customIconPreviewRow.Children.Add($customIconPreviewInfo) | Out-Null
  $customIconPreviewStatus = New-TextBlock `
    -Text 'Local, clipboard, and HTTPS icons can be previewed here.' `
    -Size 10 `
    -Color '#FF7D91AE'
  $customIconPreviewStatus.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $customIconPreviewStatus.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
  [System.Windows.Automation.AutomationProperties]::SetLiveSetting(
    $customIconPreviewStatus,
    [System.Windows.Automation.AutomationLiveSetting]::Polite
  )
  $customIconPreviewInfo.Children.Add($customIconPreviewStatus) | Out-Null
  $customIconConfirm = [System.Windows.Controls.CheckBox]::new()
  $customIconConfirmText = New-TextBlock `
    -Text 'I confirm this preview is the icon I want.' `
    -Size 10 `
    -Color '#FFC6D2E5'
  $customIconConfirmText.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $customIconConfirmText.MaxWidth = 210
  $customIconConfirm.Content = $customIconConfirmText
  [System.Windows.Automation.AutomationProperties]::SetName(
    $customIconConfirm,
    'I confirm this preview is the icon I want.'
  )
  $customIconConfirm.Foreground = Convert-ToBrush '#FFC6D2E5'
  $customIconConfirm.FontSize = 10
  $customIconConfirm.Visibility = [System.Windows.Visibility]::Collapsed
  $customIconConfirm.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
  $customIconPreviewInfo.Children.Add($customIconConfirm) | Out-Null
  $customIconRetry = [System.Windows.Controls.Button]::new()
  $customIconRetry.Content = 'Retry preview'
  $customIconRetry.Width = 96
  $customIconRetry.Height = 27
  $customIconRetry.Visibility = [System.Windows.Visibility]::Collapsed
  $customIconRetry.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $customIconRetry.Background = Convert-ToBrush '#FF172A47'
  $customIconRetry.Foreground = Convert-ToBrush '#FFF6F9FF'
  $customIconRetry.BorderBrush = Convert-ToBrush '#665C8AC6'
  $customIconRetry.Template = New-ButtonTemplate `
    -HoverBackground '#FF174A78' `
    -PressedBackground '#FF0F355E'
  $customIconPaste = [System.Windows.Controls.Button]::new()
  $customIconPaste.Content = 'Paste image'
  $customIconPaste.Width = 96
  $customIconPaste.Height = 27
  $customIconPaste.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
  $customIconPaste.Background = Convert-ToBrush '#FF172A47'
  $customIconPaste.Foreground = Convert-ToBrush '#FFF6F9FF'
  $customIconPaste.BorderBrush = Convert-ToBrush '#665C8AC6'
  $customIconPaste.ToolTip = 'Use an image currently copied to the Windows clipboard.'
  [System.Windows.Automation.AutomationProperties]::SetName(
    $customIconPaste,
    'Paste clipboard image'
  )
  $customIconPaste.Template = New-ButtonTemplate `
    -HoverBackground '#FF174A78' `
    -PressedBackground '#FF0F355E'
  $customIconActions = [System.Windows.Controls.StackPanel]::new()
  $customIconActions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $customIconActions.Children.Add($customIconPaste) | Out-Null
  $customIconActions.Children.Add($customIconRetry) | Out-Null
  $customIconPreviewInfo.Children.Add($customIconActions) | Out-Null
  $stack.Children.Add($customIconPreviewRow) | Out-Null
  $hoverMediaBox = Add-DialogField -Label 'Hover media (optional)' -Value $(if ($null -eq $ExistingItem) { '' } else { [string]$ExistingItem.hoverMedia }) -Help 'A local image, GIF, MP4/WMV video, public HTTPS image, or YouTube link.'
  $hoverMuteCheck = [System.Windows.Controls.CheckBox]::new()
  $hoverMuteCheck.Content = 'Mute hover video'
  $hoverMuteCheck.IsChecked = if ($null -eq $ExistingItem) {
    $true
  } else {
    [bool]$ExistingItem.hoverMediaMuted
  }
  $hoverMuteCheck.Foreground = Convert-ToBrush '#FFC6D2E5'
  $hoverMuteCheck.FontSize = 11
  $hoverMuteCheck.Margin = [System.Windows.Thickness]::new(0, -2, 0, 12)
  $stack.Children.Add($hoverMuteCheck) | Out-Null

  $runtimeHint = New-TextBlock -Text 'Offline services can start with Node. Hover media is loaded only from the path or URL you explicitly configure.' -Size 10 -Color '#FF7D91AE'
  $runtimeHint.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $runtimeHint.Margin = [System.Windows.Thickness]::new(0, -2, 0, 14)
  $stack.Children.Add($runtimeHint) | Out-Null

  $buttons = [System.Windows.Controls.StackPanel]::new()
  $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $stack.Children.Add($buttons) | Out-Null

  $cancel = [System.Windows.Controls.Button]::new()
  $cancel.Content = 'Cancel'
  $cancel.IsCancel = $true
  $cancel.Width = 82
  $cancel.Height = 34
  $cancel.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
  $cancel.Background = Convert-ToBrush '#FF172A47'
  $cancel.Foreground = Convert-ToBrush '#FFF6F9FF'
  $cancel.BorderBrush = Convert-ToBrush '#665C8AC6'
  $cancel.Template = New-ButtonTemplate `
    -HoverBackground '#FF174A78' `
    -PressedBackground '#FF0F355E'
  $cancel.Add_Click({ $dialog.DialogResult = $false })
  $buttons.Children.Add($cancel) | Out-Null

  $save = [System.Windows.Controls.Button]::new()
  $save.Content = 'Save'
  $save.IsDefault = $true
  $save.Width = 82
  $save.Height = 34
  $save.Background = Convert-ToBrush '#FF1F6FD0'
  $save.Foreground = [System.Windows.Media.Brushes]::White
  $save.BorderBrush = Convert-ToBrush '#FF3E8BFF'
  $save.Template = New-ButtonTemplate `
    -HoverBackground '#FF1765C1' `
    -PressedBackground '#FF155FC2' `
    -HoverBorder '#FFD9E9FF'
  $buttons.Children.Add($save) | Out-Null

  $customIconPreviewState = @{
    source = ''
    validated = $false
    confirmed = $false
    cachePath = ''
    cacheKey = ''
    previewPath = ''
    generation = 0
    webView = $null
    captureTask = $null
    captureStream = $null
    capturePath = ''
    captureGeneration = 0
    requiresConfirmation = $false
    expiryHint = ''
  }
  $updateCustomIconSaveState = {
    $source = $customIconBox.Text.Trim()
    $isRemote = $source -match '^https://'
    $requiresConfirmation = (
      $isRemote -or
      [bool]$customIconPreviewState.requiresConfirmation
    )
    $save.IsEnabled = (
      -not $requiresConfirmation -or
      (
        $customIconPreviewState.validated -and
        $customIconPreviewState.confirmed -and
        [string]::Equals(
          [string]$customIconPreviewState.source,
          $source,
          [System.StringComparison]::Ordinal
        ) -and
        (Test-Path `
          -LiteralPath ([string]$customIconPreviewState.cachePath) `
          -PathType Leaf)
      )
    )
  }
  $setCustomIconPreviewFailure = {
    param([string]$Message)
    $customIconPreviewState.validated = $false
    $customIconPreviewState.confirmed = $false
    $customIconPreviewState.cachePath = ''
    $customIconPreviewState.requiresConfirmation = $false
    $customIconPreviewState.expiryHint = ''
    $customIconConfirm.IsChecked = $false
    $customIconConfirm.Visibility = [System.Windows.Visibility]::Collapsed
    $customIconPreviewImage.Source = $null
    if ($null -ne $customIconPreviewState.webView) {
      $customIconPreviewState.webView.Visibility = [System.Windows.Visibility]::Collapsed
    }
    $customIconPreviewStatus.Text = $Message
    $customIconPreviewStatus.Foreground = Convert-ToBrush '#FFFFA6A6'
    & $updateCustomIconSaveState
  }
  $setCustomIconPreviewReady = {
    param(
      [string]$Source,
      [string]$CachePath,
      [string]$Message,
      [bool]$KeepExistingConfirmation = $false,
      [bool]$RequiresConfirmation = $true
    )
    $customIconPreviewImage.Source = New-MediaBitmap `
      -Source $CachePath `
      -Kind 'image'
    $customIconPreviewImage.Visibility = [System.Windows.Visibility]::Visible
    if ($null -ne $customIconPreviewState.webView) {
      $customIconPreviewState.webView.Visibility = [System.Windows.Visibility]::Collapsed
    }
    $customIconPreviewState.source = $Source
    $customIconPreviewState.cachePath = $CachePath
    $customIconPreviewState.validated = $true
    $customIconPreviewState.confirmed = $KeepExistingConfirmation
    $customIconPreviewState.requiresConfirmation = $RequiresConfirmation
    $customIconConfirm.IsChecked = $KeepExistingConfirmation
    $customIconConfirm.Visibility = if ($RequiresConfirmation) {
      [System.Windows.Visibility]::Visible
    } else {
      [System.Windows.Visibility]::Collapsed
    }
    $customIconPreviewStatus.Text = $Message
    $customIconPreviewStatus.Foreground = Convert-ToBrush '#FF75E6B2'
    & $updateCustomIconSaveState
  }
  $customIconCapturePoll = [System.Windows.Threading.DispatcherTimer]::new()
  $customIconCapturePoll.Interval = [TimeSpan]::FromMilliseconds(50)
  $customIconCapturePoll.Add_Tick({
      $task = $customIconPreviewState.captureTask
      if ($null -eq $task -or -not $task.IsCompleted) {
        return
      }
      $customIconCapturePoll.Stop()
      $captureGeneration = [int]$customIconPreviewState.captureGeneration
      $capturePath = [string]$customIconPreviewState.capturePath
      try {
        $task.GetAwaiter().GetResult()
      } catch {
        if ($null -ne $customIconPreviewState.captureStream) {
          $customIconPreviewState.captureStream.Dispose()
        }
        $customIconPreviewState.captureStream = $null
        if ($captureGeneration -eq [int]$customIconPreviewState.generation) {
          & $setCustomIconPreviewFailure `
            "SVG preview could not be captured. $($_.Exception.Message)"
        }
        return
      }
      if ($null -ne $customIconPreviewState.captureStream) {
        $customIconPreviewState.captureStream.Dispose()
      }
      $customIconPreviewState.captureStream = $null
      if ($captureGeneration -ne [int]$customIconPreviewState.generation) {
        return
      }
      try {
        $cardPath = Join-Path (Join-Path $runtimeRoot 'IconCache') (
          '{0}-card.png' -f [string]$customIconPreviewState.cacheKey
        )
        $capturedBitmap = New-MediaBitmap -Source $capturePath -Kind 'image'
        Save-NormalizedCustomIconBitmap `
          -Bitmap $capturedBitmap `
          -CachePath $cardPath | Out-Null
      } catch {
        & $setCustomIconPreviewFailure `
          "SVG card image could not be normalized. $($_.Exception.Message)"
        return
      }
      $keepConfirmation = (
        $null -ne $ExistingItem -and
        [string]::Equals(
          [string]$ExistingItem.customIcon,
          [string]$customIconPreviewState.source,
          [System.StringComparison]::Ordinal
        ) -and
        $ExistingItem.PSObject.Properties.Name -contains 'customIconCache' -and
        [string]::Equals(
          [string]$ExistingItem.customIconCache,
          $cardPath,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      )
      try {
        $readyMessage = (
          'SVG loaded safely. A local card copy will remain available after the source expires. Confirm the preview to enable Save.' +
          [string]$customIconPreviewState.expiryHint
        )
        & $setCustomIconPreviewReady `
          ([string]$customIconPreviewState.source) `
          $cardPath `
          $readyMessage `
          $keepConfirmation
      } catch {
        & $setCustomIconPreviewFailure `
          "SVG preview could not be opened. $($_.Exception.Message)"
      }
    })
  $customIconCaptureDelay = [System.Windows.Threading.DispatcherTimer]::new()
  $customIconCaptureDelay.Interval = [TimeSpan]::FromMilliseconds(300)
  $customIconCaptureDelay.Add_Tick({
      $customIconCaptureDelay.Stop()
      $webView = $customIconPreviewState.webView
      if (
        $null -eq $webView -or
        $null -eq $webView.CoreWebView2 -or
        [string]::IsNullOrWhiteSpace(
          [string]$customIconPreviewState.previewPath
        )
      ) {
        & $setCustomIconPreviewFailure 'SVG preview runtime is not ready.'
        return
      }
      $cacheRoot = Join-Path $runtimeRoot 'IconCache'
      $capturePath = Join-Path $cacheRoot (
        '{0}-rendered-{1}.png' -f
        $customIconPreviewState.cacheKey,
        ([guid]::NewGuid().ToString('N'))
      )
      try {
        $stream = [System.IO.FileStream]::new(
          $capturePath,
          [System.IO.FileMode]::CreateNew,
          [System.IO.FileAccess]::Write,
          [System.IO.FileShare]::None
        )
        $customIconPreviewState.captureStream = $stream
        $customIconPreviewState.capturePath = $capturePath
        $customIconPreviewState.captureGeneration = (
          [int]$customIconPreviewState.generation
        )
        $customIconPreviewState.captureTask = (
          $webView.CoreWebView2.CapturePreviewAsync(
            [Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat]::Png,
            $stream
          )
        )
        $customIconCapturePoll.Start()
      } catch {
        if ($null -ne $customIconPreviewState.captureStream) {
          $customIconPreviewState.captureStream.Dispose()
          $customIconPreviewState.captureStream = $null
        }
        & $setCustomIconPreviewFailure `
          "SVG preview could not be captured. $($_.Exception.Message)"
      }
    })
  $ensureCustomIconWebView = {
    if ($null -ne $customIconPreviewState.webView) {
      return $customIconPreviewState.webView
    }
    if (-not $script:webView2Available) {
      throw 'WebView2 is required to preview SVG icons.'
    }
    $webView = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $webView.IsHitTestVisible = $false
    $webView.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $webView.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    try {
      $webView.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
    } catch {
    }
    $creationProperties = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $creationProperties.UserDataFolder = Join-Path $runtimeRoot 'IconPreviewWebView2'
    $creationProperties.AdditionalBrowserArguments = '--disk-cache-size=33554432'
    $webView.CreationProperties = $creationProperties
    $webView.add_CoreWebView2InitializationCompleted({
        param($sender, $eventArgs)
        if (-not $eventArgs.IsSuccess) {
          & $setCustomIconPreviewFailure `
            "SVG preview runtime failed. $($eventArgs.InitializationException.Message)"
          return
        }
        $settings = $sender.CoreWebView2.Settings
        $settings.IsScriptEnabled = $false
        $settings.IsWebMessageEnabled = $false
        $settings.AreDefaultContextMenusEnabled = $false
        $settings.AreDevToolsEnabled = $false
        $settings.IsStatusBarEnabled = $false
        $settings.IsZoomControlEnabled = $false
        try {
          $settings.AreHostObjectsAllowed = $false
          $settings.IsPasswordAutosaveEnabled = $false
          $settings.IsGeneralAutofillEnabled = $false
        } catch {
          Write-RuntimeLog "Optional SVG preview isolation settings are unavailable. $($_.Exception.Message)"
        }
        $sender.CoreWebView2.add_NewWindowRequested({
            param($core, $requestArgs)
            $requestArgs.Handled = $true
          })
        $sender.CoreWebView2.add_PermissionRequested({
            param($core, $permissionArgs)
            $permissionArgs.State = (
              [Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Deny
            )
            $permissionArgs.Handled = $true
          })
        $sender.CoreWebView2.add_DownloadStarting({
            param($core, $downloadArgs)
            $downloadArgs.Cancel = $true
          })
      })
    $webView.add_NavigationStarting({
        param($sender, $eventArgs)
        try {
          $target = [uri][string]$eventArgs.Uri
          $cacheRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $runtimeRoot 'IconCache')
          )
          $targetPath = if ($target.IsFile) {
            [System.IO.Path]::GetFullPath($target.LocalPath)
          } else {
            ''
          }
          if (
            -not $target.IsFile -or
            -not $targetPath.StartsWith(
              $cacheRoot + [System.IO.Path]::DirectorySeparatorChar,
              [System.StringComparison]::OrdinalIgnoreCase
            )
          ) {
            $eventArgs.Cancel = $true
          }
        } catch {
          $eventArgs.Cancel = $true
        }
      })
    $webView.add_NavigationCompleted({
        param($sender, $eventArgs)
        if (-not $eventArgs.IsSuccess) {
          & $setCustomIconPreviewFailure `
            "SVG preview navigation failed: $($eventArgs.WebErrorStatus)"
          return
        }
        $customIconCaptureDelay.Stop()
        $customIconCaptureDelay.Start()
      })
    $customIconPreviewHost.Children.Add($webView) | Out-Null
    $customIconPreviewState.webView = $webView
    return $webView
  }
  $refreshCustomIconPreview = {
    param([bool]$ForceRemoteRefresh = $false)

    $source = $customIconBox.Text.Trim()
    $customIconPreviewState.generation = (
      [int]$customIconPreviewState.generation + 1
    )
    $customIconPreviewState.source = $source
    $customIconPreviewState.validated = $false
    $customIconPreviewState.confirmed = $false
    $customIconPreviewState.cachePath = ''
    $customIconConfirm.IsChecked = $false
    $customIconRetry.Visibility = if ($source -match '^https://') {
      [System.Windows.Visibility]::Visible
    } else {
      [System.Windows.Visibility]::Collapsed
    }
    $customIconPreviewImage.Source = $null
    if ($null -ne $customIconPreviewState.webView) {
      $customIconPreviewState.webView.Visibility = [System.Windows.Visibility]::Collapsed
    }
    if ([string]::IsNullOrWhiteSpace($source)) {
      $customIconConfirm.Visibility = [System.Windows.Visibility]::Collapsed
      $customIconPreviewStatus.Text = (
        'Local, clipboard, and HTTPS icons can be previewed here.'
      )
      $customIconPreviewStatus.Foreground = Convert-ToBrush '#FF7D91AE'
      & $updateCustomIconSaveState
      return
    }
    if ($source -notmatch '^https://') {
      if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        & $setCustomIconPreviewFailure 'Local icon file was not found.'
        return
      }
      try {
        $isClipboardIcon = Test-ManagedClipboardIconPath -Path $source
        $extension = [System.IO.Path]::GetExtension($source)
        $bitmap = if ($extension -ieq '.gif') {
          $frames = @(Get-GifFrames -Path $source)
          if ($frames.Count -eq 0) {
            throw 'GIF icon contains no image frames.'
          }
          $frames[0]
        } else {
          New-MediaBitmap -Source $source -Kind 'image'
        }
        if ($isClipboardIcon) {
          $keepClipboardConfirmation = (
            $null -ne $ExistingItem -and
            [string]::Equals(
              [string]$ExistingItem.customIcon,
              $source,
              [System.StringComparison]::OrdinalIgnoreCase
            )
          )
          & $setCustomIconPreviewReady `
            $source `
            $source `
            'Clipboard image loaded. Confirm the preview to enable Save.' `
            $keepClipboardConfirmation `
            $true
          return
        }
        $customIconPreviewState.requiresConfirmation = $false
        $customIconConfirm.Visibility = [System.Windows.Visibility]::Collapsed
        $customIconPreviewImage.Source = $bitmap
        $customIconPreviewImage.Visibility = [System.Windows.Visibility]::Visible
        $customIconPreviewStatus.Text = 'Local icon loaded.'
        $customIconPreviewStatus.Foreground = Convert-ToBrush '#FF75E6B2'
        & $updateCustomIconSaveState
      } catch {
        & $setCustomIconPreviewFailure `
          "Local icon could not load. $($_.Exception.Message)"
      }
      return
    }
    $customIconConfirm.Visibility = [System.Windows.Visibility]::Visible
    $customIconPreviewState.requiresConfirmation = $true
    $expiry = Get-SignedRemoteIconExpiry -Source $source
    if ($null -ne $expiry) {
      $customIconPreviewState.expiryHint = (
        " Signed URL expires at $($expiry.localText)."
      )
    }
    $existingCachePath = if (
      $null -ne $ExistingItem -and
      [string]::Equals(
        [string]$ExistingItem.customIcon,
        $source,
        [System.StringComparison]::Ordinal
      ) -and
      $ExistingItem.PSObject.Properties.Name -contains 'customIconCache'
    ) {
      [string]$ExistingItem.customIconCache
    } else {
      ''
    }
    $hasExistingCache = (
      -not [string]::IsNullOrWhiteSpace($existingCachePath) -and
      (Test-Path -LiteralPath $existingCachePath -PathType Leaf)
    )
    if (-not $ForceRemoteRefresh -and $hasExistingCache) {
      try {
        $cachedMessage = if ($null -ne $expiry -and $expiry.expired) {
          "Local card copy in use. The source expired at $($expiry.localText)."
        } else {
          'Local card copy loaded. It remains available if the source expires. Use Retry preview to refresh it.'
        }
        & $setCustomIconPreviewReady `
          $source `
          $existingCachePath `
          $cachedMessage `
          $true
        if ($null -ne $expiry -and $expiry.expired) {
          $customIconPreviewStatus.Foreground = Convert-ToBrush '#FFFFC266'
        }
        return
      } catch {
        $hasExistingCache = $false
      }
    }
    if ($null -ne $expiry -and $expiry.expired) {
      if ($hasExistingCache) {
        try {
          & $setCustomIconPreviewReady `
            $source `
            $existingCachePath `
            (
              "Refresh skipped because the source expired at $($expiry.localText). " +
              'The existing local card copy remains active.'
            ) `
            $true
          $customIconPreviewStatus.Foreground = Convert-ToBrush '#FFFFC266'
          return
        } catch {
          $hasExistingCache = $false
        }
      }
      & $setCustomIconPreviewFailure (
        "This signed icon URL expired at $($expiry.localText), and no usable " +
        'local copy exists. Copy a fresh image address from the provider.'
      )
      return
    }
    $customIconPreviewStatus.Text = 'Checking HTTPS image, size, and safety...'
    $customIconPreviewStatus.Foreground = Convert-ToBrush '#FFA9B9D1'
    & $updateCustomIconSaveState
    try {
      $asset = Get-RemoteCustomIconAsset -Source $source
      $customIconPreviewState.cacheKey = [string]$asset.cacheKey
      $customIconPreviewState.previewPath = [string]$asset.previewPath
      if ($asset.isSvg) {
        $webView = & $ensureCustomIconWebView
        $webView.Visibility = [System.Windows.Visibility]::Visible
        $customIconPreviewStatus.Text = 'Rendering the verified static SVG...'
        $webView.Source = [uri][System.IO.Path]::GetFullPath(
          [string]$asset.previewPath
        )
        return
      }
      $keepConfirmation = (
        $null -ne $ExistingItem -and
        [string]::Equals(
          [string]$ExistingItem.customIcon,
          $source,
          [System.StringComparison]::Ordinal
        ) -and
        $ExistingItem.PSObject.Properties.Name -contains 'customIconCache' -and
        [string]::Equals(
          [string]$ExistingItem.customIconCache,
          [string]$asset.cachePath,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      )
      & $setCustomIconPreviewReady `
        $source `
        ([string]$asset.cachePath) `
        (
          'HTTPS image loaded. A local card copy will remain available after the source expires. Confirm the preview to enable Save.' +
          [string]$customIconPreviewState.expiryHint
        ) `
        $keepConfirmation
    } catch {
      if ($hasExistingCache) {
        try {
          & $setCustomIconPreviewReady `
            $source `
            $existingCachePath `
            (
              "Refresh failed, so the existing local card copy remains active. " +
              $_.Exception.Message
            ) `
            $true
          $customIconPreviewStatus.Foreground = Convert-ToBrush '#FFFFC266'
          return
        } catch {
          $hasExistingCache = $false
        }
      }
      & $setCustomIconPreviewFailure `
        "HTTPS icon could not be verified. $($_.Exception.Message)"
    }
  }
  $customIconDebounce = [System.Windows.Threading.DispatcherTimer]::new()
  $customIconDebounce.Interval = [TimeSpan]::FromMilliseconds(700)
  $customIconDebounce.Add_Tick({
      $customIconDebounce.Stop()
      & $refreshCustomIconPreview
    })
  $customIconBox.Add_TextChanged({
      $customIconDebounce.Stop()
      $customIconPreviewState.validated = $false
      $customIconPreviewState.confirmed = $false
      $customIconConfirm.IsChecked = $false
      & $updateCustomIconSaveState
      $customIconDebounce.Start()
    })
  $customIconConfirm.Add_Checked({
      $customIconPreviewState.confirmed = $true
      & $updateCustomIconSaveState
    })
  $customIconConfirm.Add_Unchecked({
      $customIconPreviewState.confirmed = $false
      & $updateCustomIconSaveState
    })
  $customIconPaste.Add_Click({
      try {
        $clipboardAsset = Save-ClipboardCustomIconAsset
        $customIconDebounce.Stop()
        $customIconBox.Text = [string]$clipboardAsset.cachePath
        $customIconDebounce.Stop()
        & $setCustomIconPreviewReady `
          ([string]$clipboardAsset.cachePath) `
          ([string]$clipboardAsset.cachePath) `
          (
            'Clipboard image loaded ({0} x {1}). Confirm the preview to enable Save.' -f
            $clipboardAsset.width,
            $clipboardAsset.height
          ) `
          $false `
          $true
      } catch {
        & $setCustomIconPreviewFailure `
          "Clipboard image could not be used. $($_.Exception.Message)"
      }
    })
  $customIconRetry.Add_Click({
      $customIconDebounce.Stop()
      & $refreshCustomIconPreview $true
    })

  $save.Add_Click({
      $name = $nameBox.Text.Trim()
      $targetInput = $targetBox.Text.Trim()
      $health = $healthBox.Text.Trim()
      $startupTarget = $startupTargetBox.Text.Trim()
      $startupArgs = $startupArgsBox.Text.Trim()
      $customIcon = $customIconBox.Text.Trim()
      $customIconCache = if ($customIcon -match '^https://') {
        [string]$customIconPreviewState.cachePath
      } else {
        ''
      }
      $iconPreset = if ($null -ne $semanticIconBox.SelectedItem) {
        ([string]$semanticIconBox.SelectedItem.Tag).Trim().ToLowerInvariant()
      } else {
        ''
      }
      $hoverMedia = $hoverMediaBox.Text.Trim()
      $hoverMediaKind = Resolve-MediaKind -Source $hoverMedia -ConfiguredKind 'auto'
      $hoverMediaMuted = [bool]$hoverMuteCheck.IsChecked
      if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($targetInput)) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Name and target are required.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      if (
        $null -eq $ExistingItem -and
        @($script:state.items).Count -ge $script:maximumShortcutCount
      ) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          "Workspace supports up to $($script:maximumShortcutCount) shortcuts.",
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      $targetInputUri = if ($targetInput -match '^https?://') {
        Get-ValidatedWebUri -Value $targetInput
      } else {
        $null
      }
      if (
        ($targetInput -match '^https?://' -and $null -eq $targetInputUri) -or
        ($targetInput -notmatch '^https?://' -and -not (Test-Path -LiteralPath $targetInput))
      ) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Use an absolute http/https URL without embedded credentials, or an existing local path.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }

      $registration = Resolve-ShortcutRegistration -Path $targetInput
      if (-not $registration.success) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'The shortcut target could not be resolved.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      $target = [string]$registration.target
      $targetUri = if ($target -match '^https?://') {
        Get-ValidatedWebUri -Value $target
      } else {
        $null
      }
      if (
        ($target -match '^https?://' -and $null -eq $targetUri) -or
        ($target -notmatch '^https?://' -and -not (Test-Path -LiteralPath $target))
      ) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          "The resolved target no longer exists:`n$target",
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }

      $preserveExistingLaunch = (
        $null -ne $ExistingItem -and
        $registration.kind -eq 'direct' -and
        [string]::Equals(
          [string]$ExistingItem.target,
          $target,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      )
      $launchArguments = [string]$registration.launchArguments
      $workingDirectory = [string]$registration.workingDirectory
      $iconLocation = [string]$registration.iconLocation
      $sourceShortcut = [string]$registration.sourceShortcut
      $launchWindowStyle = [int]$registration.launchWindowStyle
      if ($preserveExistingLaunch) {
        if ($ExistingItem.PSObject.Properties.Name -contains 'launchArguments') {
          $launchArguments = [string]$ExistingItem.launchArguments
        }
        if ($ExistingItem.PSObject.Properties.Name -contains 'workingDirectory') {
          $workingDirectory = [string]$ExistingItem.workingDirectory
        }
        if ($ExistingItem.PSObject.Properties.Name -contains 'iconLocation') {
          $iconLocation = [string]$ExistingItem.iconLocation
        }
        if ($ExistingItem.PSObject.Properties.Name -contains 'sourceShortcut') {
          $sourceShortcut = [string]$ExistingItem.sourceShortcut
        }
        if ($ExistingItem.PSObject.Properties.Name -contains 'launchWindowStyle') {
          $launchWindowStyle = [int]$ExistingItem.launchWindowStyle
        }
      }

      $healthUri = if (-not [string]::IsNullOrWhiteSpace($health)) {
        Get-ValidatedWebUri -Value $health
      } else {
        $null
      }
      if (-not [string]::IsNullOrWhiteSpace($health) -and $null -eq $healthUri) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Health URL must be an absolute http/https URL without embedded credentials.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      if (-not [string]::IsNullOrWhiteSpace($customIcon)) {
        if ($customIcon -match '^https://') {
          if (
            -not $customIconPreviewState.validated -or
            -not $customIconPreviewState.confirmed -or
            -not [string]::Equals(
              [string]$customIconPreviewState.source,
              $customIcon,
              [System.StringComparison]::Ordinal
            ) -or
            -not (Test-Path `
              -LiteralPath $customIconCache `
              -PathType Leaf)
          ) {
            [System.Windows.MessageBox]::Show(
              $dialog,
              'Wait for the HTTPS icon preview, then confirm that it is the icon you want.',
              'Workspace',
              [System.Windows.MessageBoxButton]::OK,
              [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
          }
        } else {
          $customIconKind = Resolve-MediaKind `
            -Source $customIcon `
            -ConfiguredKind 'auto'
          if (
            $customIconKind -notin @('image', 'gif') -or
            -not (Test-MediaSource -Source $customIcon -ConfiguredKind $customIconKind)
          ) {
            [System.Windows.MessageBox]::Show(
              $dialog,
              'Custom icon must be a readable local PNG, JPG, BMP, ICO, or GIF file, or a verified public HTTPS image URL.',
              'Workspace',
              [System.Windows.MessageBoxButton]::OK,
              [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
          }
        }
      }
      if (
        [string]::IsNullOrWhiteSpace($customIcon) -and
        -not [string]::IsNullOrWhiteSpace($customIconCache)
      ) {
        $customIconCache = ''
      }
      if (
        -not [string]::IsNullOrWhiteSpace($hoverMedia) -and
        -not (Test-MediaSource -Source $hoverMedia -ConfiguredKind $hoverMediaKind)
      ) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Hover media must be a supported local file, public HTTPS image, or YouTube link.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      if (-not [string]::IsNullOrWhiteSpace($startupTarget)) {
        if ($null -ne $healthUri -and -not (Test-LoopbackWebUri -Uri $healthUri)) {
          [System.Windows.MessageBox]::Show(
            $dialog,
            'A Node start target can only be paired with a loopback health URL such as http://127.0.0.1:3000/health. Remote health monitoring remains available when no Node start target is configured.',
            'Workspace',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
          ) | Out-Null
          return
        }
        if (-not (Test-Path -LiteralPath $startupTarget)) {
          [System.Windows.MessageBox]::Show(
            $dialog,
            'Node start target must be an existing JS entry file or project folder.',
            'Workspace',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
          ) | Out-Null
          return
        }

        if (Test-Path -LiteralPath $startupTarget -PathType Container) {
          if (-not (Test-Path -LiteralPath (Join-Path $startupTarget 'package.json') -PathType Leaf)) {
            [System.Windows.MessageBox]::Show(
              $dialog,
              'A Node project folder must contain package.json.',
              'Workspace',
              [System.Windows.MessageBoxButton]::OK,
              [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
          }
          if (-not [string]::IsNullOrWhiteSpace($startupArgs) -and $startupArgs -notmatch '^[A-Za-z0-9:_-]+$') {
            [System.Windows.MessageBox]::Show(
              $dialog,
              'For a project folder, enter one package script name such as dev or start.',
              'Workspace',
              [System.Windows.MessageBoxButton]::OK,
              [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
          }
        } elseif ([System.IO.Path]::GetExtension($startupTarget) -notmatch '^\.(js|mjs|cjs)$') {
          [System.Windows.MessageBox]::Show(
            $dialog,
            'A Node entry file must end in .js, .mjs, or .cjs.',
            'Workspace',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
          ) | Out-Null
          return
        }
      }

      $newItem = $null
      $existingSnapshot = $null
      if ($null -eq $ExistingItem) {
        $newItem = [pscustomobject][ordered]@{
          id = New-ItemId
          name = $name
          target = $target
          subtitle = Get-Subtitle -Target $target
          health = $health
          startupTarget = $startupTarget
          startupArgs = $startupArgs
          launchArguments = $launchArguments
          workingDirectory = $workingDirectory
          iconLocation = $iconLocation
          sourceShortcut = $sourceShortcut
          launchWindowStyle = $launchWindowStyle
          customIcon = $customIcon
          customIconCache = $customIconCache
          iconPreset = $iconPreset
          hoverMedia = $hoverMedia
          hoverMediaKind = $hoverMediaKind
          hoverMediaMuted = $hoverMediaMuted
          glyph = if ($target -match '^https?://') { '' } else { '' }
          hidden = $false
        }
        $script:state.items += $newItem
      } else {
        $existingSnapshot = $ExistingItem |
          ConvertTo-Json -Depth 10 |
          ConvertFrom-Json
        $ExistingItem.name = $name
        $ExistingItem.target = $target
        $ExistingItem.subtitle = Get-Subtitle -Target $target
        $ExistingItem.health = $health
        $ExistingItem.startupTarget = $startupTarget
        $ExistingItem.startupArgs = $startupArgs
        $ExistingItem.launchArguments = $launchArguments
        $ExistingItem.workingDirectory = $workingDirectory
        $ExistingItem.iconLocation = $iconLocation
        $ExistingItem.sourceShortcut = $sourceShortcut
        $ExistingItem.launchWindowStyle = $launchWindowStyle
        $ExistingItem.customIcon = $customIcon
        $ExistingItem.customIconCache = $customIconCache
        $ExistingItem.iconPreset = $iconPreset
        $ExistingItem.hoverMedia = $hoverMedia
        $ExistingItem.hoverMediaKind = $hoverMediaKind
        $ExistingItem.hoverMediaMuted = $hoverMediaMuted
        $ExistingItem.glyph = if ($target -match '^https?://') { '' } else { '' }
      }
      if (-not (Save-State)) {
        if ($null -ne $newItem) {
          $newItemId = [string]$newItem.id
          $script:state.items = @(
            $script:state.items |
              Where-Object { [string]$_.id -ne $newItemId }
          )
        } elseif ($null -ne $existingSnapshot) {
          foreach ($property in $existingSnapshot.PSObject.Properties) {
            $ExistingItem.($property.Name) = $property.Value
          }
        }
        Render-Items
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Workspace could not save this registration. No changes were kept.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        return
      }
      Render-Items
      $dialog.DialogResult = $true
    })

  $dialog.Add_MouseLeftButtonDown({
      param($sender, $eventArgs)
      if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        $dialog.DragMove()
      }
    })
  $dialog.Add_ContentRendered({
      & $refreshCustomIconPreview
      $nameBox.Focus() | Out-Null
    })
  $dialog.Add_Closed({
      $customIconDebounce.Stop()
      $customIconCaptureDelay.Stop()
      if (
        $null -eq $customIconPreviewState.captureTask -or
        $customIconPreviewState.captureTask.IsCompleted
      ) {
        $customIconCapturePoll.Stop()
        if ($null -ne $customIconPreviewState.captureStream) {
          $customIconPreviewState.captureStream.Dispose()
          $customIconPreviewState.captureStream = $null
        }
      }
      if ($null -ne $customIconPreviewState.webView) {
        try {
          $customIconPreviewState.webView.Dispose()
        } catch {
        }
        $customIconPreviewState.webView = $null
      }
    })
  return $dialog.ShowDialog()
}

function Get-SemanticIconSource {
  param($Item)

  if (
    $Item.PSObject.Properties.Name -notcontains 'iconPreset' -or
    [string]::IsNullOrWhiteSpace([string]$Item.iconPreset)
  ) {
    return $null
  }

  $preset = ([string]$Item.iconPreset).Trim().ToLowerInvariant()
  $definition = @(
    Get-WorkspaceSemanticIconDefinitions |
      Where-Object {
        [string]::Equals(
          [string]$_.id,
          $preset,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      } |
      Select-Object -First 1
  )
  if ($definition.Count -eq 0) {
    if ($script:invalidSemanticIconIds.Add($preset)) {
      Write-RuntimeLog "Unknown semantic icon preset '$preset' was ignored."
    }
    return $null
  }
  try {
    return New-MediaBitmap -Source ([string]$definition[0].pngPath) -Kind 'image'
  } catch {
    if ($script:invalidSemanticIconIds.Add($preset)) {
      Write-RuntimeLog "Semantic icon '$preset' could not load. $($_.Exception.Message)"
    }
    return $null
  }
}

function Get-ItemIconPresentation {
  param($Item)

  $customIcon = Get-CustomIconSource -Item $Item
  if ($null -ne $customIcon) {
    return [pscustomobject][ordered]@{ kind = 'Custom'; source = $customIcon }
  }

  $semanticIcon = Get-SemanticIconSource -Item $Item
  if ($null -ne $semanticIcon) {
    return [pscustomobject][ordered]@{ kind = 'Semantic'; source = $semanticIcon }
  }

  $target = [string]$Item.target
  if ($target -match '^https?://') {
    return [pscustomobject][ordered]@{ kind = 'None'; source = $null }
  }
  try {
    $iconTarget = $target
    $iconResourceIndex = $null
    if (
      $Item.PSObject.Properties.Name -contains 'iconLocation' -and
      -not [string]::IsNullOrWhiteSpace([string]$Item.iconLocation)
    ) {
      $iconLocation = ([string]$Item.iconLocation).Trim()
      $iconCandidate = $iconLocation.Trim('"')
      if ($iconLocation -match '^(?<path>.*),\s*(?<index>-?\d+)\s*$') {
        $iconCandidate = $Matches['path'].Trim().Trim('"')
        $iconResourceIndex = [int]$Matches['index']
      }
      if (Test-Path -LiteralPath $iconCandidate -PathType Leaf) {
        $iconTarget = $iconCandidate
      }
    }
    if ($null -ne $iconResourceIndex -and (Test-Path -LiteralPath $iconTarget -PathType Leaf)) {
      $resourceIcon = [WorkspaceWidgetNative]::GetIconResource(
        $iconTarget,
        [int]$iconResourceIndex
      )
      if ($null -ne $resourceIcon) {
        return [pscustomobject][ordered]@{ kind = 'Shell'; source = $resourceIcon }
      }
    }
    $isDirectory = Test-Path -LiteralPath $iconTarget -PathType Container
    $shellIcon = [WorkspaceWidgetNative]::GetShellIcon($iconTarget, $isDirectory)
    return [pscustomobject][ordered]@{
      kind = if ($null -ne $shellIcon) { 'Shell' } else { 'None' }
      source = $shellIcon
    }
  } catch {
    Write-RuntimeLog "Icon load failed for '$target'. $($_.Exception.Message)"
    return [pscustomobject][ordered]@{ kind = 'None'; source = $null }
  }
}

function Get-ItemIcon {
  param($Item)

  return (Get-ItemIconPresentation -Item $Item).source
}

function Test-HasNodeStartup {
  param($Item)

  return (
    $Item.PSObject.Properties.Name -contains 'startupTarget' -and
    -not [string]::IsNullOrWhiteSpace([string]$Item.startupTarget)
  )
}

function Test-HasHealthCheck {
  param($Item)

  if (
    $Item.PSObject.Properties.Name -notcontains 'health' -or
    [string]::IsNullOrWhiteSpace([string]$Item.health)
  ) {
    return $false
  }
  return $null -ne (Get-ValidatedWebUri -Value ([string]$Item.health))
}

function Open-ItemTarget {
  param($Item)

  $target = [string]$Item.target
  $targetUri = if ($target -match '^https?://') {
    Get-ValidatedWebUri -Value $target
  } else {
    $null
  }
  if (
    ($target -match '^https?://' -and $null -eq $targetUri) -or
    ($target -notmatch '^https?://' -and -not (Test-Path -LiteralPath $target))
  ) {
    throw "The target is invalid or no longer exists: $target"
  }

  $launch = @{
    FilePath = $target
  }
  $launchWorkingDirectory = ''
  if (
    $Item.PSObject.Properties.Name -contains 'launchArguments' -and
    -not [string]::IsNullOrWhiteSpace([string]$Item.launchArguments)
  ) {
    $launch.ArgumentList = [string]$Item.launchArguments
  }
  if (
    $Item.PSObject.Properties.Name -contains 'workingDirectory' -and
    -not [string]::IsNullOrWhiteSpace([string]$Item.workingDirectory)
  ) {
    if (Test-Path -LiteralPath ([string]$Item.workingDirectory) -PathType Container) {
      $launchWorkingDirectory = [string]$Item.workingDirectory
    } else {
      Write-RuntimeLog "Working directory is unavailable for '$($Item.name)'; deriving a writable launch directory."
    }
  }
  if ([string]::IsNullOrWhiteSpace($launchWorkingDirectory)) {
    if ($target -match '^https?://') {
      $launchWorkingDirectory = $env:USERPROFILE
    } elseif (Test-Path -LiteralPath $target -PathType Container) {
      $launchWorkingDirectory = $target
    } else {
      $launchWorkingDirectory = $env:USERPROFILE
    }
  }
  if (
    -not [string]::IsNullOrWhiteSpace($launchWorkingDirectory) -and
    (Test-Path -LiteralPath $launchWorkingDirectory -PathType Container)
  ) {
    $launch.WorkingDirectory = $launchWorkingDirectory
  }
  if ($Item.PSObject.Properties.Name -contains 'launchWindowStyle') {
    switch ([int]$Item.launchWindowStyle) {
      3 { $launch.WindowStyle = 'Maximized' }
      7 { $launch.WindowStyle = 'Minimized' }
    }
  }

  Start-Process @launch | Out-Null
}

function Get-NodePackageScript {
  param(
    [string]$ProjectPath,
    [string]$ConfiguredScript
  )

  $packagePath = Join-Path $ProjectPath 'package.json'
  $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
  if ($null -eq $package.scripts) {
    throw "package.json does not define scripts: $packagePath"
  }

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredScript)) {
    if ($ConfiguredScript -notmatch '^[A-Za-z0-9:_-]+$') {
      throw 'The configured package script name contains unsupported characters.'
    }
    if ($package.scripts.PSObject.Properties.Name -notcontains $ConfiguredScript) {
      throw "package.json does not define the '$ConfiguredScript' script."
    }
    return $ConfiguredScript
  }

  foreach ($candidate in @('dev', 'start')) {
    if ($package.scripts.PSObject.Properties.Name -contains $candidate) {
      return $candidate
    }
  }
  throw 'No start script was selected, and package.json has neither dev nor start.'
}

function Resolve-NodeStartupConfiguration {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [string]$Arguments,
    [string]$WorkingDirectory
  )

  $expandedTarget = [Environment]::ExpandEnvironmentVariables($Target.Trim())
  if ($expandedTarget -notmatch '^[A-Za-z]:\\') {
    throw 'Node start targets must be local, drive-rooted paths. Relative, network, and device paths are not supported.'
  }
  $resolvedTarget = [System.IO.Path]::GetFullPath($expandedTarget)
  if (
    -not [System.IO.Path]::IsPathRooted($resolvedTarget) -or
    $resolvedTarget.StartsWith('\\', [System.StringComparison]::Ordinal) -or
    $resolvedTarget.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
    $resolvedTarget -notmatch '^[A-Za-z]:\\'
  ) {
    throw 'Node start targets must be local, drive-rooted paths. Network and device paths are not supported.'
  }
  if (-not (Test-Path -LiteralPath $resolvedTarget)) {
    throw "Node start target no longer exists: $resolvedTarget"
  }
  $configuredArguments = ([string]$Arguments).Trim()
  if ($configuredArguments.Length -gt 2048 -or $configuredArguments -match '[\x00\r\n"]') {
    throw 'Node start arguments contain unsupported characters or exceed 2,048 characters.'
  }

  if (Test-Path -LiteralPath $resolvedTarget -PathType Container) {
    $packagePath = Join-Path $resolvedTarget 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
      throw 'A Node project folder must contain package.json.'
    }
    if (
      -not [string]::IsNullOrWhiteSpace($configuredArguments) -and
      $configuredArguments -notmatch '^[A-Za-z0-9:_-]+$'
    ) {
      throw 'For a project folder, configure one package script name such as dev or start.'
    }
    $scriptName = Get-NodePackageScript `
      -ProjectPath $resolvedTarget `
      -ConfiguredScript $configuredArguments
    return [pscustomobject][ordered]@{
      kind = 'project'
      target = $resolvedTarget
      arguments = $scriptName
      workingDirectory = $resolvedTarget
    }
  }

  if ([System.IO.Path]::GetExtension($resolvedTarget) -notmatch '^\.(js|mjs|cjs)$') {
    throw 'A Node entry file must end in .js, .mjs, or .cjs.'
  }
  $resolvedWorkingDirectory = Split-Path -Parent $resolvedTarget
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $expandedWorkingDirectory = [Environment]::ExpandEnvironmentVariables($WorkingDirectory.Trim())
    if ($expandedWorkingDirectory -notmatch '^[A-Za-z]:\\') {
      throw 'Node working directories must be local, drive-rooted paths.'
    }
    $resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($expandedWorkingDirectory)
    if (
      $resolvedWorkingDirectory.StartsWith('\\', [System.StringComparison]::Ordinal) -or
      $resolvedWorkingDirectory.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
      $resolvedWorkingDirectory -notmatch '^[A-Za-z]:\\' -or
      -not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)
    ) {
      throw 'The configured Node working directory is unavailable or unsupported.'
    }
  }
  return [pscustomobject][ordered]@{
    kind = 'file'
    target = $resolvedTarget
    arguments = $configuredArguments
    workingDirectory = $resolvedWorkingDirectory
  }
}

function Start-LocalServer {
  param($Item)

  if (-not (Test-HasNodeStartup -Item $Item)) {
    throw 'This shortcut does not have a Node start target.'
  }
  if (
    [string]::IsNullOrWhiteSpace($bundledNodePath) -or
    -not (Test-Path -LiteralPath $bundledNodePath -PathType Leaf)
  ) {
    $runtimeHelp = if ($packageRuntimeEnforced) {
      'The package-local runtime is missing or damaged. Reinstall Workspace Widget.'
    } else {
      'Add runtime\node\node.exe or configure a development-only WORKSPACE_WIDGET_NODE override.'
    }
    throw "No supported Node runtime was found. $runtimeHelp"
  }

  $itemId = [string]$Item.id
  if ($script:serverProcesses.ContainsKey($itemId)) {
    try {
      if (-not $script:serverProcesses[$itemId].HasExited) {
        return $true
      }
    } catch {
      # A stale process handle is replaced below.
    }
  }

  $configuredWorkingDirectory = if (
    $Item.PSObject.Properties.Name -contains 'workingDirectory'
  ) {
    [string]$Item.workingDirectory
  } else {
    ''
  }
  $startupConfiguration = Resolve-NodeStartupConfiguration `
    -Target ([string]$Item.startupTarget) `
    -Arguments ([string]$Item.startupArgs) `
    -WorkingDirectory $configuredWorkingDirectory
  $startupTarget = [string]$startupConfiguration.target
  $startupArgs = [string]$startupConfiguration.arguments
  $previousPath = $env:PATH
  $bundledNodeDirectory = Split-Path -Parent $bundledNodePath
  $bundledOverrideDirectory = Join-Path $projectRuntimeRoot 'bin\override'

  try {
    $env:PATH = "$bundledNodeDirectory;$bundledOverrideDirectory;$previousPath"
    if ($startupConfiguration.kind -eq 'project') {
      $packageRunnerPath = $bundledPnpmPath
      $packageRunnerName = 'pnpm'
      if (
        [string]::IsNullOrWhiteSpace($packageRunnerPath) -or
        -not (Test-Path -LiteralPath $packageRunnerPath -PathType Leaf)
      ) {
        $packageRunnerPath = $bundledNpmPath
        $packageRunnerName = 'npm'
      }
      if (
        [string]::IsNullOrWhiteSpace($packageRunnerPath) -or
        -not (Test-Path -LiteralPath $packageRunnerPath -PathType Leaf)
      ) {
        throw (
          'No supported package runner was found. ' +
          'Add runtime\node\npm.cmd, runtime\pnpm\pnpm.cmd, or configure an override.'
        )
      }
      $scriptName = $startupArgs
      $process = Start-Process `
        -FilePath $packageRunnerPath `
        -ArgumentList "run `"$scriptName`"" `
        -WorkingDirectory $startupTarget `
        -WindowStyle Hidden `
        -PassThru
      Write-RuntimeLog "Started '$($Item.name)' with bundled $packageRunnerName script '$scriptName'. PID=$($process.Id)"
    } else {
      $workingDirectory = [string]$startupConfiguration.workingDirectory
      $argumentLine = "`"$startupTarget`""
      if (-not [string]::IsNullOrWhiteSpace($startupArgs)) {
        $argumentLine += " $startupArgs"
      }
      $process = Start-Process `
        -FilePath $bundledNodePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $workingDirectory `
        -WindowStyle Hidden `
        -PassThru
      Write-RuntimeLog "Started '$($Item.name)' with bundled Node. PID=$($process.Id)"
    }
  }
  finally {
    $env:PATH = $previousPath
  }

  $script:serverProcesses[$itemId] = $process
  return $true
}

function Stop-ProcessTree {
  param(
    [Parameter(Mandatory = $true)]
    [System.Diagnostics.Process]$Process
  )

  if ($Process.HasExited) {
    return $true
  }
  $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if (-not (Test-Path -LiteralPath $taskKillPath -PathType Leaf)) {
    throw 'Windows taskkill.exe was not found.'
  }
  $taskKillOutput = @(& $taskKillPath /PID $Process.Id /T /F 2>&1)
  try {
    $Process.WaitForExit(5000)
    $Process.Refresh()
  } catch {
    # The explicit process-state check below remains authoritative.
  }
  if (-not $Process.HasExited) {
    throw "The tracked process tree did not stop. PID=$($Process.Id). $($taskKillOutput -join ' ')"
  }
  return $true
}

function Test-TrackedLocalServer {
  param($Item)

  $itemId = [string]$Item.id
  if (-not $script:serverProcesses.ContainsKey($itemId)) {
    return $false
  }

  try {
    $process = $script:serverProcesses[$itemId]
    return $null -ne $process -and -not $process.HasExited
  } catch {
    return $false
  }
}

function Stop-TrackedLocalServer {
  param(
    $Item,
    [switch]$ConfirmForce,
    [switch]$AllowMissing
  )

  $itemId = [string]$Item.id
  if (-not $script:serverProcesses.ContainsKey($itemId)) {
    return [bool]$AllowMissing
  }

  $process = $script:serverProcesses[$itemId]
  try {
    if ($null -ne $process -and -not $process.HasExited) {
      if ($ConfirmForce) {
        $confirmation = [System.Windows.MessageBox]::Show(
          $script:window,
          "Workspace Widget will force-stop only the server process tree it started for '$($Item.name)' (PID $($process.Id)).`n`nUnsaved server work may be lost. Continue?",
          'Force-stop local server',
          [System.Windows.MessageBoxButton]::YesNo,
          [System.Windows.MessageBoxImage]::Warning,
          [System.Windows.MessageBoxResult]::No
        )
        if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) {
          Write-RuntimeLog "Tracked server stop canceled for '$itemId'. PID=$($process.Id)"
          return $false
        }
      }
      Stop-ProcessTree -Process $process | Out-Null
      Write-RuntimeLog "Stopped tracked server '$($Item.name)'. PID=$($process.Id)"
    }
    [void]$script:serverProcesses.Remove($itemId)
    return $true
  } catch {
    Write-RuntimeLog "Tracked server stop failed for '$itemId'. $($_.Exception.Message)"
    return $false
  }
}

function Queue-NodeStart {
  param(
    $Item,
    [bool]$OpenWhenHealthy,
    [bool]$RestartTrackedProcess
  )

  if (-not (Test-HasNodeStartup -Item $Item)) {
    throw 'This shortcut does not have a Node start target.'
  }
  if (-not (Test-HasHealthCheck -Item $Item)) {
    throw 'This shortcut does not have a health URL.'
  }
  $healthUri = Get-ValidatedWebUri -Value ([string]$Item.health)
  if (-not (Test-LoopbackWebUri -Uri $healthUri)) {
    throw 'Automatic Node startup requires a loopback health URL.'
  }

  $itemId = [string]$Item.id
  $knownHealthy = $script:healthStates.ContainsKey($itemId) -and [bool]$script:healthStates[$itemId]
  if ($knownHealthy) {
    if ($OpenWhenHealthy) {
      Open-ItemTarget -Item $Item
    } else {
      Show-Toast -Message "$($Item.name) is already online"
    }
    return
  }

  $healthKnown = $script:healthStates.ContainsKey($itemId)
  $pending = [pscustomobject]@{
    item = $Item
    startupRequested = $false
    deadline = (Get-Date).AddSeconds(30)
    openWhenHealthy = $OpenWhenHealthy
    restartTrackedProcess = $RestartTrackedProcess
  }

  if ($healthKnown) {
    if ($RestartTrackedProcess) {
      if (-not (Stop-TrackedLocalServer -Item $Item -ConfirmForce -AllowMissing)) {
        Show-Toast -Message "Restart canceled for $($Item.name)"
        return
      }
    }
    Start-LocalServer -Item $Item | Out-Null
    $pending.startupRequested = $true
    $startVerb = if ($RestartTrackedProcess) { 'Restarting' } else { 'Starting' }
    Show-Toast -Message "$startVerb $($Item.name) with bundled Node"
  } else {
    $startPurpose = if ($RestartTrackedProcess) { 'restart' } else { 'start' }
    Show-Toast -Message "Checking $($Item.name) before $startPurpose"
  }

  $script:pendingOpen[$itemId] = $pending
  $script:startupPollTimer.Start()
  Start-HealthCheck
}

function Queue-NodeStartAndOpen {
  param($Item)

  Queue-NodeStart `
    -Item $Item `
    -OpenWhenHealthy $true `
    -RestartTrackedProcess $false
}

function Queue-NodeServerRecovery {
  param($Item)

  Queue-NodeStart `
    -Item $Item `
    -OpenWhenHealthy $false `
    -RestartTrackedProcess $true
}

function Invoke-ServerLifecycleMenuAction {
  param($Item)

  $itemId = [string]$Item.id
  if (Test-TrackedLocalServer -Item $Item) {
    if (-not (Stop-TrackedLocalServer -Item $Item -ConfirmForce)) {
      Show-Toast -Message "Stop canceled for $($Item.name)"
      return
    }
    if ($script:pendingOpen.ContainsKey($itemId)) {
      [void]$script:pendingOpen.Remove($itemId)
    }
    $script:healthStates[$itemId] = $false
    Show-Toast -Message "Stopped $($Item.name)"
    Start-HealthCheck
    return
  }

  Queue-NodeServerRecovery -Item $Item
}

function Update-ServerRecoveryMenuItem {
  param($MenuItem)

  if ($null -eq $MenuItem -or $null -eq $MenuItem.Tag) {
    return
  }

  $item = $MenuItem.Tag
  $itemId = [string]$item.id
  if (Test-TrackedLocalServer -Item $item) {
    $MenuItem.Header = 'Stop server...'
    $MenuItem.ToolTip = 'Force-stops only the process tree started and tracked by this Widget. Confirmation is required.'
    $MenuItem.IsEnabled = $true
    return
  }

  $healthKnown = $script:healthStates.ContainsKey($itemId)
  $healthy = $healthKnown -and [bool]$script:healthStates[$itemId]
  if ($healthy) {
    $MenuItem.Header = 'Server is online'
    $MenuItem.ToolTip = 'The configured health endpoint is responding.'
    $MenuItem.IsEnabled = $false
    return
  }

  $MenuItem.Header = if ($healthKnown) { 'Restart server' } else { 'Check and restart server' }
  $MenuItem.ToolTip = 'Runs the trusted Node start target and waits for the health endpoint.'
  $MenuItem.IsEnabled = $true
}

function Launch-Item {
  param($Item)

  try {
    $target = [string]$Item.target
    if (
      $target -match '^https?://' -and
      -not [string]::IsNullOrWhiteSpace([string]$Item.health) -and
      (Test-HasNodeStartup -Item $Item)
    ) {
      Queue-NodeStartAndOpen -Item $Item
      return
    }
    Open-ItemTarget -Item $Item
  } catch {
    [System.Windows.MessageBox]::Show(
      $script:window,
      $_.Exception.Message,
      'Workspace could not open this item',
      [System.Windows.MessageBoxButton]::OK,
      [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
  }
}

function New-ContextMenuItem {
  param([string]$Header)
  $menuItem = [System.Windows.Controls.MenuItem]::new()
  $menuItem.Header = $Header
  $menuItem.Foreground = Convert-ToBrush '#FFF6F9FF'
  $menuItem.Background = Convert-ToBrush '#FF0F203B'
  $menuItem.Padding = [System.Windows.Thickness]::new(14, 7, 20, 7)
  $menuItem.MinWidth = 188
  $menuItem.FocusVisualStyle = $null
  $menuItem.IsTabStop = $false
  $menuItem.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  TargetType="{x:Type MenuItem}">
  <Border
    x:Name="Root"
    Background="{TemplateBinding Background}"
    Padding="{TemplateBinding Padding}"
    CornerRadius="5">
    <ContentPresenter
      ContentSource="Header"
      RecognizesAccessKey="True"
      HorizontalAlignment="Left"
      VerticalAlignment="Center" />
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsHighlighted" Value="True">
      <Setter TargetName="Root" Property="Background" Value="#FF174A78" />
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter Property="Opacity" Value="0.45" />
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@)
  return $menuItem
}

function Get-YouTubeVideoId {
  param([string]$Source)

  if ([string]::IsNullOrWhiteSpace($Source)) {
    return $null
  }
  $match = [regex]::Match(
    $Source.Trim(),
    '(?i)(?:youtu\.be/|youtube(?:-nocookie)?\.com/(?:watch\?(?:[^#]*&)?v=|embed/|shorts/))(?<id>[A-Za-z0-9_-]{11})'
  )
  if ($match.Success) {
    return $match.Groups['id'].Value
  }
  return $null
}

function Get-ValidatedWebUri {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $candidate = $null
  if (-not [uri]::TryCreate(
      $Value.Trim(),
      [System.UriKind]::Absolute,
      [ref]$candidate
    )) {
    return $null
  }
  if (
    $candidate.Scheme -notin @('http', 'https') -or
    [string]::IsNullOrWhiteSpace($candidate.Host) -or
    -not [string]::IsNullOrWhiteSpace($candidate.UserInfo)
  ) {
    return $null
  }
  return $candidate
}

function Test-LoopbackWebUri {
  param(
    [Parameter(Mandatory = $true)]
    [uri]$Uri
  )

  return (
    $Uri.IsLoopback -or
    [string]::Equals(
      $Uri.DnsSafeHost,
      'localhost',
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $Uri.DnsSafeHost.EndsWith(
      '.localhost',
      [System.StringComparison]::OrdinalIgnoreCase
    )
  )
}

function Get-ValidatedLocalMediaInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [ValidateSet('image', 'gif', 'video')]
    [string]$Kind
  )

  $resolved = [System.IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($Path)
  )
  if (
    -not [System.IO.Path]::IsPathRooted($resolved) -or
    $resolved.StartsWith('\\', [System.StringComparison]::Ordinal) -or
    -not (Test-Path -LiteralPath $resolved -PathType Leaf)
  ) {
    throw 'Local media must be an existing file on a local drive.'
  }
  $file = Get-Item -LiteralPath $resolved
  $maximumBytes = if ($Kind -eq 'video') {
    $script:maximumLocalVideoBytes
  } else {
    $script:maximumLocalImageBytes
  }
  if ($file.Length -gt $maximumBytes) {
    throw "Local $Kind media exceeds the supported file-size limit."
  }
  if ($Kind -eq 'video') {
    return [pscustomobject]@{
      path = $resolved
      byteLength = [long]$file.Length
      frameCount = 0
      aggregatePixels = 0
    }
  }

  $stream = [System.IO.File]::Open(
    $resolved,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try {
    $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
      $stream,
      [System.Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation,
      [System.Windows.Media.Imaging.BitmapCacheOption]::None
    )
    $frames = @($decoder.Frames)
    if ($frames.Count -eq 0) {
      throw 'The image contains no readable frames.'
    }
    if ($Kind -eq 'image' -and $frames.Count -gt 32) {
      throw 'Static image containers are limited to 32 embedded frames.'
    }
    if ($Kind -eq 'gif' -and $frames.Count -gt $script:maximumGifFrames) {
      throw "GIF media is limited to $($script:maximumGifFrames) frames."
    }
    $aggregatePixels = [long]0
    foreach ($frame in $frames) {
      $pixels = [long]$frame.PixelWidth * [long]$frame.PixelHeight
      if (
        $frame.PixelWidth -gt 8192 -or
        $frame.PixelHeight -gt 8192 -or
        $pixels -gt 32000000
      ) {
        throw 'Image dimensions exceed 8192 px per side or 32 megapixels.'
      }
      $aggregatePixels += $pixels
      if ($aggregatePixels -gt $script:maximumGifAggregatePixels) {
        throw 'Animated image frame dimensions exceed the supported memory budget.'
      }
    }
    return [pscustomobject]@{
      path = $resolved
      byteLength = [long]$file.Length
      frameCount = $frames.Count
      aggregatePixels = $aggregatePixels
    }
  } finally {
    $stream.Dispose()
  }
}

function Resolve-MediaKind {
  param(
    [string]$Source,
    [string]$ConfiguredKind = 'auto'
  )

  if ([string]::IsNullOrWhiteSpace($Source)) {
    return 'none'
  }
  $configured = if ([string]::IsNullOrWhiteSpace($ConfiguredKind)) {
    'auto'
  } else {
    $ConfiguredKind.Trim().ToLowerInvariant()
  }
  if ($configured -notin @('auto', 'image', 'gif', 'video', 'youtube')) {
    return 'unsupported'
  }
  if ($configured -ne 'auto') {
    return $configured
  }
  if (-not [string]::IsNullOrWhiteSpace((Get-YouTubeVideoId -Source $Source))) {
    return 'youtube'
  }

  try {
    $extension = [System.IO.Path]::GetExtension(([uri]$Source).AbsolutePath)
  } catch {
    $extension = [System.IO.Path]::GetExtension($Source)
  }
  switch ($extension.ToLowerInvariant()) {
    '.gif' { return 'gif' }
    { $_ -in @('.png', '.jpg', '.jpeg', '.bmp', '.ico') } { return 'image' }
    { $_ -in @('.mp4', '.m4v', '.wmv', '.avi', '.mov') } { return 'video' }
    default { return 'unsupported' }
  }
}

function Test-MediaSource {
  param(
    [string]$Source,
    [string]$ConfiguredKind = 'auto'
  )

  if ([string]::IsNullOrWhiteSpace($Source)) {
    return $true
  }
  $kind = Resolve-MediaKind -Source $Source -ConfiguredKind $ConfiguredKind
  if ($kind -eq 'unsupported' -or $kind -eq 'none') {
    return $false
  }
  if ($kind -eq 'youtube') {
    return -not [string]::IsNullOrWhiteSpace((Get-YouTubeVideoId -Source $Source))
  }
  if ($Source -match '^https://') {
    if ($kind -eq 'video') {
      return $false
    }
    try {
      return Test-PublicRemoteIconUri -Uri ([uri]$Source)
    } catch {
      return $false
    }
  }
  try {
    Get-ValidatedLocalMediaInfo -Path $Source -Kind $kind | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-Sha256Hex {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes
  )

  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (
      [BitConverter]::ToString($algorithm.ComputeHash($Bytes)) -replace '-', ''
    ).ToLowerInvariant()
  } finally {
    $algorithm.Dispose()
  }
}

function Get-SignedRemoteIconExpiry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source
  )

  if ($Source -notmatch '(?i)[?&]token=exp=(?<seconds>\d+)') {
    return $null
  }
  try {
    $epoch = [DateTimeOffset]::new(
      1970,
      1,
      1,
      0,
      0,
      0,
      [TimeSpan]::Zero
    )
    $expiresAt = $epoch.AddSeconds([long]$Matches.seconds)
    return [pscustomobject]@{
      expiresAt = $expiresAt
      expired = $expiresAt -le [DateTimeOffset]::UtcNow
      localText = $expiresAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
  } catch {
    return $null
  }
}

function Assert-ManagedCacheCapacity {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CacheRoot,
    [long]$AdditionalBytes
  )

  if ($AdditionalBytes -lt 0) {
    throw 'Managed-cache growth cannot be negative.'
  }
  $currentBytes = [long]0
  if (Test-Path -LiteralPath $CacheRoot -PathType Container) {
    $measurement = Get-ChildItem -LiteralPath $CacheRoot -File -ErrorAction Stop |
      Measure-Object -Property Length -Sum
    if ($null -ne $measurement.Sum) {
      $currentBytes = [long]$measurement.Sum
    }
  }
  if (($currentBytes + $AdditionalBytes) -gt $script:maximumManagedCacheBytes) {
    throw (
      'The managed media cache has reached its 128 MB safety limit. ' +
      'Close Workspace Widget and review the per-user IconCache or MediaCache before adding more media.'
    )
  }
}

function Save-NormalizedCustomIconBitmap {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Media.Imaging.BitmapSource]$Bitmap,
    [Parameter(Mandatory = $true)]
    [string]$CachePath,
    [int]$CanvasSize = 256,
    [int]$Inset = 16
  )

  $pixelCount = [long]$Bitmap.PixelWidth * [long]$Bitmap.PixelHeight
  if (
    $Bitmap.PixelWidth -gt 8192 -or
    $Bitmap.PixelHeight -gt 8192 -or
    $pixelCount -gt 32000000
  ) {
    throw 'The icon is too large. Use an image up to 8192 px per side and 32 megapixels.'
  }
  if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
    return $CachePath
  }
  Assert-ManagedCacheCapacity `
    -CacheRoot (Split-Path -Parent $CachePath) `
    -AdditionalBytes 2MB

  $available = [math]::Max(1, $CanvasSize - ($Inset * 2))
  $scale = [math]::Min(
    $available / [double]$Bitmap.PixelWidth,
    $available / [double]$Bitmap.PixelHeight
  )
  $drawWidth = [math]::Max(1, [double]$Bitmap.PixelWidth * $scale)
  $drawHeight = [math]::Max(1, [double]$Bitmap.PixelHeight * $scale)
  $drawLeft = ($CanvasSize - $drawWidth) / 2.0
  $drawTop = ($CanvasSize - $drawHeight) / 2.0

  $visual = [System.Windows.Media.DrawingVisual]::new()
  [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
    $visual,
    [System.Windows.Media.BitmapScalingMode]::Fant
  )
  $drawing = $visual.RenderOpen()
  try {
    $drawing.DrawImage(
      $Bitmap,
      [System.Windows.Rect]::new($drawLeft, $drawTop, $drawWidth, $drawHeight)
    )
  } finally {
    $drawing.Close()
  }
  $rendered = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
    $CanvasSize,
    $CanvasSize,
    96,
    96,
    [System.Windows.Media.PixelFormats]::Pbgra32
  )
  $rendered.Render($visual)
  $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
  $encoder.Frames.Add(
    [System.Windows.Media.Imaging.BitmapFrame]::Create($rendered)
  )
  $stream = [System.IO.FileStream]::new(
    $CachePath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
  )
  try {
    $encoder.Save($stream)
  } finally {
    $stream.Dispose()
  }
  return $CachePath
}

function Test-ManagedClipboardIconPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  try {
    $cacheRoot = [System.IO.Path]::GetFullPath(
      (Join-Path $runtimeRoot 'IconCache')
    )
    $resolved = [System.IO.Path]::GetFullPath($Path)
    return (
      $resolved.StartsWith(
        $cacheRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
      ) -and
      [System.IO.Path]::GetFileName($resolved) -match
        '^clipboard-[0-9a-f]{64}-card\.png$'
    )
  } catch {
    return $false
  }
}

function Save-ClipboardCustomIconAsset {
  $bitmap = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      if (-not [System.Windows.Clipboard]::ContainsImage()) {
        throw 'The clipboard does not contain an image.'
      }
      $bitmap = [System.Windows.Clipboard]::GetImage()
      break
    } catch {
      if ($attempt -eq 3 -or $_.Exception.Message -match 'does not contain') {
        throw
      }
      Start-Sleep -Milliseconds 60
    }
  }
  if ($null -eq $bitmap) {
    throw 'The clipboard image could not be read.'
  }

  $pixelCount = [long]$bitmap.PixelWidth * [long]$bitmap.PixelHeight
  if (
    $bitmap.PixelWidth -gt 8192 -or
    $bitmap.PixelHeight -gt 8192 -or
    $pixelCount -gt 32000000
  ) {
    throw 'The clipboard image is too large. Use an image up to 8192 px per side and 32 megapixels.'
  }

  $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
  $encoder.Frames.Add(
    [System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap)
  )
  $memory = [System.IO.MemoryStream]::new()
  try {
    $encoder.Save($memory)
    if ($memory.Length -gt 10485760) {
      throw 'The clipboard image is larger than the 10 MB PNG limit.'
    }
    $bytes = $memory.ToArray()
  } finally {
    $memory.Dispose()
  }

  $cacheRoot = Join-Path $runtimeRoot 'IconCache'
  if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
  }
  $hash = Get-Sha256Hex -Bytes $bytes
  $cachePath = Join-Path $cacheRoot ("clipboard-$hash-card.png")
  if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    Save-NormalizedCustomIconBitmap `
      -Bitmap $bitmap `
      -CachePath $cachePath | Out-Null
  }
  $cachedItem = Get-Item -LiteralPath $cachePath
  return [pscustomobject]@{
    cachePath = $cachePath
    width = [int]$bitmap.PixelWidth
    height = [int]$bitmap.PixelHeight
    byteLength = [long]$cachedItem.Length
  }
}

function Test-PublicRemoteIconAddress {
  param(
    [Parameter(Mandatory = $true)]
    [System.Net.IPAddress]$Address
  )

  if ([System.Net.IPAddress]::IsLoopback($Address)) {
    return $false
  }
  if (
    $Address.AddressFamily -eq
    [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and
    $Address.IsIPv4MappedToIPv6
  ) {
    return Test-PublicRemoteIconAddress -Address $Address.MapToIPv4()
  }
  $bytes = $Address.GetAddressBytes()
  if (
    $Address.AddressFamily -eq
    [System.Net.Sockets.AddressFamily]::InterNetwork
  ) {
    return -not (
      $bytes[0] -eq 0 -or
      $bytes[0] -eq 10 -or
      ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) -or
      $bytes[0] -eq 127 -or
      ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
      ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
      (
        $bytes[0] -eq 192 -and
        $bytes[1] -eq 0 -and
        $bytes[2] -in @(0, 2)
      ) -or
      ($bytes[0] -eq 192 -and $bytes[1] -eq 88 -and $bytes[2] -eq 99) -or
      ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
      (
        $bytes[0] -eq 198 -and
        (
          $bytes[1] -in @(18, 19) -or
          ($bytes[1] -eq 51 -and $bytes[2] -eq 100)
        )
      ) -or
      ($bytes[0] -eq 203 -and $bytes[1] -eq 0 -and $bytes[2] -eq 113) -or
      $bytes[0] -ge 224
    )
  }
  if (
    $Address.AddressFamily -eq
    [System.Net.Sockets.AddressFamily]::InterNetworkV6
  ) {
    if (
      ($bytes[0] -band 0xE0) -ne 0x20 -or
      $Address.IsIPv6LinkLocal -or
      $Address.IsIPv6SiteLocal -or
      $Address.IsIPv6Multicast
    ) {
      return $false
    }
    return -not (
      (
        $bytes[0] -eq 0x20 -and
        $bytes[1] -eq 0x01 -and
        $bytes[2] -le 0x01
      ) -or
      (
        $bytes[0] -eq 0x20 -and
        $bytes[1] -eq 0x01 -and
        $bytes[2] -eq 0x0D -and
        $bytes[3] -eq 0xB8
      ) -or
      ($bytes[0] -eq 0x20 -and $bytes[1] -eq 0x02) -or
      ($bytes[0] -eq 0x3F -and $bytes[1] -eq 0xFE) -or
      (
        $bytes[0] -eq 0x3F -and
        $bytes[1] -eq 0xFF -and
        ($bytes[2] -band 0xF0) -eq 0
      )
    )
  }
  return $false
}

function Select-PublicRemoteIconAddresses {
  param(
    [Parameter(Mandatory = $true)]
    [System.Net.IPAddress[]]$Addresses,
    [ValidateRange(1, 8)]
    [int]$MaximumCount = 4
  )

  if (
    $Addresses.Count -eq 0 -or
    @(
      $Addresses |
        Where-Object { -not (Test-PublicRemoteIconAddress -Address $_) }
    ).Count -gt 0
  ) {
    return @()
  }

  $ordered = @(
    $Addresses |
      Sort-Object {
        if (
          $_.AddressFamily -eq
          [System.Net.Sockets.AddressFamily]::InterNetwork
        ) {
          0
        } else {
          1
        }
      }
  )
  $selected = [System.Collections.Generic.List[System.Net.IPAddress]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($address in $ordered) {
    if ($seen.Add($address.ToString())) {
      $selected.Add($address)
    }
    if ($selected.Count -ge $MaximumCount) {
      break
    }
  }
  return @($selected.ToArray())
}

function Get-RemoteAssetRemainingMilliseconds {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$DeadlineUtc
  )

  $remaining = [long][Math]::Floor(
    ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
  )
  if ($remaining -lt 1) {
    throw 'The remote asset request timed out.'
  }
  return [int][Math]::Min($remaining, 60000)
}

function Resolve-PublicRemoteIconAddresses {
  param(
    [Parameter(Mandatory = $true)]
    [uri]$Uri,
    [datetime]$DeadlineUtc = ([DateTime]::UtcNow.AddSeconds(5)),
    [switch]$ThrowOnFailure
  )

  if (
    $Uri.Scheme -ne 'https' -or
    $Uri.AbsoluteUri.Length -gt 2048 -or
    -not [string]::IsNullOrWhiteSpace($Uri.UserInfo) -or
    [string]::IsNullOrWhiteSpace($Uri.IdnHost)
  ) {
    if ($ThrowOnFailure) {
      throw 'The remote asset URL must be public HTTPS without user info.'
    }
    return @()
  }
  try {
    $remaining = Get-RemoteAssetRemainingMilliseconds `
      -DeadlineUtc $DeadlineUtc
    $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($Uri.IdnHost)
    if (-not $dnsTask.Wait($remaining)) {
      throw 'The remote asset DNS lookup timed out.'
    }
    $addresses = @($dnsTask.GetAwaiter().GetResult())
    $selected = @(
      Select-PublicRemoteIconAddresses `
        -Addresses $addresses `
        -MaximumCount 4
    )
    if ($selected.Count -eq 0) {
      throw 'The remote asset URL must resolve only to public IP addresses.'
    }
    return $selected
  } catch {
    if ($ThrowOnFailure) {
      throw
    }
    return @()
  }
}

function Test-PublicRemoteIconUri {
  param(
    [Parameter(Mandatory = $true)]
    [uri]$Uri
  )

  return @(
    Resolve-PublicRemoteIconAddresses -Uri $Uri
  ).Count -gt 0
}

function Invoke-PinnedRemoteAssetRequest {
  param(
    [Parameter(Mandatory = $true)]
    [uri]$Uri,
    [Parameter(Mandatory = $true)]
    [long]$MaximumBytes,
    [Parameter(Mandatory = $true)]
    [datetime]$DeadlineUtc
  )

  $addresses = @(
    Resolve-PublicRemoteIconAddresses `
      -Uri $Uri `
      -DeadlineUtc $DeadlineUtc `
      -ThrowOnFailure
  )
  $lastError = $null
  foreach ($address in $addresses) {
    try {
      $remaining = Get-RemoteAssetRemainingMilliseconds `
        -DeadlineUtc $DeadlineUtc
      if ($remaining -lt 1000) {
        throw 'The remote asset request timed out.'
      }
      return [WorkspaceWidgetPinnedHttpsClient]::Get(
        $Uri,
        $address,
        $MaximumBytes,
        [Math]::Min(2000, $remaining),
        $remaining
      )
    } catch {
      $lastError = $_.Exception
    }
  }
  if ($null -eq $lastError) {
    throw 'The pinned HTTPS request could not select an address.'
  }
  throw "The pinned HTTPS request failed. $($lastError.Message)"
}

function Test-SafeSvgIcon {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes
  )

  try {
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 2097152
    $stream = [System.IO.MemoryStream]::new($Bytes, $false)
    try {
      $reader = [System.Xml.XmlReader]::Create($stream, $settings)
      try {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
      } finally {
        $reader.Dispose()
      }
    } finally {
      $stream.Dispose()
    }
    if (
      $null -eq $document.DocumentElement -or
      $document.DocumentElement.LocalName -ine 'svg'
    ) {
      throw 'The document root is not SVG.'
    }
    $blockedElements = @(
      'script',
      'foreignobject',
      'iframe',
      'object',
      'embed',
      'audio',
      'video',
      'style'
    )
    foreach ($element in @($document.SelectNodes('//*'))) {
      if ($element.LocalName.ToLowerInvariant() -in $blockedElements) {
        throw "SVG element '$($element.LocalName)' is not allowed."
      }
      foreach ($attribute in @($element.Attributes)) {
        if (
          $attribute.Name -eq 'xmlns' -or
          $attribute.Prefix -eq 'xmlns'
        ) {
          continue
        }
        $name = $attribute.LocalName.ToLowerInvariant()
        $value = ([string]$attribute.Value).Trim()
        if ($name.StartsWith('on')) {
          throw "SVG event attribute '$($attribute.Name)' is not allowed."
        }
        if (
          $name -in @('href', 'src') -and
          -not [string]::IsNullOrWhiteSpace($value) -and
          -not $value.StartsWith('#')
        ) {
          throw "External SVG reference '$($attribute.Name)' is not allowed."
        }
        if (
          $value -match '(?i)javascript:|data:|https?:|file:|url\s*\('
        ) {
          throw 'Active or external SVG content is not allowed.'
        }
      }
    }
    return [pscustomobject]@{
      success = $true
      error = $null
    }
  } catch {
    return [pscustomobject]@{
      success = $false
      error = $_.Exception.Message
    }
  }
}

function Get-RemoteCustomIconAsset {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [long]$MaximumBytes = 2097152,
    [string]$CacheDirectoryName = 'IconCache',
    [string]$AssetLabel = 'Custom icon',
    [switch]$RasterOnly,
    [switch]$SkipCardCopy
  )

  if ($MaximumBytes -lt 1 -or $MaximumBytes -gt 67108864) {
    throw 'Remote asset size limit must be between 1 byte and 64 MB.'
  }
  $maximumBytes = [long]$MaximumBytes
  $maximumSizeLabel = if (($maximumBytes % 1MB) -eq 0) {
    '{0} MB' -f ([long]($maximumBytes / 1MB))
  } else {
    '{0} bytes' -f $maximumBytes
  }
  try {
    $currentUri = [uri]$Source
  } catch {
    throw "$AssetLabel URL is not valid."
  }
  $requestDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
  $response = $null
  for ($redirect = 0; $redirect -le 3; $redirect++) {
    try {
      $response = Invoke-PinnedRemoteAssetRequest `
        -Uri $currentUri `
        -MaximumBytes $maximumBytes `
        -DeadlineUtc $requestDeadlineUtc
    } catch {
      if (
        $_.Exception.Message -match
        'The remote asset exceeds its size limit\.'
      ) {
        throw "$AssetLabel is larger than the $maximumSizeLabel limit."
      }
      throw
    }
    $statusCode = [int]$response.StatusCode
    if ($statusCode -ge 300 -and $statusCode -lt 400) {
      if (-not $response.Headers.ContainsKey('Location')) {
        throw "$AssetLabel redirect did not include a destination."
      }
      $locationText = [string]$response.Headers['Location']
      try {
        $location = [uri]::new(
          $locationText,
          [System.UriKind]::RelativeOrAbsolute
        )
      } catch {
        throw "$AssetLabel redirect destination is invalid."
      }
      $currentUri = if ($location.IsAbsoluteUri) {
        $location
      } else {
        [uri]::new($currentUri, $location)
      }
      $response = $null
      continue
    }
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
      throw "$AssetLabel server returned HTTP $statusCode."
    }
    break
  }
  if ($null -eq $response) {
    throw "$AssetLabel redirected too many times."
  }
  $contentType = if ($response.Headers.ContainsKey('Content-Type')) {
    (
      ([string]$response.Headers['Content-Type'] -split ';', 2)[0]
    ).Trim().ToLowerInvariant()
  } else {
    ''
  }
    $typeMap = @{
      'image/svg+xml' = '.svg'
      'image/png' = '.png'
      'image/jpeg' = '.jpg'
      'image/gif' = '.gif'
      'image/bmp' = '.bmp'
      'image/x-icon' = '.ico'
      'image/vnd.microsoft.icon' = '.ico'
    }
    if (-not $typeMap.ContainsKey($contentType)) {
      throw "$AssetLabel response type '$contentType' is not supported."
    }
    if (
      $RasterOnly -and
      $contentType -in @('image/svg+xml', 'image/gif')
    ) {
      throw "$AssetLabel must be a static raster image."
    }
    $bytes = [byte[]]$response.Body
    if ($bytes.Length -eq 0) {
      throw "$AssetLabel response was empty."
    }
    $rasterFrame = $null
    if ($contentType -eq 'image/svg+xml') {
      $svgCheck = Test-SafeSvgIcon -Bytes $bytes
      if (-not $svgCheck.success) {
        throw "SVG safety check failed. $($svgCheck.error)"
      }
    } else {
      $stream = [System.IO.MemoryStream]::new($bytes, $false)
      try {
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
          $stream,
          [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
          [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        if ($decoder.Frames.Count -eq 0) {
          throw 'Custom icon did not contain a readable image frame.'
        }
        $rasterFrame = $decoder.Frames[0]
        $pixelCount = (
          [long]$rasterFrame.PixelWidth *
          [long]$rasterFrame.PixelHeight
        )
        if (
          $rasterFrame.PixelWidth -gt 8192 -or
          $rasterFrame.PixelHeight -gt 8192 -or
          $pixelCount -gt 32000000
        ) {
          throw 'Custom icon dimensions exceed 8192 px per side or 32 megapixels.'
        }
        $rasterFrame.Freeze()
      } finally {
        $stream.Dispose()
      }
    }
    $cacheRoot = Join-Path $runtimeRoot $CacheDirectoryName
    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
      New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    }
    $hashInput = [System.Text.Encoding]::UTF8.GetBytes(
      $currentUri.AbsoluteUri + ':' + (Get-Sha256Hex -Bytes $bytes)
    )
    $cacheKey = Get-Sha256Hex -Bytes $hashInput
    $extension = [string]$typeMap[$contentType]
    $sourcePath = Join-Path $cacheRoot ($cacheKey + $extension)
    $expectedCacheGrowth = if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
      [long]0
    } else {
      [long]$bytes.Length
    }
    if ($extension -eq '.svg') {
      $expectedPreviewPath = Join-Path $cacheRoot ($cacheKey + '.html')
      if (-not (Test-Path -LiteralPath $expectedPreviewPath -PathType Leaf)) {
        $expectedCacheGrowth += ([long]$bytes.Length * 2) + 4096
      }
    } elseif (-not $SkipCardCopy) {
      $expectedCardPath = Join-Path $cacheRoot ($cacheKey + '-card.png')
      if (-not (Test-Path -LiteralPath $expectedCardPath -PathType Leaf)) {
        $expectedCacheGrowth += 2MB
      }
    }
    Assert-ManagedCacheCapacity `
      -CacheRoot $cacheRoot `
      -AdditionalBytes $expectedCacheGrowth
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      [System.IO.File]::WriteAllBytes($sourcePath, $bytes)
    }
    $previewPath = $sourcePath
    $managedCachePath = $sourcePath
    if ($extension -eq '.svg') {
      $previewPath = Join-Path $cacheRoot ($cacheKey + '.html')
      if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) {
        $encodedSvg = [Convert]::ToBase64String($bytes)
        $html = @"
<!doctype html>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
<style>
html,body{width:100%;height:100%;margin:0;background:transparent;overflow:hidden}
body{display:grid;place-items:center}
img{display:block;width:88%;height:88%;object-fit:contain}
</style>
<img alt="" src="data:image/svg+xml;base64,$encodedSvg">
"@
        [System.IO.File]::WriteAllText(
          $previewPath,
          $html,
          [System.Text.UTF8Encoding]::new($false)
        )
      }
    } else {
      if ($SkipCardCopy) {
        $managedCachePath = $sourcePath
      } else {
        $managedCachePath = Join-Path $cacheRoot ($cacheKey + '-card.png')
        Save-NormalizedCustomIconBitmap `
          -Bitmap $rasterFrame `
          -CachePath $managedCachePath | Out-Null
      }
    }
  return [pscustomobject]@{
    success = $true
    sourceUrl = $Source
    finalUrl = $currentUri.AbsoluteUri
    contentType = $contentType
    sourcePath = $sourcePath
    previewPath = $previewPath
    cachePath = if ($extension -eq '.svg') { '' } else { $managedCachePath }
    isSvg = $extension -eq '.svg'
    byteLength = $bytes.Length
    cacheKey = $cacheKey
  }
}

function Get-RemoteRasterMediaSource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source
  )

  $asset = Get-RemoteCustomIconAsset `
    -Source $Source `
    -MaximumBytes 10485760 `
    -CacheDirectoryName 'MediaCache' `
    -AssetLabel 'Remote image' `
    -RasterOnly `
    -SkipCardCopy
  return [string]$asset.sourcePath
}

if ($NetworkBoundaryProbe) {
  function Test-PinnedResponseRejected {
    param(
      [Parameter(Mandatory = $true)]
      [string]$ResponseText,
      [long]$MaximumBytes = 2097152
    )

    try {
      [WorkspaceWidgetPinnedHttpsClient]::ParseResponseForProbe(
        [System.Text.Encoding]::ASCII.GetBytes($ResponseText),
        $MaximumBytes,
        1000
      ) | Out-Null
      return $false
    } catch {
      return $true
    }
  }

  $publicAddressStrings = @(
    '8.8.8.8',
    '1.1.1.1',
    '2606:4700:4700::1111',
    '2001:4860:4860::8888'
  )
  $blockedAddressStrings = @(
    '0.0.0.1',
    '10.0.0.1',
    '100.64.0.1',
    '127.0.0.1',
    '169.254.1.1',
    '172.16.0.1',
    '192.0.0.1',
    '192.0.2.1',
    '192.168.0.1',
    '198.18.0.1',
    '198.51.100.1',
    '203.0.113.1',
    '224.0.0.1',
    '::1',
    '::10.0.0.1',
    '64:ff9b::a00:1',
    '64:ff9b:1::a00:1',
    '100::1',
    '2001::1',
    '2001:2::1',
    '2001:db8::1',
    '2002::1',
    '3ffe::1',
    '3fff::1',
    'fc00::1',
    'fe80::1',
    'ff00::1'
  )
  $publicAddressChecks = @(
    $publicAddressStrings | ForEach-Object {
      Test-PublicRemoteIconAddress -Address (
        [System.Net.IPAddress]::Parse($_)
      )
    }
  )
  $blockedAddressChecks = @(
    $blockedAddressStrings | ForEach-Object {
      -not (Test-PublicRemoteIconAddress -Address (
          [System.Net.IPAddress]::Parse($_)
        ))
    }
  )
  $candidateAddresses = @(
    '8.8.8.8',
    '8.8.4.4',
    '1.1.1.1',
    '1.0.0.1',
    '9.9.9.9',
    '149.112.112.112',
    '208.67.222.222',
    '208.67.220.220'
  ) | ForEach-Object { [System.Net.IPAddress]::Parse($_) }
  $selectedAddresses = @(
    Select-PublicRemoteIconAddresses `
      -Addresses $candidateAddresses `
      -MaximumCount 4
  )
  $mixedAddresses = @(
    [System.Net.IPAddress]::Parse('8.8.8.8'),
    [System.Net.IPAddress]::Parse('127.0.0.1')
  )
  $mixedSelection = @(
    Select-PublicRemoteIconAddresses `
      -Addresses $mixedAddresses `
      -MaximumCount 4
  )

  $validResponse = (
    "HTTP/1.1 200 OK`r`n" +
    "Content-Type: image/png`r`n" +
    "Content-Length: 4`r`n`r`n" +
    'TEST'
  )
  $validParsed = [WorkspaceWidgetPinnedHttpsClient]::ParseResponseForProbe(
    [System.Text.Encoding]::ASCII.GetBytes($validResponse),
    16,
    1000
  )
  $conflictingFramingRejected = Test-PinnedResponseRejected -ResponseText (
    "HTTP/1.1 200 OK`r`n" +
    "Content-Type: image/png`r`n" +
    "Transfer-Encoding: chunked`r`n" +
    "Content-Length: 0`r`n`r`n" +
    "0`r`n`r`n"
  )
  $malformedHeaderRejected = Test-PinnedResponseRejected -ResponseText (
    "HTTP/1.1 200 OK`r`n" +
    "Bad Header`r`n`r`n"
  )
  $trailerLines = @(
    1..9 | ForEach-Object {
      "X-Probe-$($_): " + ('a' * 8000)
    }
  )
  $oversizedTrailerRejected = Test-PinnedResponseRejected -ResponseText (
    "HTTP/1.1 200 OK`r`n" +
    "Content-Type: image/png`r`n" +
    "Transfer-Encoding: chunked`r`n`r`n" +
    "0`r`n" +
    ($trailerLines -join "`r`n") +
    "`r`n`r`n"
  )
  $certificatePolicy = @{
    valid = [WorkspaceWidgetPinnedHttpsClient]::EvaluateCertificatePolicyForProbe(
      [System.Net.Security.SslPolicyErrors]::None,
      [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags[]]@()
    )
    nameMismatchRejected = -not (
      [WorkspaceWidgetPinnedHttpsClient]::EvaluateCertificatePolicyForProbe(
        [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch,
        [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags[]]@()
      )
    )
    revokedRejected = -not (
      [WorkspaceWidgetPinnedHttpsClient]::EvaluateCertificatePolicyForProbe(
        [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors,
        [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags[]]@(
          [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::Revoked
        )
      )
    )
    unavailableRevocationSoftFail = (
      [WorkspaceWidgetPinnedHttpsClient]::EvaluateCertificatePolicyForProbe(
        [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors,
        [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags[]]@(
          [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::RevocationStatusUnknown
        )
      )
    )
    combinedUnavailableRevocationSoftFail = (
      [WorkspaceWidgetPinnedHttpsClient]::EvaluateCertificatePolicyForProbe(
        [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors,
        [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags[]]@(
          (
            [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::RevocationStatusUnknown -bor
            [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::OfflineRevocation
          )
        )
      )
    )
  }
  $checks = [ordered]@{
    publicAddressesAccepted = @(
      $publicAddressChecks | Where-Object { -not $_ }
    ).Count -eq 0
    specialAddressesRejected = @(
      $blockedAddressChecks | Where-Object { -not $_ }
    ).Count -eq 0
    addressCandidatesBounded = $selectedAddresses.Count -eq 4
    mixedPrivateSetRejected = $mixedSelection.Count -eq 0
    validResponseParsed = (
      $validParsed.StatusCode -eq 200 -and
      $validParsed.Body.Length -eq 4
    )
    conflictingFramingRejected = $conflictingFramingRejected
    malformedHeaderRejected = $malformedHeaderRejected
    oversizedTrailerRejected = $oversizedTrailerRejected
    totalDeadlineEnforced = (
      [WorkspaceWidgetPinnedHttpsClient]::DeadlineExpiresForProbe(100)
    )
    tlsHandshakeDeadlineEnforced = (
      [WorkspaceWidgetPinnedHttpsClient]::TlsHandshakeTimesOutForProbe(1000)
    )
    certificatePolicy = @(
      $certificatePolicy.Values | Where-Object { -not $_ }
    ).Count -eq 0
  }
  $failedChecks = @(
    $checks.GetEnumerator() |
      Where-Object { -not $_.Value } |
      ForEach-Object { $_.Key }
  )
  [pscustomobject]@{
    success = $failedChecks.Count -eq 0
    failedChecks = $failedChecks
    checks = [pscustomobject]$checks
    publicAddressCount = $publicAddressStrings.Count
    blockedAddressCount = $blockedAddressStrings.Count
    selectedAddressCount = $selectedAddresses.Count
  } | ConvertTo-Json -Depth 5
  if ($failedChecks.Count -gt 0) {
    exit 1
  }
  exit 0
}

if (-not [string]::IsNullOrWhiteSpace($RemoteAssetProbeSource)) {
  try {
    $remoteAssetProbe = Get-RemoteCustomIconAsset `
      -Source $RemoteAssetProbeSource `
      -MaximumBytes 2097152 `
      -CacheDirectoryName 'RemoteAssetProbeCache' `
      -AssetLabel 'Remote asset probe' `
      -SkipCardCopy
    [pscustomobject]@{
      success = $true
      finalUrl = $remoteAssetProbe.finalUrl
      contentType = $remoteAssetProbe.contentType
      byteLength = $remoteAssetProbe.byteLength
      pinnedTransport = $true
    } | ConvertTo-Json -Depth 4
    exit 0
  } catch {
    [pscustomobject]@{
      success = $false
      error = $_.Exception.Message
      pinnedTransport = $true
    } | ConvertTo-Json -Depth 4
    exit 1
  }
}

function New-MediaBitmap {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [string]$Kind = 'image'
  )

  $resolvedSource = $Source
  if ($Source -notmatch '^https://' -and $Kind -ne 'youtube') {
    Get-ValidatedLocalMediaInfo -Path $Source -Kind 'image' | Out-Null
  }
  if ($Kind -eq 'youtube') {
    $videoId = Get-YouTubeVideoId -Source $Source
    if ([string]::IsNullOrWhiteSpace($videoId)) {
      throw 'The YouTube video identifier could not be resolved.'
    }
    $resolvedSource = "https://i.ytimg.com/vi/$videoId/hqdefault.jpg"
  }
  if ($resolvedSource -match '^https://') {
    $resolvedSource = Get-RemoteRasterMediaSource -Source $resolvedSource
  } else {
    $resolvedSource = [System.IO.Path]::GetFullPath($Source)
  }

  $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
  $bitmap.BeginInit()
  $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bitmap.CreateOptions = (
    [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile -bor
    [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
  )
  $bitmap.UriSource = [uri]$resolvedSource
  $bitmap.EndInit()
  $bitmap.Freeze()
  return $bitmap
}

function Get-GifFrames {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "GIF file not found: $Path"
  }
  $validated = Get-ValidatedLocalMediaInfo -Path $Path -Kind 'gif'
  $decoder = [System.Windows.Media.Imaging.GifBitmapDecoder]::new(
    [uri][System.IO.Path]::GetFullPath($Path),
    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  )
  $frames = @($decoder.Frames)
  if ($frames.Count -ne [int]$validated.frameCount) {
    throw 'GIF frame metadata changed while the file was being loaded.'
  }
  return $frames
}

function Get-ThemePalette {
  $appearance = $script:state.window.appearance
  $theme = ([string]$appearance.theme).Trim()
  switch ($theme.ToLowerInvariant()) {
    'neon' {
      return [pscustomobject]@{
        name = 'Neon'
        accent = '#FF30F2FF'
        panel = '#F0050812'
        card = '#E8111230'
        cardHover = '#F5230B4C'
        border = '#C33CFFF2'
        text = '#FFF7FEFF'
      }
    }
    'sakura' {
      return [pscustomobject]@{
        name = 'Sakura'
        accent = '#FFFF6FAE'
        panel = '#F01D1025'
        card = '#EA35172F'
        cardHover = '#F34A2147'
        border = '#B8FF9AC2'
        text = '#FFFFF6FB'
      }
    }
    'monochrome' {
      return [pscustomobject]@{
        name = 'Monochrome'
        accent = '#FFAFC7FF'
        panel = '#F016181D'
        card = '#EA23262D'
        cardHover = '#F2383D47'
        border = '#99D8DEE9'
        text = '#FFF7F8FA'
      }
    }
    'custom' {
      return [pscustomobject]@{
        name = 'Custom'
        accent = [string]$appearance.accentColor
        panel = [string]$appearance.panelColor
        card = [string]$appearance.cardColor
        cardHover = [string]$appearance.cardHoverColor
        border = [string]$appearance.accentColor
        text = [string]$appearance.textColor
      }
    }
    default {
      return [pscustomobject]@{
        name = 'Midnight'
        accent = '#FF3E8BFF'
        panel = '#EE09162B'
        card = '#E80F203B'
        cardHover = '#F2162F56'
        border = '#945C8AC6'
        text = '#FFF6F9FF'
      }
    }
  }
}

function Set-ColorAlpha {
  param(
    [string]$Color,
    [byte]$Alpha
  )

  try {
    $resolved = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    $resolved.A = $Alpha
    return $resolved.ToString()
  } catch {
    return '#B809162B'
  }
}

function Stop-BackgroundMedia {
  if ($null -ne $script:backgroundGifTimer) {
    $script:backgroundGifTimer.Stop()
  }
  $script:backgroundGifFrames = @()
  $script:backgroundGifIndex = 0
  try {
    $script:backgroundVideo.Stop()
  } catch {
  }
  $script:backgroundVideo.Source = $null
  $script:backgroundVideo.Visibility = [System.Windows.Visibility]::Collapsed
  $script:backgroundImage.Source = $null
  $script:backgroundImage.Visibility = [System.Windows.Visibility]::Collapsed
}

function Apply-BackgroundMedia {
  Stop-BackgroundMedia
  $appearance = $script:state.window.appearance
  $source = [string]$appearance.backgroundMedia
  $kind = Resolve-MediaKind `
    -Source $source `
    -ConfiguredKind ([string]$appearance.backgroundMediaKind)
  $mediaOpacity = [math]::Max(
    0.05,
    [math]::Min(1.0, [double]$appearance.backgroundMediaOpacity)
  )

  if ($kind -eq 'none') {
    $script:backgroundTint.Fill = Convert-ToBrush $script:themePalette.panel
    return
  }
  if (-not (Test-MediaSource -Source $source -ConfiguredKind $kind)) {
    $script:backgroundTint.Fill = Convert-ToBrush $script:themePalette.panel
    Write-RuntimeLog "Background media is unavailable or unsupported: '$source'."
    return
  }

  $script:backgroundTint.Fill = Convert-ToBrush (
    Set-ColorAlpha -Color $script:themePalette.panel -Alpha 184
  )
  try {
    switch ($kind) {
      'image' {
        $script:backgroundImage.Source = New-MediaBitmap -Source $source -Kind $kind
        $script:backgroundImage.Opacity = $mediaOpacity
        $script:backgroundImage.Visibility = [System.Windows.Visibility]::Visible
      }
      'youtube' {
        $script:backgroundImage.Source = New-MediaBitmap -Source $source -Kind $kind
        $script:backgroundImage.Opacity = $mediaOpacity
        $script:backgroundImage.Visibility = [System.Windows.Visibility]::Visible
        $script:backgroundImage.ToolTip = 'YouTube poster. Inline playback is available for shortcut hover media.'
      }
      'gif' {
        if ($source -match '^https://') {
          throw 'Animated GIF backgrounds must be local files.'
        }
        $script:backgroundGifFrames = @(Get-GifFrames -Path $source)
        if ($script:backgroundGifFrames.Count -eq 0) {
          throw 'The GIF contains no frames.'
        }
        $script:backgroundGifIndex = 0
        $script:backgroundImage.Source = $script:backgroundGifFrames[0]
        $script:backgroundImage.Opacity = $mediaOpacity
        $script:backgroundImage.Visibility = [System.Windows.Visibility]::Visible
        $script:backgroundGifTimer.Start()
      }
      'video' {
        $resolvedVideo = if ($source -match '^https://') {
          [uri]$source
        } else {
          [uri][System.IO.Path]::GetFullPath($source)
        }
        $script:backgroundVideo.Source = $resolvedVideo
        $script:backgroundVideo.IsMuted = [bool]$appearance.backgroundVideoMuted
        $script:backgroundVideo.Volume = if ($script:backgroundVideo.IsMuted) { 0 } else { 0.35 }
        $script:backgroundVideo.Opacity = $mediaOpacity
        $script:backgroundVideo.Visibility = [System.Windows.Visibility]::Visible
        $script:backgroundVideo.Play()
      }
    }
  } catch {
    Stop-BackgroundMedia
    $script:backgroundTint.Fill = Convert-ToBrush $script:themePalette.panel
    Write-RuntimeLog "Background media could not load. $($_.Exception.Message)"
  }
}

function Apply-Appearance {
  param([switch]$SkipRender)

  $script:themePalette = Get-ThemePalette
  $script:window.Background = [System.Windows.Media.Brushes]::Transparent
  $script:panelBorder.Background = Convert-ToBrush (
    Set-ColorAlpha -Color $script:themePalette.panel -Alpha 255
  )
  $script:panelBorder.BorderBrush = Convert-ToBrush (
    Set-ColorAlpha -Color $script:themePalette.border -Alpha 32
  )
  $script:headerTitleText.Foreground = Convert-ToBrush $script:themePalette.text
  $script:appearanceStatusText.Text = [string]$script:themePalette.name
  Apply-BackgroundMedia
  if (-not $SkipRender -and $null -ne $script:wrapPanel) {
    Render-Items
  }
}

function Show-AppearanceDialog {
  $appearance = $script:state.window.appearance
  $dialog = [System.Windows.Window]::new()
  $dialog.Title = 'Appearance & media'
  $dialog.Owner = $script:window
  $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
  $dialog.WindowStyle = [System.Windows.WindowStyle]::None
  $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $dialog.Width = 500
  $dialog.SizeToContent = [System.Windows.SizeToContent]::Height
  $dialog.AllowsTransparency = $true
  $dialog.Background = [System.Windows.Media.Brushes]::Transparent
  $dialog.ShowInTaskbar = $false

  $outer = [System.Windows.Controls.Border]::new()
  $outer.CornerRadius = [System.Windows.CornerRadius]::new(16)
  $outer.Background = Convert-ToBrush '#FF09162B'
  $outer.BorderBrush = Convert-ToBrush $script:themePalette.border
  $outer.BorderThickness = [System.Windows.Thickness]::new(1)
  $outer.Padding = [System.Windows.Thickness]::new(22)
  $dialog.Content = $outer

  $stack = [System.Windows.Controls.StackPanel]::new()
  $outer.Child = $stack
  $title = New-TextBlock -Text 'Appearance & media' -Size 20 -Weight 'SemiBold'
  $title.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $stack.Children.Add($title) | Out-Null
  $intro = New-TextBlock `
    -Text 'Use a preset or custom colors, then add a local image, GIF, video, or YouTube poster as the widget background.' `
    -Size 10 `
    -Color '#FFA9B9D1'
  $intro.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $intro.Margin = [System.Windows.Thickness]::new(0, 0, 0, 15)
  $stack.Children.Add($intro) | Out-Null

  $themeLabel = New-TextBlock -Text 'Theme' -Size 11 -Color '#FFA9B9D1'
  $themeLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $stack.Children.Add($themeLabel) | Out-Null
  $themeBox = [System.Windows.Controls.ComboBox]::new()
  foreach ($themeName in @('Midnight', 'Neon', 'Sakura', 'Monochrome', 'Custom')) {
    $themeBox.Items.Add($themeName) | Out-Null
  }
  $themeBox.SelectedItem = [string]$appearance.theme
  if ($themeBox.SelectedIndex -lt 0) {
    $themeBox.SelectedItem = 'Midnight'
  }
  $themeBox.Height = 34
  $themeBox.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
  $themeBox.Background = Convert-ToBrush '#FF0F203B'
  $themeBox.Foreground = Convert-ToBrush '#FFF6F9FF'
  $stack.Children.Add($themeBox) | Out-Null

  function Add-AppearanceTextField {
    param([string]$Label, [string]$Value, [string]$Help)

    $labelBlock = New-TextBlock -Text $Label -Size 11 -Color '#FFA9B9D1'
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
    $stack.Children.Add($labelBlock) | Out-Null
    $box = [System.Windows.Controls.TextBox]::new()
    $box.Text = $Value
    $box.Height = 34
    $box.Padding = [System.Windows.Thickness]::new(9, 6, 9, 6)
    $box.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $box.Background = Convert-ToBrush '#FF0F203B'
    $box.Foreground = Convert-ToBrush '#FFF6F9FF'
    $box.BorderBrush = Convert-ToBrush '#665C8AC6'
    $box.ToolTip = $Help
    $stack.Children.Add($box) | Out-Null
    return $box
  }

  $colors = [System.Windows.Controls.Grid]::new()
  $colors.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $colors.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $colors.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
  $stack.Children.Add($colors) | Out-Null

  function Add-ColorField {
    param(
      [Parameter(Mandatory = $true)]
      [System.Windows.Controls.Grid]$Grid,
      [string]$Label,
      [string]$Value,
      [int]$Column
    )

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = if ($Column -eq 0) {
      [System.Windows.Thickness]::new(0, 0, 6, 0)
    } else {
      [System.Windows.Thickness]::new(6, 0, 0, 0)
    }
    [System.Windows.Controls.Grid]::SetColumn($panel, $Column)
    $Grid.Children.Add($panel) | Out-Null
    $labelBlock = New-TextBlock -Text $Label -Size 10 -Color '#FFA9B9D1'
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $panel.Children.Add($labelBlock) | Out-Null
    $box = [System.Windows.Controls.TextBox]::new()
    $box.Text = $Value
    $box.Height = 32
    $box.Padding = [System.Windows.Thickness]::new(8, 5, 8, 5)
    $box.Background = Convert-ToBrush '#FF0F203B'
    $box.Foreground = Convert-ToBrush '#FFF6F9FF'
    $box.BorderBrush = Convert-ToBrush '#665C8AC6'
    $panel.Children.Add($box) | Out-Null
    return $box
  }

  $accentBox = Add-ColorField -Grid $colors -Label 'Accent ARGB' -Value ([string]$appearance.accentColor) -Column 0
  $panelColorBox = Add-ColorField -Grid $colors -Label 'Panel ARGB' -Value ([string]$appearance.panelColor) -Column 1

  $cardColors = [System.Windows.Controls.Grid]::new()
  $cardColors.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $cardColors.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $cardColors.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
  $stack.Children.Add($cardColors) | Out-Null
  $cardColorBox = Add-ColorField -Grid $cardColors -Label 'Shortcut card ARGB' -Value ([string]$appearance.cardColor) -Column 0
  $cardHoverColorBox = Add-ColorField -Grid $cardColors -Label 'Card hover ARGB' -Value ([string]$appearance.cardHoverColor) -Column 1
  $textColorBox = Add-AppearanceTextField `
    -Label 'Primary text ARGB' `
    -Value ([string]$appearance.textColor) `
    -Help 'Used by the Custom theme for primary labels and shortcut names.'

  $mediaLabel = New-TextBlock -Text 'Background media' -Size 11 -Color '#FFA9B9D1'
  $mediaLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $stack.Children.Add($mediaLabel) | Out-Null
  $mediaGrid = [System.Windows.Controls.Grid]::new()
  $mediaGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $browseColumn = [System.Windows.Controls.ColumnDefinition]::new()
  $browseColumn.Width = [System.Windows.GridLength]::Auto
  $mediaGrid.ColumnDefinitions.Add($browseColumn) | Out-Null
  $mediaGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
  $stack.Children.Add($mediaGrid) | Out-Null
  $backgroundBox = [System.Windows.Controls.TextBox]::new()
  $backgroundBox.Text = [string]$appearance.backgroundMedia
  $backgroundBox.Height = 34
  $backgroundBox.Padding = [System.Windows.Thickness]::new(9, 6, 9, 6)
  $backgroundBox.Background = Convert-ToBrush '#FF0F203B'
  $backgroundBox.Foreground = Convert-ToBrush '#FFF6F9FF'
  $backgroundBox.BorderBrush = Convert-ToBrush '#665C8AC6'
  $backgroundBox.ToolTip = 'Local image/GIF/video, public HTTPS image, or YouTube link.'
  $mediaGrid.Children.Add($backgroundBox) | Out-Null
  $browse = [System.Windows.Controls.Button]::new()
  $browse.Content = 'Browse...'
  $browse.Width = 82
  $browse.Height = 34
  $browse.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
  $browse.Background = Convert-ToBrush '#FF172A47'
  $browse.Foreground = Convert-ToBrush '#FFF6F9FF'
  $browse.BorderBrush = Convert-ToBrush '#665C8AC6'
  $browse.Template = New-ButtonTemplate
  [System.Windows.Controls.Grid]::SetColumn($browse, 1)
  $mediaGrid.Children.Add($browse) | Out-Null
  $browse.Add_Click({
      $picker = [Microsoft.Win32.OpenFileDialog]::new()
      $picker.Title = 'Choose Workspace background media'
      $picker.Filter = 'Supported media|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.mp4;*.m4v;*.wmv;*.avi;*.mov|Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif|Videos|*.mp4;*.m4v;*.wmv;*.avi;*.mov|All files|*.*'
      if ($picker.ShowDialog($dialog)) {
        $backgroundBox.Text = $picker.FileName
      }
    })

  $opacityRow = [System.Windows.Controls.Grid]::new()
  $opacityRow.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $opacityValueColumn = [System.Windows.Controls.ColumnDefinition]::new()
  $opacityValueColumn.Width = [System.Windows.GridLength]::Auto
  $opacityRow.ColumnDefinitions.Add($opacityValueColumn) | Out-Null
  $opacityRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
  $stack.Children.Add($opacityRow) | Out-Null
  $mediaOpacity = [System.Windows.Controls.Slider]::new()
  $mediaOpacity.Minimum = 0.05
  $mediaOpacity.Maximum = 1.0
  $mediaOpacity.SmallChange = 0.05
  $mediaOpacity.Value = [double]$appearance.backgroundMediaOpacity
  $mediaOpacity.ToolTip = 'Background media opacity'
  $opacityRow.Children.Add($mediaOpacity) | Out-Null
  $mediaOpacityText = New-TextBlock -Text ('{0:P0}' -f $mediaOpacity.Value) -Size 11
  $mediaOpacityText.Width = 48
  $mediaOpacityText.TextAlignment = [System.Windows.TextAlignment]::Right
  [System.Windows.Controls.Grid]::SetColumn($mediaOpacityText, 1)
  $opacityRow.Children.Add($mediaOpacityText) | Out-Null
  $mediaOpacity.Add_ValueChanged({
      $mediaOpacityText.Text = '{0:P0}' -f $mediaOpacity.Value
    })

  $muteBackground = [System.Windows.Controls.CheckBox]::new()
  $muteBackground.Content = 'Mute background video'
  $muteBackground.IsChecked = [bool]$appearance.backgroundVideoMuted
  $muteBackground.Foreground = Convert-ToBrush '#FFC6D2E5'
  $muteBackground.FontSize = 11
  $muteBackground.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
  $stack.Children.Add($muteBackground) | Out-Null

  $rights = New-TextBlock `
    -Text 'Only use media you trust and have permission to display. YouTube playback uses the privacy-enhanced embed domain when WebView2 is available.' `
    -Size 9 `
    -Color '#FF7D91AE'
  $rights.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $rights.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
  $stack.Children.Add($rights) | Out-Null

  $buttons = [System.Windows.Controls.StackPanel]::new()
  $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $stack.Children.Add($buttons) | Out-Null
  $clear = [System.Windows.Controls.Button]::new()
  $clear.Content = 'Clear media'
  $clear.Width = 92
  $clear.Height = 34
  $clear.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
  $clear.Background = Convert-ToBrush '#FF172A47'
  $clear.Foreground = Convert-ToBrush '#FFF6F9FF'
  $clear.BorderBrush = Convert-ToBrush '#665C8AC6'
  $clear.Template = New-ButtonTemplate
  $clear.Add_Click({ $backgroundBox.Text = '' })
  $buttons.Children.Add($clear) | Out-Null
  $cancel = [System.Windows.Controls.Button]::new()
  $cancel.Content = 'Cancel'
  $cancel.IsCancel = $true
  $cancel.Width = 82
  $cancel.Height = 34
  $cancel.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
  $cancel.Background = Convert-ToBrush '#FF172A47'
  $cancel.Foreground = Convert-ToBrush '#FFF6F9FF'
  $cancel.BorderBrush = Convert-ToBrush '#665C8AC6'
  $cancel.Template = New-ButtonTemplate
  $cancel.Add_Click({ $dialog.DialogResult = $false })
  $buttons.Children.Add($cancel) | Out-Null
  $apply = [System.Windows.Controls.Button]::new()
  $apply.Content = 'Apply'
  $apply.IsDefault = $true
  $apply.Width = 82
  $apply.Height = 34
  $apply.Background = Convert-ToBrush '#FF1F6FD0'
  $apply.Foreground = [System.Windows.Media.Brushes]::White
  $apply.BorderBrush = Convert-ToBrush '#FF3E8BFF'
  $apply.Template = New-ButtonTemplate
  $buttons.Children.Add($apply) | Out-Null

  $presetValues = @{
    Midnight = @('#FF3E8BFF', '#EE09162B', '#E80F203B', '#F2162F56', '#FFF6F9FF')
    Neon = @('#FF30F2FF', '#F0050812', '#E8111230', '#F5230B4C', '#FFF7FEFF')
    Sakura = @('#FFFF6FAE', '#F01D1025', '#EA35172F', '#F34A2147', '#FFFFF6FB')
    Monochrome = @('#FFAFC7FF', '#F016181D', '#EA23262D', '#F2383D47', '#FFF7F8FA')
  }
  $themeBox.Add_SelectionChanged({
      $selectedTheme = [string]$themeBox.SelectedItem
      if ($presetValues.ContainsKey($selectedTheme)) {
        $accentBox.Text = $presetValues[$selectedTheme][0]
        $panelColorBox.Text = $presetValues[$selectedTheme][1]
        $cardColorBox.Text = $presetValues[$selectedTheme][2]
        $cardHoverColorBox.Text = $presetValues[$selectedTheme][3]
        $textColorBox.Text = $presetValues[$selectedTheme][4]
      }
    })

  $apply.Add_Click({
      $selectedTheme = [string]$themeBox.SelectedItem
      $backgroundMedia = $backgroundBox.Text.Trim()
      try {
        Convert-ToBrush $accentBox.Text.Trim() | Out-Null
        Convert-ToBrush $panelColorBox.Text.Trim() | Out-Null
        Convert-ToBrush $cardColorBox.Text.Trim() | Out-Null
        Convert-ToBrush $cardHoverColorBox.Text.Trim() | Out-Null
        Convert-ToBrush $textColorBox.Text.Trim() | Out-Null
      } catch {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'All colors must be valid #AARRGGBB or named WPF colors.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }
      $backgroundKind = Resolve-MediaKind -Source $backgroundMedia -ConfiguredKind 'auto'
      if (
        -not [string]::IsNullOrWhiteSpace($backgroundMedia) -and
        -not (Test-MediaSource -Source $backgroundMedia -ConfiguredKind $backgroundKind)
      ) {
        [System.Windows.MessageBox]::Show(
          $dialog,
          'Background media must be a supported local file, public HTTPS image, or YouTube link.',
          'Workspace',
          [System.Windows.MessageBoxButton]::OK,
          [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
      }

      if ($selectedTheme -ne 'Custom' -and $presetValues.ContainsKey($selectedTheme)) {
        $actualColors = @(
          $accentBox.Text.Trim(),
          $panelColorBox.Text.Trim(),
          $cardColorBox.Text.Trim(),
          $cardHoverColorBox.Text.Trim(),
          $textColorBox.Text.Trim()
        )
        if ([string]::Join('|', $actualColors) -cne [string]::Join('|', $presetValues[$selectedTheme])) {
          $selectedTheme = 'Custom'
        }
      }
      $appearance.theme = $selectedTheme
      $appearance.accentColor = $accentBox.Text.Trim()
      $appearance.panelColor = $panelColorBox.Text.Trim()
      $appearance.cardColor = $cardColorBox.Text.Trim()
      $appearance.cardHoverColor = $cardHoverColorBox.Text.Trim()
      $appearance.textColor = $textColorBox.Text.Trim()
      $appearance.backgroundMedia = $backgroundMedia
      $appearance.backgroundMediaKind = $backgroundKind
      $appearance.backgroundMediaOpacity = [math]::Round([double]$mediaOpacity.Value, 2)
      $appearance.backgroundVideoMuted = [bool]$muteBackground.IsChecked
      Apply-Appearance
      Save-State
      $dialog.DialogResult = $true
    })

  $dialog.Add_MouseLeftButtonDown({
      param($sender, $eventArgs)
      if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        try {
          $dialog.DragMove()
        } catch {
        }
      }
    })
  return $dialog.ShowDialog()
}

function Get-YouTubeEmbedUri {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VideoId
  )

  if ($VideoId -notmatch '^[A-Za-z0-9_-]{11}$') {
    throw 'The YouTube video identifier is not valid.'
  }
  $origin = [uri]::EscapeDataString($script:youtubeEmbedOrigin)
  return [uri](
    "https://www.youtube-nocookie.com/embed/$VideoId" +
    "?autoplay=1&mute=1&controls=0&loop=1&playlist=$VideoId&playsinline=1" +
    "&origin=$origin&widget_referrer=$origin"
  )
}

function Start-YouTubeHoverNavigation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VideoId
  )

  $embedUri = Get-YouTubeEmbedUri -VideoId $VideoId
  $script:hoverPendingYouTubeVideoId = $VideoId
  if (
    $null -eq $script:hoverWebView -or
    $null -eq $script:hoverWebView.CoreWebView2
  ) {
    if ($null -ne $script:hoverWebView) {
      try {
        $script:hoverWebView.EnsureCoreWebView2Async() | Out-Null
      } catch {
      }
    }
    return $false
  }
  $headers = "Referer: $($script:youtubeEmbedReferrer)`r`n"
  $request = $script:hoverWebView.CoreWebView2.Environment.CreateWebResourceRequest(
    $embedUri.AbsoluteUri,
    'GET',
    $null,
    $headers
  )
  $script:hoverWebView.CoreWebView2.NavigateWithWebResourceRequest($request)
  $script:hoverPendingYouTubeVideoId = $null
  Write-RuntimeLog "YouTube hover navigation started with an identified WebView2 request. videoId=$VideoId"
  return $true
}

function Ensure-HoverWebView {
  if (-not $script:webView2Available) {
    return $false
  }
  if ($null -ne $script:hoverWebView) {
    return $true
  }

  try {
    $script:hoverWebView = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $script:hoverWebView.IsHitTestVisible = $false
    $script:hoverWebView.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $script:hoverWebView.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $creationProperties = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $creationProperties.UserDataFolder = Join-Path $runtimeRoot 'WebView2'
    $creationProperties.AdditionalBrowserArguments = '--disk-cache-size=33554432'
    $script:hoverWebView.CreationProperties = $creationProperties
    $script:hoverWebView.add_CoreWebView2InitializationCompleted({
        param($sender, $eventArgs)
        if (-not $eventArgs.IsSuccess) {
          $script:webView2LoadError = $eventArgs.InitializationException.Message
          Write-RuntimeLog "WebView2 initialization failed. $($script:webView2LoadError)"
          Show-HoverMediaFallback -Reason 'YouTube playback is unavailable'
          return
        }
        $script:hoverWebViewReady = $true
        $settings = $sender.CoreWebView2.Settings
        $settings.AreDefaultContextMenusEnabled = $false
        $settings.AreDevToolsEnabled = $false
        $settings.IsStatusBarEnabled = $false
        $settings.IsZoomControlEnabled = $false
        $settings.IsWebMessageEnabled = $false
        try {
          $settings.AreHostObjectsAllowed = $false
          $settings.IsPasswordAutosaveEnabled = $false
          $settings.IsGeneralAutofillEnabled = $false
        } catch {
          Write-RuntimeLog "Optional YouTube isolation settings are unavailable. $($_.Exception.Message)"
        }
        $sender.CoreWebView2.add_NewWindowRequested({
            param($core, $requestArgs)
            $requestArgs.Handled = $true
          })
        $sender.CoreWebView2.add_PermissionRequested({
            param($core, $permissionArgs)
            $permissionArgs.State = (
              [Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Deny
            )
            $permissionArgs.Handled = $true
          })
        $sender.CoreWebView2.add_DownloadStarting({
            param($core, $downloadArgs)
            $downloadArgs.Cancel = $true
          })
        foreach ($filter in @(
            'https://www.youtube-nocookie.com/*',
            'https://www.youtube.com/*',
            'https://youtube.com/*'
          )) {
          $sender.CoreWebView2.AddWebResourceRequestedFilter(
            $filter,
            [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All
          )
        }
        $sender.CoreWebView2.add_WebResourceRequested({
            param($core, $resourceArgs)
            try {
              $requestUri = [uri][string]$resourceArgs.Request.Uri
              if (
                $requestUri.Scheme -eq 'https' -and
                $requestUri.DnsSafeHost -in @(
                  'www.youtube-nocookie.com',
                  'www.youtube.com',
                  'youtube.com'
                )
              ) {
                $resourceArgs.Request.Headers.SetHeader(
                  'Referer',
                  $script:youtubeEmbedReferrer
                )
              }
            } catch {
            }
          })
        if (
          -not [string]::IsNullOrWhiteSpace(
            [string]$script:hoverPendingYouTubeVideoId
          )
        ) {
          Start-YouTubeHoverNavigation `
            -VideoId $script:hoverPendingYouTubeVideoId | Out-Null
        }
      })
    $script:hoverWebView.add_NavigationStarting({
        param($sender, $eventArgs)
        $allowed = $false
        try {
          $uri = [uri][string]$eventArgs.Uri
          $allowed = (
            $uri.AbsoluteUri -eq 'about:blank' -or
            (
              $uri.Scheme -eq 'https' -and
              $uri.DnsSafeHost -eq 'www.youtube-nocookie.com' -and
              $uri.Port -eq 443 -and
              $uri.AbsolutePath -match '^/embed/[A-Za-z0-9_-]{11}/?$'
            )
          )
        } catch {
          $allowed = $false
        }
        if (-not $allowed) {
          $eventArgs.Cancel = $true
        }
      })
    $script:hoverPreviewWebHost.Children.Add($script:hoverWebView) | Out-Null
    return $true
  } catch {
    $script:webView2LoadError = $_.Exception.Message
    Write-RuntimeLog "WebView2 control could not be created. $($script:webView2LoadError)"
    return $false
  }
}

function Stop-HoverMediaPreview {
  $script:hoverPendingYouTubeVideoId = $null
  if ($null -ne $script:hoverGifTimer) {
    $script:hoverGifTimer.Stop()
  }
  $script:hoverGifFrames = @()
  $script:hoverGifIndex = 0
  try {
    $script:hoverPreviewVideo.Stop()
  } catch {
  }
  $script:hoverPreviewVideo.Source = $null
  $script:hoverPreviewVideo.Visibility = [System.Windows.Visibility]::Collapsed
  $script:hoverPreviewImage.Source = $null
  $script:hoverPreviewImage.Visibility = [System.Windows.Visibility]::Collapsed
  $script:hoverPreviewWebHost.Visibility = [System.Windows.Visibility]::Collapsed
  if ($null -ne $script:hoverWebView) {
    try {
      $script:hoverWebView.Source = [uri]'about:blank'
    } catch {
    }
  }
  $script:hoverPreviewBorder.Visibility = [System.Windows.Visibility]::Collapsed
  $script:activeHoverMediaItemId = $null
  $script:activeHoverMediaItem = $null
}

function Show-HoverMediaFallback {
  param([string]$Reason = 'Media preview is unavailable')

  $item = $script:activeHoverMediaItem
  $script:hoverPendingYouTubeVideoId = $null
  if ($null -eq $item) {
    return
  }
  $source = [string]$item.hoverMedia
  try {
    if (
      (Resolve-MediaKind -Source $source -ConfiguredKind 'auto') -eq 'youtube'
    ) {
      $script:hoverPreviewImage.Source = New-MediaBitmap `
        -Source $source `
        -Kind 'youtube'
      $script:hoverPreviewImage.Visibility = [System.Windows.Visibility]::Visible
    }
  } catch {
    $script:hoverPreviewImage.Source = $null
  }
  try {
    $script:hoverPreviewVideo.Stop()
    $script:hoverPreviewVideo.Source = $null
  } catch {
  }
  try {
    if ($null -ne $script:hoverWebView) {
      $script:hoverWebView.Source = [uri]'about:blank'
    }
  } catch {
  }
  $script:hoverPreviewVideo.Visibility = [System.Windows.Visibility]::Collapsed
  $script:hoverPreviewWebHost.Visibility = [System.Windows.Visibility]::Collapsed
  $script:hoverPreviewLabel.Text = "$($item.name) · $Reason"
  $script:hoverPreviewBorder.Visibility = [System.Windows.Visibility]::Visible
}

function Start-HoverMediaPreview {
  param($Item)

  if (
    $script:minUiMode -or
    $null -eq $Item -or
    $Item.PSObject.Properties.Name -notcontains 'hoverMedia' -or
    [string]::IsNullOrWhiteSpace([string]$Item.hoverMedia)
  ) {
    return
  }
  Stop-HoverMediaPreview
  $source = [string]$Item.hoverMedia
  $kind = Resolve-MediaKind `
    -Source $source `
    -ConfiguredKind ([string]$Item.hoverMediaKind)
  if (-not (Test-MediaSource -Source $source -ConfiguredKind $kind)) {
    Write-RuntimeLog "Hover media is unavailable or unsupported for '$($Item.name)': '$source'."
    return
  }

  $script:activeHoverMediaItemId = [string]$Item.id
  $script:activeHoverMediaItem = $Item
  $script:hoverPreviewLabel.Text = [string]$Item.name
  $script:hoverPreviewBorder.BorderBrush = Convert-ToBrush $script:themePalette.accent
  try {
    switch ($kind) {
      'image' {
        $script:hoverPreviewImage.Source = New-MediaBitmap -Source $source -Kind $kind
        $script:hoverPreviewImage.Visibility = [System.Windows.Visibility]::Visible
      }
      'gif' {
        if ($source -match '^https://') {
          throw 'Animated GIF hover media must be a local file.'
        }
        $script:hoverGifFrames = @(Get-GifFrames -Path $source)
        if ($script:hoverGifFrames.Count -eq 0) {
          throw 'The GIF contains no frames.'
        }
        $script:hoverGifIndex = 0
        $script:hoverPreviewImage.Source = $script:hoverGifFrames[0]
        $script:hoverPreviewImage.Visibility = [System.Windows.Visibility]::Visible
        $script:hoverGifTimer.Start()
      }
      'video' {
        $script:hoverPreviewVideo.Source = if ($source -match '^https://') {
          [uri]$source
        } else {
          [uri][System.IO.Path]::GetFullPath($source)
        }
        $script:hoverPreviewVideo.IsMuted = if (
          $Item.PSObject.Properties.Name -contains 'hoverMediaMuted'
        ) {
          [bool]$Item.hoverMediaMuted
        } else {
          $true
        }
        $script:hoverPreviewVideo.Volume = if ($script:hoverPreviewVideo.IsMuted) { 0 } else { 0.35 }
        $script:hoverPreviewVideo.Visibility = [System.Windows.Visibility]::Visible
        $script:hoverPreviewVideo.Play()
      }
      'youtube' {
        $videoId = Get-YouTubeVideoId -Source $source
        if (Ensure-HoverWebView) {
          $script:hoverPreviewWebHost.Visibility = [System.Windows.Visibility]::Visible
          Start-YouTubeHoverNavigation -VideoId $videoId | Out-Null
        } else {
          $script:hoverPreviewImage.Source = New-MediaBitmap -Source $source -Kind 'youtube'
          $script:hoverPreviewImage.Visibility = [System.Windows.Visibility]::Visible
          $script:hoverPreviewLabel.Text = "$($Item.name) · install WebView2 for playback"
        }
      }
    }
    $script:hoverPreviewBorder.Visibility = [System.Windows.Visibility]::Visible
  } catch {
    Stop-HoverMediaPreview
    Write-RuntimeLog "Hover media could not load for '$($Item.name)'. $($_.Exception.Message)"
  }
}

function Get-CustomIconSource {
  param($Item)

  if (
    $Item.PSObject.Properties.Name -notcontains 'customIcon' -or
    [string]::IsNullOrWhiteSpace([string]$Item.customIcon)
  ) {
    return $null
  }
  $source = [string]$Item.customIcon
  $resolvedSource = $source
  if ($source -match '^https://') {
    if (
      $Item.PSObject.Properties.Name -notcontains 'customIconCache' -or
      [string]::IsNullOrWhiteSpace([string]$Item.customIconCache)
    ) {
      return $null
    }
    $resolvedSource = [string]$Item.customIconCache
  }
  if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
    return $null
  }
  try {
    if ([System.IO.Path]::GetExtension($resolvedSource) -ieq '.gif') {
      $frames = @(Get-GifFrames -Path $resolvedSource)
      if ($frames.Count -gt 0) {
        return $frames[0]
      }
      return $null
    }
    return New-MediaBitmap -Source $resolvedSource -Kind 'image'
  } catch {
    Write-RuntimeLog "Custom icon could not load for '$($Item.name)'. $($_.Exception.Message)"
    return $null
  }
}

function Set-LauncherCardHealthPresentation {
  param(
    $Item,
    [ValidateSet('Checking', 'Online', 'Offline', 'Unavailable')]
    [string]$State,
    [switch]$Announce
  )

  $itemId = [string]$Item.id
  if (-not $script:healthDots.ContainsKey($itemId)) {
    return
  }
  $dot = $script:healthDots[$itemId]
  $dot.Fill = Convert-ToBrush $(switch ($State) {
      'Online' { '#FF35DE8F' }
      'Checking' { '#FF7D91AE' }
      default { '#FFFF697D' }
    })
  $statusText = switch ($State) {
    'Offline' { 'Offline · click card to start with bundled Node' }
    default { $State }
  }
  $dot.ToolTip = $statusText
  [System.Windows.Automation.AutomationProperties]::SetName(
    $dot,
    "$($Item.name) status: $statusText"
  )
  [System.Windows.Automation.AutomationProperties]::SetLiveSetting(
    $dot,
    [System.Windows.Automation.AutomationLiveSetting]::Polite
  )

  $card = $dot.Tag
  if ($null -ne $card) {
    [System.Windows.Automation.AutomationProperties]::SetName(
      $card,
      "Open $($Item.name). Status: $statusText."
    )
    [System.Windows.Automation.AutomationProperties]::SetHelpText(
      $card,
      "Target: $($Item.target). Health status: $statusText."
    )
  }
  if ($Announce) {
    try {
      $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($dot)
      if ($null -eq $peer) {
        $peer = [System.Windows.Automation.Peers.FrameworkElementAutomationPeer]::new($dot)
      }
      $peer.RaiseAutomationEvent(
        [System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged
      )
    } catch {
      Write-RuntimeLog "Health accessibility announcement failed for '$($Item.name)'."
    }
  }
}

function New-LauncherCard {
  param($Item)

  $isMinUi = [bool]$script:minUiMode
  $card = [System.Windows.Controls.Border]::new()
  $card.Width = if ($isMinUi) { 62 } else { 158 }
  $card.Height = if ($isMinUi) { 62 } else { 138 }
  $card.Margin = if ($isMinUi) {
    [System.Windows.Thickness]::new(4)
  } else {
    [System.Windows.Thickness]::new(6)
  }
  $card.CornerRadius = [System.Windows.CornerRadius]::new($(if ($isMinUi) { 12 } else { 14 }))
  $card.Background = Convert-ToBrush $script:themePalette.card
  $card.BorderBrush = Convert-ToBrush (
    Set-ColorAlpha -Color $script:themePalette.border -Alpha 82
  )
  $card.BorderThickness = [System.Windows.Thickness]::new(1)
  $card.Padding = [System.Windows.Thickness]::new($(if ($isMinUi) { 8 } else { 12 }))
  $card.Cursor = [System.Windows.Input.Cursors]::Hand
  $card.Focusable = $true
  $card.Tag = $Item
  $card.Opacity = if ($Item.hidden) { 0.4 } else { 1.0 }
  [System.Windows.Automation.AutomationProperties]::SetName(
    $card,
    "Open $($Item.name)"
  )

  $grid = [System.Windows.Controls.Grid]::new()
  $card.Child = $grid
  if (-not $isMinUi) {
    $grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) | Out-Null
    $titleRow = [System.Windows.Controls.RowDefinition]::new()
    $titleRow.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($titleRow) | Out-Null
    $subtitleRow = [System.Windows.Controls.RowDefinition]::new()
    $subtitleRow.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($subtitleRow) | Out-Null
  }

  $iconPresentation = Get-ItemIconPresentation -Item $Item
  $iconSource = $iconPresentation.source
  if ($null -ne $iconSource) {
    $image = if ([string]$iconPresentation.kind -eq 'Semantic') {
      $maskHost = [System.Windows.Controls.Border]::new()
      $maskBrush = [System.Windows.Media.ImageBrush]::new($iconSource)
      $maskBrush.Stretch = [System.Windows.Media.Stretch]::Uniform
      $maskHost.OpacityMask = $maskBrush
      $maskHost.Background = if ([System.Windows.SystemParameters]::HighContrast) {
        [System.Windows.SystemColors]::ControlTextBrush
      } else {
        Convert-ToBrush $script:themePalette.text
      }
      $maskHost
    } else {
      $sourceImage = [System.Windows.Controls.Image]::new()
      $sourceImage.Source = $iconSource
      $sourceImage.Stretch = [System.Windows.Media.Stretch]::Uniform
      [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
        $sourceImage,
        [System.Windows.Media.BitmapScalingMode]::HighQuality
      )
      $sourceImage
    }
    $image.Width = if ($isMinUi) { 34 } else { 44 }
    $image.Height = $image.Width
    $image.Margin = if ($isMinUi) {
      [System.Windows.Thickness]::new(0)
    } else {
      [System.Windows.Thickness]::new(0, 2, 0, 8)
    }
    $image.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $image.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetRow($image, 0)
    $grid.Children.Add($image) | Out-Null
  } else {
    $glyph = if ([string]::IsNullOrWhiteSpace([string]$Item.glyph)) { '' } else { [string]$Item.glyph }
    $icon = New-FluentText -Glyph $glyph -Size $(if ($isMinUi) { 30 } else { 34 })
    $icon.Margin = if ($isMinUi) {
      [System.Windows.Thickness]::new(0)
    } else {
      [System.Windows.Thickness]::new(0, 0, 0, 8)
    }
    [System.Windows.Controls.Grid]::SetRow($icon, 0)
    $grid.Children.Add($icon) | Out-Null
  }

  if (-not $isMinUi) {
    $title = New-TextBlock -Text ([string]$Item.name) -Size 12 -Weight 'SemiBold'
    $title.Foreground = Convert-ToBrush $script:themePalette.text
    $title.TextAlignment = [System.Windows.TextAlignment]::Center
    $title.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    [System.Windows.Controls.Grid]::SetRow($title, 1)
    $grid.Children.Add($title) | Out-Null

    $subtitleGrid = [System.Windows.Controls.Grid]::new()
    $subtitleGrid.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($subtitleGrid, 2)
    $grid.Children.Add($subtitleGrid) | Out-Null
    $subtitle = New-TextBlock -Text ([string]$Item.subtitle) -Size 10 -Color '#FFA9B9D1'
    $subtitle.TextAlignment = [System.Windows.TextAlignment]::Center
    $subtitle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $subtitleGrid.Children.Add($subtitle) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$Item.health)) {
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Name = "Health$([string]$Item.id -replace '[^A-Za-z0-9_]', '')"
    $dot.Width = 9
    $dot.Height = 9
    $dot.Fill = Convert-ToBrush '#FF7D91AE'
    $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $dot.VerticalAlignment = if ($isMinUi) {
      [System.Windows.VerticalAlignment]::Bottom
    } else {
      [System.Windows.VerticalAlignment]::Center
    }
    $dot.Margin = if ($isMinUi) {
      [System.Windows.Thickness]::new(0, 0, 0, 1)
    } else {
      [System.Windows.Thickness]::new(0)
    }
    $dot.ToolTip = 'Checking'
    $dot.Tag = $card
    if ($isMinUi) {
      $grid.Children.Add($dot) | Out-Null
    } else {
      $subtitleGrid.Children.Add($dot) | Out-Null
    }
    $script:healthDots[[string]$Item.id] = $dot
    Set-LauncherCardHealthPresentation -Item $Item -State 'Checking'
  }

  $startupHint = if (Test-HasNodeStartup -Item $Item) {
    "`nOffline: starts with bundled Node, waits for health, then opens."
  } else {
    ''
  }
  $mediaHint = if (
    $Item.PSObject.Properties.Name -contains 'hoverMedia' -and
    -not [string]::IsNullOrWhiteSpace([string]$Item.hoverMedia)
  ) {
    "`nHover preview: $($Item.hoverMedia)"
  } else {
    ''
  }
  $card.ToolTip = "$($Item.name)`n$($Item.target)$startupHint$mediaHint`nRight-click to organize."
  [System.Windows.Automation.AutomationProperties]::SetHelpText(
    $card,
    "$($Item.name). $($Item.subtitle). Press Enter or Space to open; use the context-menu key to organize."
  )

  $card.Add_MouseEnter({
      param($sender, $eventArgs)
      $sender.Background = Convert-ToBrush $script:themePalette.cardHover
      $sender.BorderBrush = Convert-ToBrush $script:themePalette.accent
      Start-HoverMediaPreview -Item $sender.Tag
    })
  $card.Add_MouseLeave({
      param($sender, $eventArgs)
      if ($sender.IsKeyboardFocused) {
        $sender.Background = Convert-ToBrush $script:themePalette.cardHover
        $sender.BorderBrush = Convert-ToBrush $script:themePalette.accent
      } else {
        $sender.Background = Convert-ToBrush $script:themePalette.card
        $sender.BorderBrush = Convert-ToBrush (
          Set-ColorAlpha -Color $script:themePalette.border -Alpha 82
        )
      }
      if (
        $script:activeHoverMediaItemId -eq [string]$sender.Tag.id
      ) {
        Stop-HoverMediaPreview
      }
    })
  $card.Add_GotKeyboardFocus({
      param($sender, $eventArgs)
      $sender.Background = Convert-ToBrush $script:themePalette.cardHover
      $sender.BorderBrush = Convert-ToBrush $script:themePalette.accent
      $sender.BorderThickness = [System.Windows.Thickness]::new(2)
    })
  $card.Add_LostKeyboardFocus({
      param($sender, $eventArgs)
      $sender.BorderThickness = [System.Windows.Thickness]::new(1)
      if ($sender.IsMouseOver) {
        $sender.Background = Convert-ToBrush $script:themePalette.cardHover
        $sender.BorderBrush = Convert-ToBrush $script:themePalette.accent
      } else {
        $sender.Background = Convert-ToBrush $script:themePalette.card
        $sender.BorderBrush = Convert-ToBrush (
          Set-ColorAlpha -Color $script:themePalette.border -Alpha 82
        )
      }
    })
  $card.Add_MouseLeftButtonUp({
      param($sender, $eventArgs)
      $clickedItem = $sender.Tag
      if (-not $clickedItem.hidden) {
        Launch-Item -Item $clickedItem
      }
    })
  $card.Add_KeyDown({
      param($sender, $eventArgs)
      $clickedItem = $sender.Tag
      if (($eventArgs.Key -eq [System.Windows.Input.Key]::Enter -or
          $eventArgs.Key -eq [System.Windows.Input.Key]::Space) -and
          -not $clickedItem.hidden) {
        Launch-Item -Item $clickedItem
        $eventArgs.Handled = $true
      }
    })

  $context = [System.Windows.Controls.ContextMenu]::new()
  $context.Background = Convert-ToBrush '#FF0F203B'
  $context.Foreground = Convert-ToBrush '#FFF6F9FF'
  $context.BorderBrush = Convert-ToBrush '#995C8AC6'
  $context.BorderThickness = [System.Windows.Thickness]::new(1)
  $context.Padding = [System.Windows.Thickness]::new(4)
  $context.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  TargetType="{x:Type ContextMenu}">
  <Border
    Background="{TemplateBinding Background}"
    BorderBrush="{TemplateBinding BorderBrush}"
    BorderThickness="{TemplateBinding BorderThickness}"
    Padding="{TemplateBinding Padding}"
    CornerRadius="7">
    <StackPanel
      IsItemsHost="True"
      KeyboardNavigation.DirectionalNavigation="Cycle" />
  </Border>
</ControlTemplate>
'@)
  if ((Test-HasNodeStartup -Item $Item) -and (Test-HasHealthCheck -Item $Item)) {
    $serverRecovery = New-ContextMenuItem -Header 'Check and restart server'
    $serverRecovery.Tag = $Item
    Update-ServerRecoveryMenuItem -MenuItem $serverRecovery
    $serverRecovery.Add_Click({
        param($sender, $eventArgs)
        try {
          Invoke-ServerLifecycleMenuAction -Item $sender.Tag
        } catch {
          Show-Toast -Message "Could not change $($sender.Tag.name) server state"
          Write-RuntimeLog "Server lifecycle request failed for '$($sender.Tag.id)'. $($_.Exception.Message)"
        }
      })
    $context.Items.Add($serverRecovery) | Out-Null
    $context.Tag = $serverRecovery
    $context.Add_Opened({
        param($sender, $eventArgs)
        Update-ServerRecoveryMenuItem -MenuItem $sender.Tag
      })
  } elseif (Test-HasHealthCheck -Item $Item) {
    $configureRecovery = New-ContextMenuItem -Header 'Configure server restart...'
    $configureRecovery.ToolTip = 'Add a trusted Node start target before this shortcut can restart its server.'
    $configureRecovery.Tag = $Item
    $configureRecovery.Add_Click({
        param($sender, $eventArgs)
        Show-ItemDialog -ExistingItem $sender.Tag | Out-Null
      })
    $context.Items.Add($configureRecovery) | Out-Null
  }

  $edit = New-ContextMenuItem -Header 'Edit'
  $edit.Tag = $Item
  $edit.Add_Click({
      param($sender, $eventArgs)
      Show-ItemDialog -ExistingItem $sender.Tag | Out-Null
    })
  $context.Items.Add($edit) | Out-Null

  $earlier = New-ContextMenuItem -Header 'Move earlier'
  $earlier.Tag = $Item
  $earlier.Add_Click({
      param($sender, $eventArgs)
      Move-Item -ItemId ([string]$sender.Tag.id) -Direction -1
    })
  $context.Items.Add($earlier) | Out-Null

  $later = New-ContextMenuItem -Header 'Move later'
  $later.Tag = $Item
  $later.Add_Click({
      param($sender, $eventArgs)
      Move-Item -ItemId ([string]$sender.Tag.id) -Direction 1
    })
  $context.Items.Add($later) | Out-Null

  $visibility = New-ContextMenuItem -Header $(if ($Item.hidden) { 'Show' } else { 'Hide' })
  $visibility.Tag = $Item
  $visibility.Add_Click({
      param($sender, $eventArgs)
      $selectedItem = $sender.Tag
      $selectedItem.hidden = -not [bool]$selectedItem.hidden
      Save-State
      Render-Items
    })
  $context.Items.Add($visibility) | Out-Null

  $remove = New-ContextMenuItem -Header 'Remove shortcut...'
  $remove.Foreground = Convert-ToBrush '#FFFFA7B4'
  $remove.ToolTip = 'Removes only this Workspace entry. The original target stays untouched.'
  $remove.Tag = $Item
  $remove.Add_Click({
      param($sender, $eventArgs)
      Remove-ItemRegistration -Item $sender.Tag
    })
  $context.Items.Add($remove) | Out-Null
  $card.ContextMenu = $context

  return $card
}

function Update-PageDots {
  if ($null -eq $script:scrollViewer -or $null -eq $script:pageDotsPanel) {
    return
  }

  $viewport = [math]::Max(1.0, $script:scrollViewer.ViewportHeight)
  $extent = [math]::Max($viewport, $script:scrollViewer.ExtentHeight)
  $pageCount = [math]::Max(1, [math]::Ceiling($extent / $viewport))
  if ($pageCount -le 1) {
    if ($script:lastPageDotSignature -ne '1:0') {
      $script:pageDotsPanel.Children.Clear()
      $script:lastPageDotSignature = '1:0'
    }
    return
  }
  $maximumOffset = [math]::Max(0.0, $extent - $viewport)
  $currentPage = if (
    $maximumOffset -gt 0 -and
    $script:scrollViewer.VerticalOffset -ge ($maximumOffset - 1.0)
  ) {
    $pageCount - 1
  } else {
    [math]::Min(
      $pageCount - 1,
      [math]::Floor(($script:scrollViewer.VerticalOffset + ($viewport * 0.35)) / $viewport)
    )
  }

  $signature = "$($pageCount):$($currentPage)"
  if ($script:lastPageDotSignature -eq $signature) {
    return
  }

  $script:pageDotsPanel.Children.Clear()
  $script:lastPageDotSignature = $signature
  for ($page = 0; $page -lt $pageCount; $page++) {
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = if ($page -eq $currentPage) { 8 } else { 6 }
    $dot.Height = $dot.Width
    $dot.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
    $dot.Fill = Convert-ToBrush $(if ($page -eq $currentPage) { '#FF3E8BFF' } else { '#667D91AE' })
    $script:pageDotsPanel.Children.Add($dot) | Out-Null
  }
}

function Render-Items {
  $script:wrapPanel.Children.Clear()
  $script:healthDots.Clear()
  $script:lastPageDotSignature = ''
  $showHidden = [bool]$script:showHiddenCheck.IsChecked
  foreach ($item in @($script:state.items)) {
    if (-not $item.hidden -or $showHidden) {
      $script:wrapPanel.Children.Add((New-LauncherCard -Item $item)) | Out-Null
    }
  }
  $script:itemCountText.Text = "$(@($script:state.items | Where-Object { -not $_.hidden }).Count) shortcuts"
  $script:window.Dispatcher.BeginInvoke(
    [action]{ Update-PageDots },
    [System.Windows.Threading.DispatcherPriority]::Loaded
  ) | Out-Null
  Start-HealthCheck
}

function Start-HealthCheck {
  if ($script:healthPollTimer.IsEnabled) {
    return
  }

  $script:pendingHealth = [System.Collections.Generic.List[object]]::new()
  foreach ($item in @($script:state.items | Where-Object {
        -not $_.hidden -and (Test-HasHealthCheck -Item $_)
      })) {
    $request = $null
    try {
      $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get,
        [string]$item.health
      )
      $task = $script:httpClient.SendAsync(
        $request,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
      )
      $script:pendingHealth.Add([pscustomobject]@{
          item = $item
          task = $task
          request = $request
        })
    } catch {
      if ($null -ne $request) {
        $request.Dispose()
      }
      $script:healthStates[[string]$item.id] = $false
      if ($script:healthDots.ContainsKey([string]$item.id)) {
        Set-LauncherCardHealthPresentation `
          -Item $item `
          -State $(if (Test-HasNodeStartup -Item $item) { 'Offline' } else { 'Unavailable' }) `
          -Announce
      }
    }
  }

  $script:healthStartedAt = Get-Date
  $script:healthPollTimer.Start()
}

function Complete-HealthCheck {
  $online = 0
  $total = 0
  foreach ($pending in @($script:pendingHealth)) {
    $total++
    $healthy = $false
    $response = $null
    try {
      if ($pending.task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
        $response = $pending.task.Result
        $statusCode = [int]$pending.task.Result.StatusCode
        $healthy = $statusCode -ge 200 -and $statusCode -lt 400
      }
    } catch {
      $healthy = $false
    } finally {
      if ($null -ne $response) {
        $response.Dispose()
      }
      if (
        $pending.PSObject.Properties.Name -contains 'request' -and
        $null -ne $pending.request
      ) {
        $pending.request.Dispose()
      }
    }
    if ($healthy) {
      $online++
    }
    $itemId = [string]$pending.item.id
    $script:healthStates[$itemId] = $healthy
    if ($script:healthDots.ContainsKey($itemId)) {
      Set-LauncherCardHealthPresentation `
        -Item $pending.item `
        -State $(if ($healthy) {
            'Online'
          } elseif (Test-HasNodeStartup -Item $pending.item) {
            'Offline'
          } else {
            'Unavailable'
          }) `
        -Announce
    }

    if ($script:pendingOpen.ContainsKey($itemId)) {
      $pendingOpen = $script:pendingOpen[$itemId]
      if ($healthy) {
        $openWhenHealthy = (
          $pendingOpen.PSObject.Properties.Name -notcontains 'openWhenHealthy' -or
          [bool]$pendingOpen.openWhenHealthy
        )
        if ($openWhenHealthy) {
          try {
            Open-ItemTarget -Item $pendingOpen.item
            Show-Toast -Message "$($pendingOpen.item.name) is ready"
          } catch {
            Show-Toast -Message "Could not open $($pendingOpen.item.name)"
            Write-RuntimeLog "Ready target open failed for '$itemId'. $($_.Exception.Message)"
          }
        } else {
          Show-Toast -Message "$($pendingOpen.item.name) is online"
        }
        $script:pendingOpen.Remove($itemId)
      } elseif (-not [bool]$pendingOpen.startupRequested) {
        try {
          if (
            $pendingOpen.PSObject.Properties.Name -contains 'restartTrackedProcess' -and
            [bool]$pendingOpen.restartTrackedProcess
          ) {
            if (-not (Stop-TrackedLocalServer -Item $pendingOpen.item -ConfirmForce -AllowMissing)) {
              $script:pendingOpen.Remove($itemId)
              Show-Toast -Message "Restart canceled for $($pendingOpen.item.name)"
              continue
            }
          }
          Start-LocalServer -Item $pendingOpen.item | Out-Null
          $pendingOpen.startupRequested = $true
          $pendingOpen.deadline = (Get-Date).AddSeconds(30)
          $startVerb = if (
            $pendingOpen.PSObject.Properties.Name -contains 'restartTrackedProcess' -and
            [bool]$pendingOpen.restartTrackedProcess
          ) { 'Restarting' } else { 'Starting' }
          Show-Toast -Message "$startVerb $($pendingOpen.item.name) with bundled Node"
        } catch {
          $script:pendingOpen.Remove($itemId)
          Show-Toast -Message "Could not start $($pendingOpen.item.name)"
          Write-RuntimeLog "Bundled Node start failed for '$itemId'. $($_.Exception.Message)"
        }
      } elseif ((Get-Date) -ge [datetime]$pendingOpen.deadline) {
        $script:pendingOpen.Remove($itemId)
        Show-Toast -Message "$($pendingOpen.item.name) did not become healthy"
        Write-RuntimeLog "Bundled Node start timed out for '$itemId'."
      }
    }
  }
  $healthSummary = if ($total -gt 0) { "$online / $total online" } else { 'No health checks' }
  $script:onlineText.Text = $healthSummary
  $script:headerLogo.ToolTip = "Workspace Widget`n$healthSummary"
  [System.Windows.Automation.AutomationProperties]::SetHelpText(
    $script:headerLogo,
    $healthSummary
  )
  $script:onlineDot.Fill = Convert-ToBrush $(if ($online -eq $total -and $total -gt 0) { '#FF35DE8F' } else { '#FFFFB454' })
  $script:lastCheckedText.Text = "Last checked  $(Get-Date -Format 'HH:mm:ss')"
  if ($script:pendingOpen.Count -eq 0) {
    $script:startupPollTimer.Stop()
  }
}

function Capture-Widget {
  param([string]$Path)

  try {
    $bounds = [System.Windows.Media.VisualTreeHelper]::GetDescendantBounds($script:window)
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($script:window)
    $pixelWidth = [math]::Max(1, [int][math]::Ceiling($bounds.Width * $dpi.DpiScaleX))
    $pixelHeight = [math]::Max(1, [int][math]::Ceiling($bounds.Height * $dpi.DpiScaleY))
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
      $pixelWidth,
      $pixelHeight,
      96 * $dpi.DpiScaleX,
      96 * $dpi.DpiScaleY,
      [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($script:window)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
      $encoder.Save($stream)
    } finally {
      $stream.Dispose()
    }
    Write-RuntimeLog "Captured widget to '$Path'."
  } catch {
    Write-RuntimeLog "Capture failed. $($_.Exception.Message)"
    throw
  }
}

if ($IconResolutionProbe) {
  $semanticProbePath = Join-Path $script:semanticIconRoot 'launch.png'
  $probeItems = @(
    [pscustomobject][ordered]@{
      case = 'custom-over-semantic'
      name = 'Custom priority probe'
      target = 'https://example.invalid/custom'
      customIcon = $semanticProbePath
      customIconCache = ''
      iconPreset = 'service'
      iconLocation = ''
    },
    [pscustomobject][ordered]@{
      case = 'semantic-over-web-fallback'
      name = 'Semantic priority probe'
      target = 'https://example.invalid/semantic'
      customIcon = ''
      customIconCache = ''
      iconPreset = 'service'
      iconLocation = ''
    },
    [pscustomobject][ordered]@{
      case = 'shell-target'
      name = 'Shell priority probe'
      target = Join-Path $env:WINDIR 'System32\notepad.exe'
      customIcon = ''
      customIconCache = ''
      iconPreset = ''
      iconLocation = ''
    },
    [pscustomobject][ordered]@{
      case = 'web-fluent-fallback'
      name = 'Web fallback probe'
      target = 'https://example.invalid/fallback'
      customIcon = ''
      customIconCache = ''
      iconPreset = ''
      iconLocation = ''
    }
  )
  $expectedKinds = @('Custom', 'Semantic', 'Shell', 'None')
  $results = for ($index = 0; $index -lt $probeItems.Count; $index++) {
    $presentation = Get-ItemIconPresentation -Item $probeItems[$index]
    [pscustomobject][ordered]@{
      case = [string]$probeItems[$index].case
      expectedKind = $expectedKinds[$index]
      actualKind = [string]$presentation.kind
      hasImageSource = $null -ne $presentation.source
      matched = (
        [string]$presentation.kind -eq $expectedKinds[$index] -and
        $(if ($expectedKinds[$index] -eq 'None') {
            $null -eq $presentation.source
          } else {
            $null -ne $presentation.source
          })
      )
    }
  }
  $script:healthDots = @{}
  $accessibilityItem = [pscustomobject][ordered]@{
    id = 'semantic-health-accessibility-probe'
    name = 'Semantic health probe'
    target = 'http://127.0.0.1:9/'
  }
  $accessibilityCard = [System.Windows.Controls.Border]::new()
  $accessibilityDot = [System.Windows.Shapes.Ellipse]::new()
  $accessibilityDot.Tag = $accessibilityCard
  $script:healthDots[[string]$accessibilityItem.id] = $accessibilityDot
  Set-LauncherCardHealthPresentation -Item $accessibilityItem -State 'Checking'
  $checkingName = [System.Windows.Automation.AutomationProperties]::GetName(
    $accessibilityCard
  )
  Set-LauncherCardHealthPresentation -Item $accessibilityItem -State 'Online'
  $onlineName = [System.Windows.Automation.AutomationProperties]::GetName(
    $accessibilityCard
  )
  $dotName = [System.Windows.Automation.AutomationProperties]::GetName(
    $accessibilityDot
  )
  $liveSetting = [System.Windows.Automation.AutomationProperties]::GetLiveSetting(
    $accessibilityDot
  ).ToString()
  $accessibilityMatched = (
    $checkingName -match 'Status: Checking' -and
    $onlineName -match 'Status: Online' -and
    $dotName -match 'status: Online' -and
    $liveSetting -eq 'Polite'
  )
  $success = (
    @($results | Where-Object { -not $_.matched }).Count -eq 0 -and
    $accessibilityMatched
  )
  [pscustomobject][ordered]@{
    success = $success
    resolutionOrder = @('Custom', 'Semantic', 'Shell', 'Fluent fallback')
    results = @($results)
    accessibility = [ordered]@{
      matched = $accessibilityMatched
      checkingCardName = $checkingName
      onlineCardName = $onlineName
      onlineDotName = $dotName
      liveSetting = $liveSetting
    }
  } | ConvertTo-Json -Depth 6
  exit $(if ($success) { 0 } else { 1 })
}

if ($StartupTargetProbe) {
  try {
    if ([string]::IsNullOrWhiteSpace($StartupProbeTarget)) {
      throw 'StartupProbeTarget is required for StartupTargetProbe.'
    }
    $configuration = Resolve-NodeStartupConfiguration `
      -Target $StartupProbeTarget `
      -Arguments $StartupProbeArgs
    [pscustomobject]@{
      success = $true
      kind = $configuration.kind
      target = $configuration.target
      arguments = $configuration.arguments
    } | ConvertTo-Json -Depth 4
    exit 0
  } catch {
    [pscustomobject]@{
      success = $false
      error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4
    exit 1
  }
}

if ($StartupProbe) {
  if (
    [string]::IsNullOrWhiteSpace($StartupProbeTarget) -or
    [string]::IsNullOrWhiteSpace($StartupProbeHealth)
  ) {
    throw 'StartupProbeTarget and StartupProbeHealth are required for StartupProbe.'
  }

  $script:serverProcesses = @{}
  $probeItem = [pscustomobject][ordered]@{
    id = 'startup-probe'
    name = 'Bundled Node startup probe'
    target = $StartupProbeHealth
    health = $StartupProbeHealth
    startupTarget = $StartupProbeTarget
    startupArgs = $StartupProbeArgs
  }

  $probeProcess = $null
  $healthy = $false
  $tokenMatched = $false
  $statusCode = $null
  $trackedBeforeStop = $false
  $stopSucceeded = $false
  $processExitedAfterStop = $false
  $trackedRemoved = $false
  $startedAt = Get-Date
  try {
    Start-LocalServer -Item $probeItem | Out-Null
    $probeProcess = $script:serverProcesses['startup-probe']
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not $healthy) {
      Start-Sleep -Milliseconds 250
      try {
        $response = Invoke-WebRequest -Uri $StartupProbeHealth -UseBasicParsing -TimeoutSec 1
        $statusCode = [int]$response.StatusCode
        $tokenMatched = (
          [string]::IsNullOrWhiteSpace($StartupProbeExpectedToken) -or
          ([string]$response.Content).IndexOf(
            $StartupProbeExpectedToken,
            [System.StringComparison]::Ordinal
          ) -ge 0
        )
        $healthy = $statusCode -ge 200 -and $statusCode -lt 400 -and $tokenMatched
      } catch {
        $healthy = $false
      }
    }

    $trackedBeforeStop = Test-TrackedLocalServer -Item $probeItem
    $stopSucceeded = Stop-TrackedLocalServer -Item $probeItem
    if ($null -ne $probeProcess) {
      try {
        $probeProcess.Refresh()
        $processExitedAfterStop = [bool]$probeProcess.HasExited
      } catch {
        $processExitedAfterStop = $true
      }
    }
    $trackedRemoved = -not $script:serverProcesses.ContainsKey('startup-probe')

    [pscustomobject]@{
      success = $healthy -and $trackedBeforeStop -and $stopSucceeded -and $processExitedAfterStop -and $trackedRemoved
      bundledNodePath = $bundledNodePath
      bundledNodeVersion = (& $bundledNodePath --version)
      processId = if ($null -ne $probeProcess) { $probeProcess.Id } else { $null }
      health = $StartupProbeHealth
      statusCode = $statusCode
      expectedTokenMatched = [bool]$tokenMatched
      readyMilliseconds = [math]::Round(((Get-Date) - $startedAt).TotalMilliseconds)
      windowStyle = 'Hidden'
      trackedBeforeStop = [bool]$trackedBeforeStop
      stopSucceeded = [bool]$stopSucceeded
      processExitedAfterStop = [bool]$processExitedAfterStop
      trackedRemoved = [bool]$trackedRemoved
    } | ConvertTo-Json -Depth 5
  }
  finally {
    if ($null -ne $probeProcess) {
      try {
        if (-not $probeProcess.HasExited) {
          Stop-ProcessTree -Process $probeProcess | Out-Null
        }
      } catch {
        Write-RuntimeLog "Startup probe cleanup failed. $($_.Exception.Message)"
      }
    }
  }
  if (-not ($healthy -and $trackedBeforeStop -and $stopSucceeded -and $processExitedAfterStop -and $trackedRemoved)) {
    exit 1
  }
  exit 0
}

try {
  $script:state = Read-State
} catch [System.NotSupportedException] {
  if ($StateLifecycleProbe) {
    [pscustomobject][ordered]@{
      success = $false
      exitCode = 3
      statePath = $StatePath
      error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4
    exit 3
  }
  [System.Windows.MessageBox]::Show(
    $_.Exception.Message,
    'Workspace Widget update required',
    [System.Windows.MessageBoxButton]::OK,
    [System.Windows.MessageBoxImage]::Warning
  ) | Out-Null
  exit 3
}
if ($StateLifecycleProbe) {
  [pscustomobject][ordered]@{
    success = $true
    exitCode = 0
    statePath = $StatePath
    schemaVersion = [int]$script:state.schemaVersion
    itemCount = @($script:state.items).Count
  } | ConvertTo-Json -Depth 4
  exit 0
}
$script:minUiMode = [bool]$script:state.window.minUiMode
$script:minUiWidth = 96.0
$script:minUiOpacity = [math]::Max(
  0.35,
  [math]::Min(1.0, [double]$script:state.window.minUiOpacity)
)
$script:baseOpacity = if ($script:minUiMode) {
  $script:minUiOpacity
} else {
  [math]::Max(0.35, [math]::Min(1.0, [double]$script:state.window.opacity))
}
$script:hoverBrightness = [bool]$script:state.window.hoverBrightness
$script:alwaysOnTop = [bool]$script:state.window.alwaysOnTop
$script:attachToDesktopPreference = [bool]$script:state.window.attachToDesktop
$script:attachToDesktop = $script:attachToDesktopPreference -and -not $NoDesktopAttach
$script:healthDots = @{}
$script:healthStates = @{}
$script:pendingHealth = @()
$script:pendingOpen = @{}
$script:serverProcesses = @{}
$script:scrollTarget = 0.0
$script:lastPageDotSignature = ''
$script:scrollAnimationActive = $false
$script:scrollAnimationStartOffset = 0.0
$script:scrollAnimationStartTicks = [long]0
$script:scrollAnimationDurationMs = 260.0
$script:scrollAnimationFrames = 0
$script:lastAppliedOpacity = -1.0
$script:allowExit = $false
$script:trayHintShown = $false
$script:trayIcon = $null
$script:trayMenu = $null
$script:showEventTimer = $null
$script:applyingUiMode = $false
$script:snappingMinUi = $false
$script:minUiSnapTimer = $null
$script:topmostReassertTimer = $null
$script:foregroundPresentationActive = $false
$script:foregroundPresentationActivated = $false
$script:initialPresentationDone = $false
$script:initialPresentationAttempts = 0
$script:initialPresentationRetryTimer = $null
$script:autostartBusy = $false
$script:autostartProcess = $null
$script:autostartRequestedAction = $null
$script:autostartStartedAt = $null
$script:updatingAutostartCheck = $false
$script:autostartPollTimer = $null
$script:themePalette = $null
$script:backgroundGifTimer = $null
$script:backgroundGifFrames = @()
$script:backgroundGifIndex = 0
$script:hoverGifTimer = $null
$script:hoverGifFrames = @()
$script:hoverGifIndex = 0
$script:hoverWebView = $null
$script:hoverWebViewReady = $false
$script:hoverPendingYouTubeVideoId = $null
$script:youtubeEmbedOrigin = 'https://workspace-widget.local'
$script:youtubeEmbedReferrer = "$($script:youtubeEmbedOrigin)/"
$script:activeHoverMediaItemId = $null
$script:activeHoverMediaItem = $null

$xaml = @'
<Window
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="Workspace Service Widget"
  WindowStyle="None"
  ResizeMode="CanResize"
  AllowsTransparency="True"
  Background="Transparent"
  BorderThickness="0"
  Padding="0"
  ShowInTaskbar="False"
  MinWidth="96"
  MinHeight="320"
  MaxWidth="1000"
  MaxHeight="1000"
  FontFamily="Segoe UI Variable Text, Segoe UI"
  SnapsToDevicePixels="True"
  UseLayoutRounding="True"
  AllowDrop="True">
  <Border
    x:Name="PanelBorder"
    CornerRadius="14"
    Background="#FF09162B"
    BorderBrush="#205C8AC6"
    BorderThickness="0"
    Padding="20">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto" />
        <RowDefinition Height="Auto" />
        <RowDefinition Height="*" />
        <RowDefinition Height="Auto" />
      </Grid.RowDefinitions>

      <Image
        x:Name="WidgetBackgroundImage"
        Grid.RowSpan="4"
        Visibility="Collapsed"
        Stretch="UniformToFill"
        IsHitTestVisible="False" />
      <MediaElement
        x:Name="WidgetBackgroundVideo"
        Grid.RowSpan="4"
        Visibility="Collapsed"
        LoadedBehavior="Manual"
        UnloadedBehavior="Manual"
        Stretch="UniformToFill"
        IsMuted="True"
        Volume="0"
        ScrubbingEnabled="True"
        IsHitTestVisible="False" />
      <Rectangle
        x:Name="WidgetBackgroundTint"
        Grid.RowSpan="4"
        Fill="#B809162B"
        IsHitTestVisible="False" />

      <Grid x:Name="Header" Grid.Row="0" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <StackPanel
          x:Name="FullHeaderIdentity"
          Orientation="Horizontal"
          VerticalAlignment="Center">
          <Image
            x:Name="HeaderLogo"
            Width="24"
            Height="24"
            Margin="0,0,8,0"
            Stretch="Uniform"
            VerticalAlignment="Center"
            ToolTip="Workspace Widget" />
          <TextBlock
            x:Name="HeaderTitleText"
            Text="Workspace"
            FontSize="25"
            FontWeight="SemiBold"
            Foreground="#FFF6F9FF"
            VerticalAlignment="Center" />
          <StackPanel
            x:Name="HeaderHealthStatus"
            Orientation="Horizontal"
            VerticalAlignment="Center">
            <Ellipse
              x:Name="OnlineDot"
              Width="9"
              Height="9"
              Fill="#FF7D91AE"
              Margin="16,0,7,0"
              VerticalAlignment="Center" />
            <TextBlock
              x:Name="OnlineText"
              Text="Checking services"
              FontSize="10.5"
              Foreground="#FFA9B9D1"
              VerticalAlignment="Center" />
          </StackPanel>
        </StackPanel>
        <WrapPanel
          x:Name="Toolbar"
          Grid.Column="1"
          Orientation="Horizontal"
          HorizontalAlignment="Right"
          VerticalAlignment="Center" />
      </Grid>

      <StackPanel Grid.Row="1">
        <Border
          x:Name="OpacityPanel"
          Visibility="Collapsed"
          CornerRadius="11"
          Background="#8F0F203B"
          BorderBrush="#4D5C8AC6"
          BorderThickness="1"
          Padding="12,9"
          Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock
              Text="Opacity"
              FontSize="11"
              Foreground="#FFF6F9FF"
              VerticalAlignment="Center"
              Margin="0,0,12,0" />
            <Slider
              x:Name="OpacitySlider"
              Grid.Column="1"
              Minimum="0.35"
              Maximum="1"
              SmallChange="0.05"
              LargeChange="0.1"
              VerticalAlignment="Center"
              Margin="0,0,12,0" />
            <TextBlock
              x:Name="OpacityValue"
              Grid.Column="2"
              Width="42"
              FontSize="11"
              Foreground="#FFF6F9FF"
              TextAlignment="Right"
              VerticalAlignment="Center" />
            <TextBlock
              x:Name="HoverOpacityHint"
              Grid.Column="3"
              Text="Hover 100%"
              FontSize="10"
              Foreground="#FF7D91AE"
              Margin="14,0,0,0"
              VerticalAlignment="Center" />
          </Grid>
        </Border>

        <Border
          x:Name="SettingsPanel"
          Visibility="Collapsed"
          CornerRadius="11"
          Background="#8F0F203B"
          BorderBrush="#4D5C8AC6"
          BorderThickness="1"
          Padding="12,9"
          Margin="0,0,0,12">
          <Grid>
            <Grid.RowDefinitions>
               <RowDefinition Height="Auto" />
               <RowDefinition Height="Auto" />
               <RowDefinition Height="Auto" />
               <RowDefinition Height="Auto" />
               <RowDefinition Height="Auto" />
               <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <CheckBox
              x:Name="HoverBrightnessCheck"
              Content="Hover brightness"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,0,18,0" />
            <CheckBox
              x:Name="ShowHiddenCheck"
              Grid.Column="1"
              Content="Show hidden"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,0,18,0" />
            <TextBlock
              x:Name="ItemCountText"
              Grid.Column="2"
              Foreground="#FF7D91AE"
              FontSize="10"
              VerticalAlignment="Center" />
            <Button
              x:Name="ResetSizeButton"
              Grid.Column="3"
              Content="Reset size"
              Foreground="#FFC6D2E5"
              Background="#201F3A62"
              BorderBrush="#4D5C8AC6"
              Padding="9,4"
              FontSize="10" />
            <CheckBox
              x:Name="AlwaysOnTopCheck"
              Grid.Row="1"
              Grid.ColumnSpan="2"
              Content="Always on top"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,9,18,0"
              ToolTip="Keep Workspace above folders, browsers, and other applications." />
            <CheckBox
              x:Name="MinUiModeCheck"
              Grid.Row="2"
              Grid.ColumnSpan="2"
              Content="MIN UI mode"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,9,18,0"
              ToolTip="Use a 96 px icon rail that snaps to the nearest screen edge." />
            <CheckBox
              x:Name="StartWithWindowsCheck"
              Grid.Row="3"
              Grid.ColumnSpan="2"
              Content="Start with Windows"
              IsThreeState="True"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,9,18,0"
              ToolTip="Start Workspace Widget after you sign in. Windows preserves user and organization policy control." />
            <TextBlock
              x:Name="AutostartStatusText"
              Grid.Row="3"
              Grid.Column="2"
              Grid.ColumnSpan="2"
              Text="Checking..."
              Foreground="#FF7D91AE"
              FontSize="10"
              TextAlignment="Right"
              VerticalAlignment="Center"
              Margin="8,9,0,0"
              ToolTip="Windows startup-app status" />
            <Button
              x:Name="AppearanceButton"
              Grid.Row="4"
              Grid.ColumnSpan="2"
              Content="Appearance &amp; media..."
              Foreground="#FFC6D2E5"
              Background="#201F3A62"
              BorderBrush="#4D5C8AC6"
              Padding="9,5"
              HorizontalAlignment="Left"
              Margin="0,9,18,0"
              FontSize="10"
              ToolTip="Choose a theme, colors, and an image, GIF, video, or YouTube background." />
              <TextBlock
                x:Name="AppearanceStatusText"
              Grid.Row="4"
              Grid.Column="2"
              Grid.ColumnSpan="2"
              Text="Midnight"
              Foreground="#FF7D91AE"
              FontSize="10"
              TextAlignment="Right"
                VerticalAlignment="Center"
                Margin="8,9,0,0" />
            <CheckBox
              x:Name="DesktopLayerCheck"
              Grid.Row="5"
              Grid.ColumnSpan="4"
              Content="Keep on desktop layer when inactive"
              Foreground="#FFC6D2E5"
              FontSize="11"
              VerticalAlignment="Center"
              Margin="0,9,0,0"
              ToolTip="When enabled, Workspace returns behind ordinary apps after it loses focus. Opening it from the shortcut or tray always brings it forward." />
          </Grid>
        </Border>
      </StackPanel>

      <Grid Grid.Row="2" x:Name="ContentGrid">
        <ScrollViewer
          x:Name="ItemScrollViewer"
          VerticalScrollBarVisibility="Hidden"
          HorizontalScrollBarVisibility="Disabled"
          CanContentScroll="False"
          Focusable="False">
          <WrapPanel
            x:Name="ItemWrapPanel"
            Orientation="Horizontal"
            HorizontalAlignment="Center" />
        </ScrollViewer>

        <StackPanel
          x:Name="PageDotsPanel"
          HorizontalAlignment="Right"
          VerticalAlignment="Center"
          Margin="0,0,-10,0"
          IsHitTestVisible="False" />

        <Rectangle
          x:Name="DropOverlay"
          Visibility="Collapsed"
          Stroke="#FF3E8BFF"
          StrokeThickness="2"
          StrokeDashArray="5 4"
          RadiusX="14"
          RadiusY="14"
          Fill="#280A57B7"
          Margin="2"
          IsHitTestVisible="False" />
        <TextBlock
          x:Name="DropText"
          Visibility="Collapsed"
          Text="Drop to add"
          Foreground="#FFD9E9FF"
          FontSize="26"
          FontWeight="SemiBold"
          HorizontalAlignment="Center"
          VerticalAlignment="Center"
          IsHitTestVisible="False" />
        <Border
          x:Name="HoverPreviewBorder"
          Visibility="Collapsed"
          Width="304"
          Height="176"
          CornerRadius="14"
          BorderBrush="#CC74AEFF"
          BorderThickness="1"
          Background="#FA050B16"
          HorizontalAlignment="Center"
          VerticalAlignment="Center"
          IsHitTestVisible="False"
          Panel.ZIndex="30">
          <Grid x:Name="HoverPreviewHost" ClipToBounds="True">
            <Image
              x:Name="HoverPreviewImage"
              Visibility="Collapsed"
              Stretch="UniformToFill"
              IsHitTestVisible="False" />
            <MediaElement
              x:Name="HoverPreviewVideo"
              Visibility="Collapsed"
              LoadedBehavior="Manual"
              UnloadedBehavior="Manual"
              Stretch="UniformToFill"
              IsMuted="True"
              Volume="0"
              ScrubbingEnabled="True"
              IsHitTestVisible="False" />
            <Grid
              x:Name="HoverPreviewWebHost"
              Visibility="Collapsed"
              IsHitTestVisible="False" />
            <Border
              Background="#A8000000"
              VerticalAlignment="Bottom"
              Padding="10,6">
              <TextBlock
                x:Name="HoverPreviewLabel"
                Foreground="#FFFFFFFF"
                FontSize="11"
                FontWeight="SemiBold"
                TextTrimming="CharacterEllipsis" />
            </Border>
          </Grid>
        </Border>
      </Grid>

      <Grid x:Name="Footer" Grid.Row="3" Margin="0,8,0,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto" />
            <ColumnDefinition Width="*" />
          </Grid.ColumnDefinitions>
          <Button
            x:Name="AddShortcutButton"
            Content="+  Add shortcut"
            Padding="11,7"
            Foreground="#FF74AEFF"
            Background="Transparent"
            BorderBrush="#FF3E8BFF"
            BorderThickness="1"
            FontSize="11"
            Cursor="Hand" />
          <TextBlock
            Grid.Column="1"
            Text="Drop apps, files, folders, or URLs here"
            FontSize="11"
            Foreground="#FF7D91AE"
            HorizontalAlignment="Center"
            VerticalAlignment="Center"
            Margin="14,0,0,0" />
        </Grid>
        <Border
          Grid.Row="1"
          BorderBrush="#335C8AC6"
          BorderThickness="0,1,0,0"
          Margin="0,8,0,0"
          Padding="0,8,0,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <Button
              x:Name="RefreshButton"
              Background="Transparent"
              BorderBrush="Transparent"
              Foreground="#FFC6D2E5"
              Padding="0"
              Cursor="Hand">
              <StackPanel Orientation="Horizontal">
                <TextBlock
                  Text=""
                  FontFamily="Segoe Fluent Icons"
                  FontSize="15"
                  Margin="0,0,7,0" />
                <TextBlock Text="Refresh status" FontSize="11" />
              </StackPanel>
            </Button>
            <TextBlock
              x:Name="ToastText"
              Grid.Column="1"
              FontSize="11"
              Foreground="#FF74AEFF"
              VerticalAlignment="Center"
              Margin="14,0,0,0" />
            <TextBlock
              x:Name="LastCheckedText"
              Grid.Column="2"
              Text="Last checked  —"
              FontSize="11"
              Foreground="#FFA9B9D1"
              VerticalAlignment="Center" />
            <ResizeGrip
              x:Name="WindowResizeGrip"
              Grid.Column="3"
              Width="16"
              Height="16"
              Margin="10,0,-5,-5"
              HorizontalAlignment="Right"
              VerticalAlignment="Bottom"
              ToolTip="Resize Workspace" />
          </Grid>
        </Border>
      </Grid>

      <Border
        x:Name="ToastBorder"
        Grid.RowSpan="4"
        Visibility="Collapsed"
        HorizontalAlignment="Center"
        VerticalAlignment="Bottom"
        Margin="0,0,0,54"
        Padding="12,7"
        CornerRadius="10"
        Background="#F31B3559"
        BorderBrush="#995C8AC6"
        BorderThickness="1"
        IsHitTestVisible="False">
        <TextBlock
          x:Name="ToastOverlayText"
          Foreground="#FFF6F9FF"
          FontSize="11" />
      </Border>

      <Border
        x:Name="ResizeHandle"
        Grid.RowSpan="4"
        Width="30"
        Height="30"
        HorizontalAlignment="Right"
        VerticalAlignment="Bottom"
        Margin="0,0,-9,-9"
        Background="Transparent"
        Cursor="SizeNWSE"
        ToolTip="Resize Workspace" />
    </Grid>
  </Border>
</Window>
'@

$xmlReader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$script:window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
$script:window.Left = if ($script:minUiMode) {
  [double]$script:state.window.minUiLeft
} else {
  [double]$script:state.window.left
}
$script:window.Top = if ($script:minUiMode) {
  [double]$script:state.window.minUiTop
} else {
  [double]$script:state.window.top
}
$script:window.Width = if ($script:minUiMode) {
  $script:minUiWidth
} else {
  [math]::Max(430, [double]$script:state.window.width)
}
$script:window.Height = if ($script:minUiMode) {
  [math]::Max(320, [math]::Min(1000, [double]$script:state.window.minUiHeight))
} else {
  [math]::Max(500, [double]$script:state.window.height)
}
$script:window.Topmost = $script:alwaysOnTop
$script:window.Opacity = if ([string]::IsNullOrWhiteSpace($CapturePath)) {
  0.0
} else {
  $script:baseOpacity
}

$script:toolbar = $script:window.FindName('Toolbar')
$script:fullHeaderIdentity = $script:window.FindName('FullHeaderIdentity')
$script:headerLogo = $script:window.FindName('HeaderLogo')
$script:headerTitleText = $script:window.FindName('HeaderTitleText')
$script:headerHealthStatus = $script:window.FindName('HeaderHealthStatus')
$script:panelBorder = $script:window.FindName('PanelBorder')
$script:opacityPanel = $script:window.FindName('OpacityPanel')
$script:settingsPanel = $script:window.FindName('SettingsPanel')
$script:opacitySlider = $script:window.FindName('OpacitySlider')
$script:opacityValue = $script:window.FindName('OpacityValue')
$script:hoverOpacityHint = $script:window.FindName('HoverOpacityHint')
$script:hoverBrightnessCheck = $script:window.FindName('HoverBrightnessCheck')
$script:alwaysOnTopCheck = $script:window.FindName('AlwaysOnTopCheck')
$script:minUiModeCheck = $script:window.FindName('MinUiModeCheck')
$script:startWithWindowsCheck = $script:window.FindName('StartWithWindowsCheck')
$script:desktopLayerCheck = $script:window.FindName('DesktopLayerCheck')
$script:autostartStatusText = $script:window.FindName('AutostartStatusText')
$script:appearanceButton = $script:window.FindName('AppearanceButton')
$script:appearanceStatusText = $script:window.FindName('AppearanceStatusText')
$script:showHiddenCheck = $script:window.FindName('ShowHiddenCheck')
$script:itemCountText = $script:window.FindName('ItemCountText')
$script:resetSizeButton = $script:window.FindName('ResetSizeButton')
$script:scrollViewer = $script:window.FindName('ItemScrollViewer')
$script:wrapPanel = $script:window.FindName('ItemWrapPanel')
$script:pageDotsPanel = $script:window.FindName('PageDotsPanel')
$script:dropOverlay = $script:window.FindName('DropOverlay')
$script:dropText = $script:window.FindName('DropText')
$script:addShortcutButton = $script:window.FindName('AddShortcutButton')
$script:refreshButton = $script:window.FindName('RefreshButton')
$script:onlineDot = $script:window.FindName('OnlineDot')
$script:onlineText = $script:window.FindName('OnlineText')
$script:lastCheckedText = $script:window.FindName('LastCheckedText')
$script:toastBorder = $script:window.FindName('ToastBorder')
$script:toastText = $script:window.FindName('ToastOverlayText')
$script:header = $script:window.FindName('Header')
$script:contentGrid = $script:window.FindName('ContentGrid')
$script:footer = $script:window.FindName('Footer')
$script:windowResizeGrip = $script:window.FindName('WindowResizeGrip')
$script:resizeHandle = $script:window.FindName('ResizeHandle')
$script:backgroundImage = $script:window.FindName('WidgetBackgroundImage')
$script:backgroundVideo = $script:window.FindName('WidgetBackgroundVideo')
$script:backgroundTint = $script:window.FindName('WidgetBackgroundTint')
$script:hoverPreviewBorder = $script:window.FindName('HoverPreviewBorder')
$script:hoverPreviewHost = $script:window.FindName('HoverPreviewHost')
$script:hoverPreviewImage = $script:window.FindName('HoverPreviewImage')
$script:hoverPreviewVideo = $script:window.FindName('HoverPreviewVideo')
$script:hoverPreviewWebHost = $script:window.FindName('HoverPreviewWebHost')
$script:hoverPreviewLabel = $script:window.FindName('HoverPreviewLabel')

$headerLogoPath = Join-Path $ProjectRoot 'assets\workspace-widget-logo.png'
if (Test-Path -LiteralPath $headerLogoPath -PathType Leaf) {
  try {
    $headerBitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
    $headerBitmap.BeginInit()
    $headerBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $headerBitmap.UriSource = [uri]$headerLogoPath
    $headerBitmap.EndInit()
    $headerBitmap.Freeze()
    $script:headerLogo.Source = $headerBitmap
    [System.Windows.Automation.AutomationProperties]::SetName(
      $script:headerLogo,
      'Workspace Widget'
    )
  } catch {
    $script:headerLogo.Visibility = [System.Windows.Visibility]::Collapsed
    Write-RuntimeLog "Header logo could not load. $($_.Exception.Message)"
  }
}

$secondaryButtonTemplate = New-ButtonTemplate `
  -HoverBackground '#FF174A78' `
  -PressedBackground '#FF0F355E'
$script:addShortcutButton.Template = $secondaryButtonTemplate
$script:refreshButton.Template = $secondaryButtonTemplate
$script:resetSizeButton.Template = $secondaryButtonTemplate
$script:appearanceButton.Template = $secondaryButtonTemplate
$script:addShortcutButton.FocusVisualStyle = $null
$script:refreshButton.FocusVisualStyle = $null
$script:resetSizeButton.FocusVisualStyle = $null
$script:appearanceButton.FocusVisualStyle = $null

function Set-WidgetOpacity {
  param([double]$Value)

  $resolved = [math]::Max(0.35, [math]::Min(1.0, $Value))
  $script:window.BeginAnimation(
    [System.Windows.Window]::OpacityProperty,
    $null
  )
  $script:window.Opacity = $resolved
  if ([math]::Abs($script:lastAppliedOpacity - $resolved) -gt 0.001) {
    $script:lastAppliedOpacity = $resolved
    Write-RuntimeLog "Opacity applied. value=$([math]::Round($resolved, 2))"
  }
}

function Update-WidgetOpacity {
  param([switch]$ForceBase)

  $opacityEditorOpen = (
    $script:opacityPanel.Visibility -eq [System.Windows.Visibility]::Visible
  )
  $useHoverBrightness = (
    -not $ForceBase -and
    -not $opacityEditorOpen -and
    $script:hoverBrightness -and
    $script:window.IsMouseOver
  )
  Set-WidgetOpacity -Value $(if ($useHoverBrightness) { 1.0 } else { $script:baseOpacity })
  $script:hoverOpacityHint.Text = if ($script:hoverBrightness) {
    'Hover 100%'
  } else {
    'Hover off'
  }
}

function Get-WidgetWorkingArea {
  $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
  $handle = $helper.EnsureHandle()
  if ($handle -ne [IntPtr]::Zero) {
    try {
      $physical = [WorkspaceWidgetNative]::GetPhysicalWorkArea($handle)
      $presentationSource = [System.Windows.PresentationSource]::FromVisual(
        $script:window
      )
      if (
        $null -ne $presentationSource -and
        $null -ne $presentationSource.CompositionTarget
      ) {
        $transform = $presentationSource.CompositionTarget.TransformFromDevice
        $topLeft = $transform.Transform(
          [System.Windows.Point]::new($physical.Left, $physical.Top)
        )
        $bottomRight = $transform.Transform(
          [System.Windows.Point]::new($physical.Right, $physical.Bottom)
        )
        return [pscustomobject]@{
          left = [double]$topLeft.X
          top = [double]$topLeft.Y
          right = [double]$bottomRight.X
          bottom = [double]$bottomRight.Y
          width = [double]($bottomRight.X - $topLeft.X)
          height = [double]($bottomRight.Y - $topLeft.Y)
        }
      }
    } catch {
      Write-RuntimeLog "DPI-aware work area lookup failed. $($_.Exception.Message)"
    }
  }

  $workArea = [System.Windows.SystemParameters]::WorkArea
  return [pscustomobject]@{
    left = [double]$workArea.Left
    top = [double]$workArea.Top
    right = [double]$workArea.Right
    bottom = [double]$workArea.Bottom
    width = [double]$workArea.Width
    height = [double]$workArea.Height
  }
}

function Ensure-WindowVisible {
  param(
    [string]$Reason = 'visibility check',
    [switch]$Persist,
    [switch]$Quiet
  )

  try {
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
    $handle = $helper.EnsureHandle()
    $physicalBounds = [WorkspaceWidgetNative]::GetPhysicalWindowRect($handle)
    $left = [double]$physicalBounds.Left
    $top = [double]$physicalBounds.Top
    $width = [double]($physicalBounds.Right - $physicalBounds.Left)
    $height = [double]($physicalBounds.Bottom - $physicalBounds.Top)
    $areaIndex = 0
    $workingAreas = @(
      foreach ($area in [WorkspaceWidgetNative]::GetPhysicalWorkAreas()) {
        $areaIndex++
        [pscustomobject]@{
          deviceName = "physical-display-$areaIndex"
          left = [double]$area.Left
          top = [double]$area.Top
          right = [double]$area.Right
          bottom = [double]$area.Bottom
          width = [double]($area.Right - $area.Left)
          height = [double]($area.Bottom - $area.Top)
        }
      }
    )
    $geometry = Resolve-VisibleWindowGeometry `
      -Left $left `
      -Top $top `
      -Width $width `
      -Height $height `
      -MinWidth $width `
      -MinHeight $height `
      -MinimumVisibleWidth $(if ($script:minUiMode) { 48.0 } else { 160.0 }) `
      -MinimumVisibleHeight $(if ($script:minUiMode) { 56.0 } else { 72.0 }) `
      -WorkingAreas $workingAreas
    if (-not $geometry.adjusted) {
      return $false
    }

    $positioned = [WorkspaceWidgetNative]::SetWindowPos(
      $handle,
      [IntPtr]::Zero,
      [int][math]::Round([double]$geometry.left),
      [int][math]::Round([double]$geometry.top),
      [int][math]::Round([double]$geometry.width),
      [int][math]::Round([double]$geometry.height),
      (
        [WorkspaceWidgetNative]::SWP_NOZORDER -bor
        [WorkspaceWidgetNative]::SWP_NOACTIVATE
      )
    )
    if (-not $positioned) {
      throw 'Windows rejected the recovered widget bounds.'
    }

    if ($Persist) {
      Save-State | Out-Null
    }
    if (-not $Quiet) {
      Write-RuntimeLog (
        "Window recovered to visible work area. reason=$Reason " +
        "from=$([math]::Round($left)),$([math]::Round($top)) " +
        "to=$([math]::Round([double]$geometry.left)),$([math]::Round([double]$geometry.top)) " +
        "display='$($geometry.deviceName)' coordinates=physical"
      )
    }
    return $true
  } catch {
    Write-RuntimeLog "Window visibility recovery failed. reason=$Reason $($_.Exception.Message)"
    return $false
  }
}

function Snap-MinUiToNearestEdge {
  param([double]$AnchorCenter = [double]::NaN)

  if (-not $script:minUiMode) {
    return
  }

  $workArea = Get-WidgetWorkingArea
  $edgeMargin = 8.0
  $resolvedCenter = if ([double]::IsNaN($AnchorCenter)) {
    $script:window.Left + ($script:window.Width / 2.0)
  } else {
    $AnchorCenter
  }
  $workAreaCenter = $workArea.left + ($workArea.width / 2.0)
  $targetLeft = if ($resolvedCenter -le $workAreaCenter) {
    $workArea.left + $edgeMargin
  } else {
    $workArea.right - $script:minUiWidth - $edgeMargin
  }
  $maximumTop = [math]::Max(
    $workArea.top + $edgeMargin,
    $workArea.bottom - $script:window.Height - $edgeMargin
  )
  $targetTop = [math]::Max(
    $workArea.top + $edgeMargin,
    [math]::Min($maximumTop, $script:window.Top)
  )
  if (
    [math]::Abs($script:window.Left - $targetLeft) -lt 0.5 -and
    [math]::Abs($script:window.Top - $targetTop) -lt 0.5
  ) {
    return
  }

  $script:snappingMinUi = $true
  try {
    $script:window.Left = $targetLeft
    $script:window.Top = $targetTop
  } finally {
    $script:snappingMinUi = $false
  }
}

function Set-ToolbarCompactMode {
  param([bool]$Compact)

  foreach ($button in @($script:toolbar.Children)) {
    if ($button -isnot [System.Windows.Controls.Button]) {
      continue
    }
    if ($null -ne $button.Tag -and $null -ne $button.Tag.label) {
      $button.Tag.label.Visibility = if ($Compact) {
        [System.Windows.Visibility]::Collapsed
      } else {
        [System.Windows.Visibility]::Visible
      }
    }
    $button.Width = if ($Compact) { 24 } else { [double]::NaN }
    $button.Height = if ($Compact) { 24 } else { [double]::NaN }
    $button.Padding = if ($Compact) {
      [System.Windows.Thickness]::new(4)
    } elseif ($null -eq $button.Tag -or $null -eq $button.Tag.label) {
      [System.Windows.Thickness]::new(7, 6, 7, 6)
    } else {
      [System.Windows.Thickness]::new(8, 6, 8, 6)
    }
    $button.Margin = if ($Compact) {
      [System.Windows.Thickness]::new(1)
    } else {
      [System.Windows.Thickness]::new(2, 0, 0, 0)
    }
  }
}

function Update-ResponsiveHeader {
  if ($script:minUiMode) {
    $script:fullHeaderIdentity.Visibility = [System.Windows.Visibility]::Collapsed
    return
  }

  $script:fullHeaderIdentity.Visibility = [System.Windows.Visibility]::Visible
  $compactTitle = $script:window.ActualWidth -lt 500
  $compactHealth = $script:window.ActualWidth -lt 680
  Set-ToolbarCompactMode -Compact $compactTitle
  $script:headerTitleText.Visibility = if ($compactTitle) {
    [System.Windows.Visibility]::Collapsed
  } else {
    [System.Windows.Visibility]::Visible
  }
  $script:headerHealthStatus.Visibility = if ($compactHealth) {
    [System.Windows.Visibility]::Collapsed
  } else {
    [System.Windows.Visibility]::Visible
  }
  $script:headerLogo.Margin = if ($compactTitle) {
    [System.Windows.Thickness]::new(0)
  } else {
    [System.Windows.Thickness]::new(0, 0, 8, 0)
  }
}

function Set-MinUiMode {
  param(
    [bool]$Enabled,
    [switch]$Initial
  )

  if ($script:applyingUiMode) {
    return
  }
  if (-not $Initial -and $script:minUiMode -eq $Enabled) {
    return
  }

  $script:applyingUiMode = $true
  $previousAutostartGuard = $script:updatingAutostartCheck
  $script:updatingAutostartCheck = $true
  try {
    $previouslyMinUi = [bool]$script:minUiMode
    $anchorCenter = $script:window.Left + ($script:window.Width / 2.0)

    if ($Enabled) {
      if (-not $previouslyMinUi) {
        $script:state.window.left = [math]::Round($script:window.Left, 1)
        $script:state.window.top = [math]::Round($script:window.Top, 1)
        $script:state.window.width = [math]::Round($script:window.Width, 1)
        $script:state.window.height = [math]::Round($script:window.Height, 1)
        $script:state.window.opacity = [math]::Round([double]$script:baseOpacity, 2)
      }

      $script:minUiMode = $true
      $script:state.window.minUiMode = $true
      $script:baseOpacity = $script:minUiOpacity
      $script:window.MinWidth = $script:minUiWidth
      $script:window.MaxWidth = $script:minUiWidth
      $script:window.Width = $script:minUiWidth
      $workArea = Get-WidgetWorkingArea
      $maximumMinHeight = [math]::Max(320, $workArea.height - 16)
      $requestedMinHeight = if ($Initial) {
        [double]$script:state.window.minUiHeight
      } else {
        [double]$script:window.Height
      }
      $script:window.Height = [math]::Max(
        320,
        [math]::Min($maximumMinHeight, $requestedMinHeight)
      )
      if ($Initial) {
        $script:window.Left = [double]$script:state.window.minUiLeft
        $script:window.Top = [double]$script:state.window.minUiTop
        $anchorCenter = $script:window.Left + ($script:minUiWidth / 2.0)
      }

      $script:panelBorder.Padding = [System.Windows.Thickness]::new(8)
      $script:panelBorder.CornerRadius = [System.Windows.CornerRadius]::new(14)
      $script:fullHeaderIdentity.Visibility = [System.Windows.Visibility]::Collapsed
      $script:header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
      [System.Windows.Controls.Grid]::SetColumn($script:toolbar, 0)
      [System.Windows.Controls.Grid]::SetColumnSpan($script:toolbar, 2)
      $script:toolbar.Width = 78
      $script:toolbar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
      Set-ToolbarCompactMode -Compact $true
      $script:opacityPanel.Visibility = [System.Windows.Visibility]::Collapsed
      $script:settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
      $script:footer.Visibility = [System.Windows.Visibility]::Collapsed
      $script:pageDotsPanel.Visibility = [System.Windows.Visibility]::Collapsed
      $script:resizeHandle.Visibility = [System.Windows.Visibility]::Collapsed
      $script:dropText.Text = '+'
      $script:dropText.FontSize = 28
      $script:minUiModeButton.ToolTip = 'Restore full Workspace'
      [System.Windows.Automation.AutomationProperties]::SetName(
        $script:minUiModeButton,
        'Restore full Workspace'
      )
      Snap-MinUiToNearestEdge -AnchorCenter $anchorCenter
    } else {
      if ($previouslyMinUi) {
        $script:state.window.minUiLeft = [math]::Round($script:window.Left, 1)
        $script:state.window.minUiTop = [math]::Round($script:window.Top, 1)
        $script:state.window.minUiHeight = [math]::Round($script:window.Height, 1)
        $script:state.window.minUiOpacity = [math]::Round([double]$script:baseOpacity, 2)
        $script:minUiOpacity = [double]$script:state.window.minUiOpacity
      }

      $script:minUiMode = $false
      $script:state.window.minUiMode = $false
      $script:baseOpacity = [math]::Max(
        0.35,
        [math]::Min(1.0, [double]$script:state.window.opacity)
      )
      $script:window.MaxWidth = 1000
      $script:window.MinWidth = 430
      $script:window.Width = [math]::Max(430, [double]$script:state.window.width)
      $script:window.Height = [math]::Max(500, [double]$script:state.window.height)
      $script:window.Left = [double]$script:state.window.left
      $script:window.Top = [double]$script:state.window.top

      $script:panelBorder.Padding = [System.Windows.Thickness]::new(20)
      $script:panelBorder.CornerRadius = [System.Windows.CornerRadius]::new(14)
      $script:fullHeaderIdentity.Visibility = [System.Windows.Visibility]::Visible
      $script:header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
      [System.Windows.Controls.Grid]::SetColumn($script:toolbar, 1)
      [System.Windows.Controls.Grid]::SetColumnSpan($script:toolbar, 1)
      $script:toolbar.Width = [double]::NaN
      $script:toolbar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
      Set-ToolbarCompactMode -Compact $false
      $script:footer.Visibility = [System.Windows.Visibility]::Visible
      $script:pageDotsPanel.Visibility = [System.Windows.Visibility]::Visible
      $script:resizeHandle.Visibility = [System.Windows.Visibility]::Visible
      $script:dropText.Text = 'Drop to add'
      $script:dropText.FontSize = 26
      $script:minUiModeButton.ToolTip = 'Switch to MIN UI'
      [System.Windows.Automation.AutomationProperties]::SetName(
        $script:minUiModeButton,
        'Switch to MIN UI'
      )
    }

    if ($script:minUiModeCheck.IsChecked -ne $Enabled) {
      $script:minUiModeCheck.IsChecked = $Enabled
    }
    Update-ResponsiveHeader
    $script:opacitySlider.Value = $script:baseOpacity
    $script:opacityValue.Text = '{0:P0}' -f $script:baseOpacity
    $visibilityReason = if ($Initial) { 'initial mode restore' } else { 'ui mode change' }
    Ensure-WindowVisible `
      -Reason $visibilityReason `
      -Quiet:(-not $Initial) | Out-Null
    if ($script:window.IsLoaded) {
      Render-Items
      Update-WidgetOpacity
      Save-State
      Write-RuntimeLog "MIN UI mode changed. enabled=$Enabled width=$([math]::Round($script:window.Width))"
    }
  } finally {
    $script:updatingAutostartCheck = $previousAutostartGuard
    $script:applyingUiMode = $false
  }
}

function Set-WindowLayerMode {
  param(
    [string]$Reason = 'refresh',
    [switch]$Quiet
  )

  try {
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
    $handle = $helper.EnsureHandle()
    if ($handle -eq [IntPtr]::Zero) {
      throw 'The Workspace window handle is unavailable.'
    }

    $desiredOwner = [IntPtr]::Zero
    if (-not $script:alwaysOnTop -and $script:attachToDesktop) {
      $desktop = [WorkspaceWidgetNative]::FindWindow('Progman', 'Program Manager')
      if ($desktop -ne [IntPtr]::Zero) {
        $desiredOwner = $desktop
      }
    }

    $currentOwner = [WorkspaceWidgetNative]::GetWindowOwner($handle)
    if ($currentOwner -ne $desiredOwner) {
      [WorkspaceWidgetNative]::SetWindowOwner($handle, $desiredOwner)
      $currentOwner = [WorkspaceWidgetNative]::GetWindowOwner($handle)
      if ($currentOwner -ne $desiredOwner) {
        throw "The window owner did not change to $($desiredOwner.ToInt64())."
      }
    }

    $script:window.Topmost = $script:alwaysOnTop
    $insertAfter = if ($script:alwaysOnTop) {
      [WorkspaceWidgetNative]::HWND_TOPMOST
    } else {
      [WorkspaceWidgetNative]::HWND_NOTOPMOST
    }
    $flags = (
      [WorkspaceWidgetNative]::SWP_NOMOVE -bor
      [WorkspaceWidgetNative]::SWP_NOSIZE -bor
      [WorkspaceWidgetNative]::SWP_NOACTIVATE
    )
    $positioned = [WorkspaceWidgetNative]::SetWindowPos(
      $handle,
      $insertAfter,
      0,
      0,
      0,
      0,
      $flags
    )
    if (-not $positioned) {
      throw 'Windows rejected the requested topmost Z-order.'
    }

    $nativeTopmost = [WorkspaceWidgetNative]::IsTopmostWindow($handle)
    if ($nativeTopmost -ne $script:alwaysOnTop) {
      throw "Native topmost verification returned $nativeTopmost."
    }

    if (-not $Quiet) {
      Write-RuntimeLog (
        "Window layer applied. reason=$Reason topmost=$($script:alwaysOnTop) " +
        "nativeTopmost=$nativeTopmost owner=$($currentOwner.ToInt64())"
      )
    }
    return $true
  } catch {
    Write-RuntimeLog "Window layer apply failed. reason=$Reason $($_.Exception.Message)"
    return $false
  }
}

function Show-WorkspaceFromTray {
  param([string]$Reason = 'tray restore')

  try {
    if (-not $script:window.IsVisible) {
      $script:window.Show()
    }
    if ($script:window.WindowState -eq [System.Windows.WindowState]::Minimized) {
      $script:window.WindowState = [System.Windows.WindowState]::Normal
    }
    Ensure-WindowVisible -Reason $Reason -Persist | Out-Null

    $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
    $handle = $helper.EnsureHandle()
    if ($handle -eq [IntPtr]::Zero) {
      throw 'The Workspace window handle is unavailable.'
    }

    [WorkspaceWidgetNative]::ShowWindow(
      $handle,
      [WorkspaceWidgetNative]::SW_RESTORE
    ) | Out-Null

    if ($script:attachToDesktop -and -not $script:alwaysOnTop) {
      # A desktop-owned window is intentionally behind ordinary apps. Detach it
      # briefly and raise it to the top of the normal window band so an explicit
      # launch/Open action is always visible. Focus loss reattaches it.
      [WorkspaceWidgetNative]::SetWindowOwner($handle, [IntPtr]::Zero)
      if ([WorkspaceWidgetNative]::GetWindowOwner($handle) -ne [IntPtr]::Zero) {
        throw 'Windows did not detach the widget from the desktop layer.'
      }
      $script:window.Topmost = $false
      $flags = (
        [WorkspaceWidgetNative]::SWP_NOMOVE -bor
        [WorkspaceWidgetNative]::SWP_NOSIZE
      )
      $raisedTopmost = [WorkspaceWidgetNative]::SetWindowPos(
        $handle,
        [WorkspaceWidgetNative]::HWND_TOPMOST,
        0,
        0,
        0,
        0,
        $flags
      )
      $raisedNormal = [WorkspaceWidgetNative]::SetWindowPos(
        $handle,
        [WorkspaceWidgetNative]::HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        $flags
      )
      if (-not $raisedTopmost -or -not $raisedNormal) {
        throw 'Windows rejected the foreground Z-order transition.'
      }
      if ([WorkspaceWidgetNative]::IsTopmostWindow($handle)) {
        throw 'The temporary foreground pulse left the widget topmost.'
      }
      $script:foregroundPresentationActive = $true
      $script:foregroundPresentationActivated = $false
    } else {
      if (-not (Set-WindowLayerMode -Reason $Reason)) {
        throw 'The requested window layer could not be applied.'
      }
      $script:foregroundPresentationActive = $false
      $script:foregroundPresentationActivated = $false
      if (-not $script:alwaysOnTop) {
        $raisedNormal = [WorkspaceWidgetNative]::SetWindowPos(
          $handle,
          [IntPtr]::Zero,
          0,
          0,
          0,
          0,
          (
            [WorkspaceWidgetNative]::SWP_NOMOVE -bor
            [WorkspaceWidgetNative]::SWP_NOSIZE
          )
        )
        if (-not $raisedNormal) {
          throw 'Windows rejected the normal foreground Z-order.'
        }
      }
    }

    $foregroundAccepted = [WorkspaceWidgetNative]::SetForegroundWindow($handle)
    $activationAccepted = $script:window.Activate()
    $script:window.UpdateLayout()
    Update-WidgetOpacity

    $minimumWidth = if ($script:minUiMode) { 48 } else { 160 }
    $minimumHeight = if ($script:minUiMode) { 56 } else { 72 }
    $nativePresented = [WorkspaceWidgetNative]::IsWindowPresented(
      $handle,
      $minimumWidth,
      $minimumHeight
    )
    $owner = [WorkspaceWidgetNative]::GetWindowOwner($handle)
    $nativeTopmost = [WorkspaceWidgetNative]::IsTopmostWindow($handle)
    if (-not $nativePresented) {
      throw 'Native visibility verification did not find an accessible widget area.'
    }
    if ($owner -ne [IntPtr]::Zero) {
      throw "The explicitly presented window still has owner $($owner.ToInt64())."
    }
    if ($script:alwaysOnTop -and -not $nativeTopmost) {
      throw 'Always on top was requested but native verification is false.'
    }

    if ($null -ne $presentedEvent) {
      $presentedEvent.Set() | Out-Null
    }
    Write-RuntimeLog (
      "Workspace presented and verified. reason=$Reason " +
      "detachedForForeground=$($script:foregroundPresentationActive) " +
      "foregroundAccepted=$foregroundAccepted activationAccepted=$activationAccepted " +
      "owner=$($owner.ToInt64()) topmost=$nativeTopmost"
    )
    return $true
  } catch {
    if ($null -ne $presentedEvent) {
      $presentedEvent.Reset() | Out-Null
    }
    Write-RuntimeLog "Workspace presentation failed. reason=$Reason $($_.Exception.Message)"
    return $false
  }
}

function Complete-InitialPresentation {
  param([string]$Reason = 'initial launch')

  if (-not (Show-WorkspaceFromTray -Reason $Reason)) {
    return $false
  }
  $script:initialPresentationDone = $true
  if (-not $script:readySignalSent -and $null -ne $readyEvent) {
    $script:readySignalSent = $true
    $readyEvent.Set() | Out-Null
    Write-RuntimeLog 'Workspace UI ready signal set after verified presentation.'
  }
  return $true
}

function Hide-WorkspaceToTray {
  if (-not $script:window.IsVisible) {
    return
  }
  Save-State
  $script:window.Hide()
  $script:foregroundPresentationActive = $false
  $script:foregroundPresentationActivated = $false
  Write-RuntimeLog 'Workspace hidden to tray.'
  if (-not $script:trayHintShown -and $null -ne $script:trayIcon) {
    $script:trayHintShown = $true
    $script:trayIcon.BalloonTipTitle = 'Workspace is still running'
    $script:trayIcon.BalloonTipText = 'Right-click the tray icon and choose Exit to stop the process.'
    $script:trayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $script:trayIcon.ShowBalloonTip(2500)
  }
}

function Exit-WorkspaceWidget {
  $script:allowExit = $true
  Write-RuntimeLog 'Workspace exit requested from tray.'
  if ($null -ne $script:trayIcon) {
    $script:trayIcon.Visible = $false
  }
  $script:window.Close()
}

function Set-AutostartUiFromResult {
  param([Parameter(Mandatory = $true)]$Result)

  $userCanControl = if (
    $Result.PSObject.Properties.Name -contains 'userCanControl'
  ) {
    [bool]$Result.userCanControl
  } else {
    $true
  }
  $script:updatingAutostartCheck = $true
  try {
    switch ([string]$Result.state) {
      'Enabled' {
        $script:startWithWindowsCheck.IsThreeState = $false
        $script:startWithWindowsCheck.IsChecked = $true
        $script:startWithWindowsCheck.IsEnabled = $userCanControl
        $script:autostartStatusText.Text = if ($userCanControl) {
          'On'
        } else {
          'On · policy'
        }
        $script:startWithWindowsCheck.ToolTip = if ($userCanControl) {
          (
            'Workspace Widget starts after Windows sign-in. ' +
            'You can also control this in Windows Startup Apps settings.'
          )
        } else {
          'A Windows or organization policy keeps this startup entry enabled.'
        }
      }
      'Disabled' {
        $script:startWithWindowsCheck.IsThreeState = $false
        $script:startWithWindowsCheck.IsChecked = $false
        $script:startWithWindowsCheck.IsEnabled = $userCanControl
        $script:autostartStatusText.Text = 'Off'
        $script:startWithWindowsCheck.ToolTip = (
          'Turn this on to start Workspace Widget after Windows sign-in.'
        )
      }
      'DisabledByUser' {
        $script:startWithWindowsCheck.IsThreeState = $false
        $script:startWithWindowsCheck.IsChecked = $false
        $script:startWithWindowsCheck.IsEnabled = $false
        $script:autostartStatusText.Text = 'Off · Windows setting'
        $script:startWithWindowsCheck.ToolTip = (
          'Windows Startup Apps settings disabled Workspace Widget. ' +
          'Re-enable it from Settings > Apps > Startup.'
        )
      }
      'DisabledByPolicy' {
        $script:startWithWindowsCheck.IsThreeState = $true
        $script:startWithWindowsCheck.IsChecked = $null
        $script:startWithWindowsCheck.IsEnabled = $false
        $script:autostartStatusText.Text = 'Blocked by policy'
        $script:startWithWindowsCheck.ToolTip = (
          'A Windows or organization policy controls this startup entry.'
        )
      }
      'Missing' {
        $script:startWithWindowsCheck.IsThreeState = $false
        $script:startWithWindowsCheck.IsChecked = $false
        $script:startWithWindowsCheck.IsEnabled = $true
        $script:autostartStatusText.Text = 'Off · not registered'
        $script:startWithWindowsCheck.ToolTip = (
          'Turn this on to register Workspace Widget for Windows sign-in.'
        )
      }
      'Drifted' {
        $script:startWithWindowsCheck.IsThreeState = $true
        $script:startWithWindowsCheck.IsChecked = $null
        $script:startWithWindowsCheck.IsEnabled = $false
        $script:autostartStatusText.Text = 'Needs repair'
        $script:startWithWindowsCheck.ToolTip = (
          'The unpackaged development startup task needs repair.'
        )
      }
      'PermissionDenied' {
        $script:startWithWindowsCheck.IsThreeState = $true
        $script:startWithWindowsCheck.IsChecked = $null
        $script:startWithWindowsCheck.IsEnabled = $false
        $script:autostartStatusText.Text = 'Permission blocked'
        $script:startWithWindowsCheck.ToolTip = (
          'Windows did not allow this account to inspect or change startup.'
        )
      }
      default {
        $script:startWithWindowsCheck.IsThreeState = $true
        $script:startWithWindowsCheck.IsChecked = $null
        $script:startWithWindowsCheck.IsEnabled = $false
        $script:autostartStatusText.Text = 'Unavailable'
        $script:startWithWindowsCheck.ToolTip = 'Autostart status is unavailable.'
      }
    }
  } finally {
    $script:updatingAutostartCheck = $false
  }
}

function ConvertTo-ProcessArgument {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Contains('"')) {
    throw 'A process argument contains an unsupported quote character.'
  }
  return '"' + $Value + '"'
}

function Start-AutostartOperation {
  param(
    [ValidateSet('Get', 'Enable', 'Disable')]
    [string]$Action
  )

  if ($script:autostartBusy) {
    return
  }
  if (-not (Test-Path -LiteralPath $nativeHostPath -PathType Leaf)) {
    Set-AutostartUiFromResult -Result ([pscustomobject]@{ state = 'Unavailable' })
    Show-Toast -Message 'Workspace Widget host is missing'
    return
  }

  $script:autostartBusy = $true
  $script:autostartRequestedAction = $Action
  $script:startWithWindowsCheck.IsEnabled = $false
  $script:autostartStatusText.Text = if ($Action -eq 'Get') {
    'Checking...'
  } else {
    'Updating...'
  }

  try {
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $nativeHostPath
    $processInfo.Arguments = @(
      '--autostart', $Action,
      '--silent'
    ) -join ' '
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $processInfo.WorkingDirectory = $runtimeRoot
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $script:autostartProcess = [System.Diagnostics.Process]::new()
    $script:autostartProcess.StartInfo = $processInfo
    if (-not $script:autostartProcess.Start()) {
      throw 'Workspace Widget host did not start.'
    }
    $script:autostartStartedAt = Get-Date
    $script:autostartPollTimer.Start()
  } catch {
    $script:autostartBusy = $false
    $script:autostartProcess = $null
    $script:autostartStartedAt = $null
    Set-AutostartUiFromResult -Result ([pscustomobject]@{ state = 'PermissionDenied' })
    Write-RuntimeLog "Autostart $Action could not start. $($_.Exception.Message)"
    Show-Toast -Message 'Could not update Windows startup'
  }
}

function Complete-AutostartOperation {
  if ($null -eq $script:autostartProcess) {
    return
  }
  if (-not $script:autostartProcess.HasExited) {
    if (
      $null -eq $script:autostartStartedAt -or
      ((Get-Date) - $script:autostartStartedAt).TotalSeconds -lt 12
    ) {
      return
    }

    $timedOutProcess = $script:autostartProcess
    $timedOutAction = [string]$script:autostartRequestedAction
    try {
      $timedOutProcess.Kill()
      $timedOutProcess.WaitForExit(1000) | Out-Null
    } catch {
      Write-RuntimeLog "Autostart $timedOutAction timeout cleanup failed. $($_.Exception.Message)"
    }
    $script:autostartPollTimer.Stop()
    $script:autostartProcess = $null
    $script:autostartRequestedAction = $null
    $script:autostartStartedAt = $null
    $script:autostartBusy = $false
    $timedOutProcess.Dispose()
    Set-AutostartUiFromResult -Result ([pscustomobject]@{ state = 'Unavailable' })
    Write-RuntimeLog "Autostart $timedOutAction timed out after 12 seconds."
    Show-Toast -Message 'Windows startup check timed out'
    return
  }

  $script:autostartPollTimer.Stop()
  $requestedAction = [string]$script:autostartRequestedAction
  $process = $script:autostartProcess
  $script:autostartProcess = $null
  $script:autostartRequestedAction = $null
  $script:autostartStartedAt = $null
  $script:autostartBusy = $false

  try {
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $exitCode = $process.ExitCode
    $result = if ([string]::IsNullOrWhiteSpace($standardOutput)) {
      $null
    } else {
      $standardOutput | ConvertFrom-Json
    }

    if ($null -eq $result) {
      throw "No status was returned. $standardError"
    }
    Set-AutostartUiFromResult -Result $result

    if ($exitCode -eq 0 -and $result.success) {
      if (
        $requestedAction -eq 'Enable' -and
        [string]$result.state -eq 'Enabled'
      ) {
        Show-Toast -Message 'Starts with Windows at sign-in'
      } elseif ($requestedAction -eq 'Enable') {
        Show-Toast -Message 'Windows startup remains off'
      } elseif ($requestedAction -eq 'Disable') {
        Show-Toast -Message 'Windows startup is off'
      }
      Write-RuntimeLog (
        "Autostart $requestedAction completed. state=$($result.state) " +
        "changed=$($result.changed)"
      )
    } else {
      $errorMessage = if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
        [string]$result.error
      } else {
        $standardError
      }
      Write-RuntimeLog "Autostart $requestedAction failed. $errorMessage"
      Show-Toast -Message 'Autostart needs installer repair'
    }
  } catch {
    Set-AutostartUiFromResult -Result ([pscustomobject]@{ state = 'Unavailable' })
    Write-RuntimeLog "Autostart $requestedAction response failed. $($_.Exception.Message)"
    Show-Toast -Message 'Could not read Windows startup status'
  } finally {
    $process.Dispose()
  }
}

$script:minUiModeButton = New-ToolbarButton -Glyph '' -Label '' -AutomationName 'Switch to MIN UI'
$addToolbar = New-ToolbarButton -Glyph '' -Label 'Add' -AutomationName 'Add shortcut'
$opacityToolbar = New-ToolbarButton -Glyph '' -Label 'Opacity' -AutomationName 'Opacity controls'
$settingsToolbar = New-ToolbarButton -Glyph '' -Label 'Settings' -AutomationName 'Widget settings'
$closeToolbar = New-ToolbarButton -Glyph '' -Label '' -AutomationName 'Hide to tray'
$script:toolbar.Children.Add($script:minUiModeButton) | Out-Null
$script:toolbar.Children.Add($addToolbar) | Out-Null
$script:toolbar.Children.Add($opacityToolbar) | Out-Null
$script:toolbar.Children.Add($settingsToolbar) | Out-Null
$script:toolbar.Children.Add($closeToolbar) | Out-Null

$trayIconPath = Join-Path $ProjectRoot 'assets\workspace-widget.ico'
$script:trayIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:trayIcon.Icon = [System.Drawing.Icon]::new($trayIconPath)
$script:trayIcon.Text = 'Workspace Widget'
$script:trayIcon.Visible = $true
$script:trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$trayOpenItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Workspace')
$trayExitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
$trayOpenItem.Add_Click({
    $script:window.Dispatcher.BeginInvoke(
      [action]{ Show-WorkspaceFromTray }
    ) | Out-Null
  })
$trayExitItem.Add_Click({
    $script:window.Dispatcher.BeginInvoke(
      [action]{ Exit-WorkspaceWidget }
    ) | Out-Null
  })
$script:trayMenu.Items.Add($trayOpenItem) | Out-Null
$script:trayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$script:trayMenu.Items.Add($trayExitItem) | Out-Null
$script:trayIcon.ContextMenuStrip = $script:trayMenu
$script:trayIcon.Add_DoubleClick({
    $script:window.Dispatcher.BeginInvoke(
      [action]{ Show-WorkspaceFromTray }
    ) | Out-Null
  })
Write-RuntimeLog 'Workspace tray icon ready.'

$script:showEventTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:showEventTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:showEventTimer.Add_Tick({
    if ($null -ne $showEvent -and $showEvent.WaitOne(0)) {
      Show-WorkspaceFromTray -Reason 'existing-instance request' | Out-Null
    }
  })
$script:showEventTimer.Start()

$script:opacitySlider.Value = $script:baseOpacity
$script:opacityValue.Text = '{0:P0}' -f $script:baseOpacity
$script:hoverBrightnessCheck.IsChecked = $script:hoverBrightness
$script:alwaysOnTopCheck.IsChecked = $script:alwaysOnTop
$script:minUiModeCheck.IsChecked = $script:minUiMode
$script:desktopLayerCheck.IsChecked = $script:attachToDesktopPreference
$script:desktopLayerCheck.IsEnabled = -not $NoDesktopAttach
$script:startWithWindowsCheck.IsThreeState = $true
$script:startWithWindowsCheck.IsChecked = $null
$script:startWithWindowsCheck.IsEnabled = $false
$script:showHiddenCheck.IsChecked = $false
$script:hoverOpacityHint.Text = if ($script:hoverBrightness) { 'Hover 100%' } else { 'Hover off' }
Set-MinUiMode -Enabled $script:minUiMode -Initial

$script:saveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:saveTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:saveTimer.Add_Tick({
    $script:saveTimer.Stop()
    Save-State
  })

$script:minUiSnapTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:minUiSnapTimer.Interval = [TimeSpan]::FromMilliseconds(420)
$script:minUiSnapTimer.Add_Tick({
    $script:minUiSnapTimer.Stop()
    if ($script:minUiMode) {
      Snap-MinUiToNearestEdge
      Save-State
    }
  })

$script:topmostReassertTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:topmostReassertTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$script:topmostReassertTimer.Add_Tick({
    $script:topmostReassertTimer.Stop()
    if ($script:window.IsVisible -and $script:alwaysOnTop) {
      Set-WindowLayerMode -Reason 'topmost focus transition' -Quiet | Out-Null
    } elseif (
      $script:window.IsVisible -and
      $script:foregroundPresentationActive -and
      $script:foregroundPresentationActivated
    ) {
      $script:foregroundPresentationActive = $false
      $script:foregroundPresentationActivated = $false
      Set-WindowLayerMode -Reason 'verified focus loss' -Quiet | Out-Null
    }
  })

$script:initialPresentationRetryTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:initialPresentationRetryTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:initialPresentationRetryTimer.Add_Tick({
    $script:initialPresentationAttempts++
    if (Complete-InitialPresentation -Reason "initial retry $($script:initialPresentationAttempts)") {
      $script:initialPresentationRetryTimer.Stop()
    } elseif ($script:initialPresentationAttempts -ge 8) {
      $script:initialPresentationRetryTimer.Stop()
      Write-RuntimeLog 'Initial presentation retries exhausted; readiness was not signaled.'
    }
  })

$script:toastTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:toastTimer.Interval = [TimeSpan]::FromSeconds(2.4)
$script:toastTimer.Add_Tick({
    $script:toastTimer.Stop()
    $script:toastBorder.Visibility = [System.Windows.Visibility]::Collapsed
  })

$script:backgroundGifTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:backgroundGifTimer.Interval = [TimeSpan]::FromMilliseconds(90)
$script:backgroundGifTimer.Add_Tick({
    if ($script:backgroundGifFrames.Count -eq 0) {
      $script:backgroundGifTimer.Stop()
      return
    }
    $script:backgroundGifIndex = (
      $script:backgroundGifIndex + 1
    ) % $script:backgroundGifFrames.Count
    $script:backgroundImage.Source = $script:backgroundGifFrames[
      $script:backgroundGifIndex
    ]
  })
$script:hoverGifTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:hoverGifTimer.Interval = [TimeSpan]::FromMilliseconds(90)
$script:hoverGifTimer.Add_Tick({
    if ($script:hoverGifFrames.Count -eq 0) {
      $script:hoverGifTimer.Stop()
      return
    }
    $script:hoverGifIndex = (
      $script:hoverGifIndex + 1
    ) % $script:hoverGifFrames.Count
    $script:hoverPreviewImage.Source = $script:hoverGifFrames[
      $script:hoverGifIndex
    ]
  })
$script:backgroundVideo.Add_MediaEnded({
    $script:backgroundVideo.Position = [TimeSpan]::Zero
    $script:backgroundVideo.Play()
  })
$script:hoverPreviewVideo.Add_MediaEnded({
    $script:hoverPreviewVideo.Position = [TimeSpan]::Zero
    $script:hoverPreviewVideo.Play()
  })
$script:backgroundVideo.Add_MediaFailed({
    $message = $args[1].ErrorException.Message
    Write-RuntimeLog "Background video playback failed. $message"
    Stop-BackgroundMedia
    $script:backgroundTint.Fill = Convert-ToBrush $script:themePalette.panel
    Show-Toast 'Background video could not be played on this PC.'
  })
$script:hoverPreviewVideo.Add_MediaFailed({
    $message = $args[1].ErrorException.Message
    Write-RuntimeLog "Hover video playback failed. $message"
    Show-HoverMediaFallback -Reason 'video preview unavailable'
  })

$script:autostartPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:autostartPollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:autostartPollTimer.Add_Tick({
    Complete-AutostartOperation
  })

$script:httpClientHandler = [System.Net.Http.HttpClientHandler]::new()
$script:httpClientHandler.AllowAutoRedirect = $false
$script:httpClientHandler.UseCookies = $false
$script:httpClientHandler.UseDefaultCredentials = $false
$script:httpClient = [System.Net.Http.HttpClient]::new($script:httpClientHandler)
$script:httpClient.Timeout = [TimeSpan]::FromSeconds(3)
$script:httpClient.DefaultRequestHeaders.UserAgent.ParseAdd('WorkspaceServiceWidget/2.0')

$script:healthPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:healthPollTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:healthPollTimer.Add_Tick({
    $finished = @($script:pendingHealth | Where-Object { $_.task.IsCompleted }).Count
    $expired = ((Get-Date) - $script:healthStartedAt).TotalSeconds -gt 4
    if ($finished -eq @($script:pendingHealth).Count -or $expired) {
      $script:healthPollTimer.Stop()
      Complete-HealthCheck
    }
  })

$script:healthTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:healthTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:healthTimer.Add_Tick({ Start-HealthCheck })
$script:healthTimer.Start()

$script:startupPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:startupPollTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:startupPollTimer.Add_Tick({
    if ($script:pendingOpen.Count -eq 0) {
      $script:startupPollTimer.Stop()
    } else {
      Start-HealthCheck
    }
  })

Apply-Appearance -SkipRender

$script:scrollRenderingHandler = [EventHandler]{
  param($sender, $eventArgs)

  if (-not $script:scrollAnimationActive) {
    return
  }

  $nowTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
  $elapsedMs = (
    ($nowTicks - $script:scrollAnimationStartTicks) * 1000.0 /
    [System.Diagnostics.Stopwatch]::Frequency
  )
  $progress = [math]::Min(1.0, $elapsedMs / $script:scrollAnimationDurationMs)
  $smoothProgress = (
    $progress * $progress * $progress *
    (($progress * (($progress * 6.0) - 15.0)) + 10.0)
  )
  $offset = (
    $script:scrollAnimationStartOffset +
    (($script:scrollTarget - $script:scrollAnimationStartOffset) * $smoothProgress)
  )

  $script:scrollViewer.ScrollToVerticalOffset($offset)
  $script:scrollAnimationFrames++
  Update-PageDots

  if ($progress -ge 1.0) {
    $script:scrollViewer.ScrollToVerticalOffset($script:scrollTarget)
    $script:scrollAnimationActive = $false
    Update-PageDots
    $effectiveHz = if ($elapsedMs -gt 0) {
      [math]::Round($script:scrollAnimationFrames / ($elapsedMs / 1000.0), 1)
    } else {
      0
    }
    Write-RuntimeLog (
      "Smooth scroll complete. frames=$($script:scrollAnimationFrames) " +
      "durationMs=$([math]::Round($elapsedMs)) renderHz=$effectiveHz"
    )
  }
}
[System.Windows.Media.CompositionTarget]::add_Rendering($script:scrollRenderingHandler)

$addToolbar.Add_Click({ Show-ItemDialog | Out-Null })
$script:addShortcutButton.Add_Click({ Show-ItemDialog | Out-Null })
$closeToolbar.Add_Click({ Hide-WorkspaceToTray })
$script:minUiModeButton.Add_Click({
    Set-MinUiMode -Enabled (-not $script:minUiMode)
  })
$opacityToolbar.Add_Click({
    if ($script:minUiMode) {
      Set-MinUiMode -Enabled $false
    }
    $script:opacityPanel.Visibility = if ($script:opacityPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
      [System.Windows.Visibility]::Collapsed
    } else {
      [System.Windows.Visibility]::Visible
    }
    $script:settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
    Update-WidgetOpacity
  })
$settingsToolbar.Add_Click({
    if ($script:minUiMode) {
      Set-MinUiMode -Enabled $false
    }
    $script:settingsPanel.Visibility = if ($script:settingsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
      [System.Windows.Visibility]::Collapsed
    } else {
      [System.Windows.Visibility]::Visible
    }
    if (
      $script:settingsPanel.Visibility -eq [System.Windows.Visibility]::Visible -and
      -not $script:autostartBusy
    ) {
      Start-AutostartOperation -Action Get
    }
    $script:opacityPanel.Visibility = [System.Windows.Visibility]::Collapsed
    Update-WidgetOpacity
  })
$script:appearanceButton.Add_Click({
    Show-AppearanceDialog | Out-Null
  })

$script:opacitySlider.Add_ValueChanged({
    if ($script:applyingUiMode) {
      return
    }
    $script:baseOpacity = [double]$script:opacitySlider.Value
    $script:opacityValue.Text = '{0:P0}' -f $script:baseOpacity
    Update-WidgetOpacity -ForceBase
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:hoverBrightnessCheck.Add_Checked({
    $script:hoverBrightness = $true
    Update-WidgetOpacity
    Write-RuntimeLog 'Hover brightness changed. enabled=True'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:hoverBrightnessCheck.Add_Unchecked({
    $script:hoverBrightness = $false
    Update-WidgetOpacity
    Write-RuntimeLog 'Hover brightness changed. enabled=False'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:alwaysOnTopCheck.Add_Checked({
    $script:alwaysOnTop = $true
    Set-WindowLayerMode -Reason 'setting enabled' | Out-Null
    Write-RuntimeLog 'Always on top changed. enabled=True'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:alwaysOnTopCheck.Add_Unchecked({
    $script:alwaysOnTop = $false
    Set-WindowLayerMode -Reason 'setting disabled' | Out-Null
    Write-RuntimeLog 'Always on top changed. enabled=False'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:desktopLayerCheck.Add_Checked({
    $script:attachToDesktopPreference = $true
    $script:attachToDesktop = -not $NoDesktopAttach
    Set-WindowLayerMode -Reason 'desktop layer enabled' | Out-Null
    Write-RuntimeLog "Desktop layer changed. enabled=$($script:attachToDesktop)"
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:desktopLayerCheck.Add_Unchecked({
    $script:attachToDesktopPreference = $false
    $script:attachToDesktop = $false
    $script:foregroundPresentationActive = $false
    Set-WindowLayerMode -Reason 'desktop layer disabled' | Out-Null
    Write-RuntimeLog 'Desktop layer changed. enabled=False'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:minUiModeCheck.Add_Checked({
    if (-not $script:applyingUiMode -and -not $script:minUiMode) {
      Set-MinUiMode -Enabled $true
    }
  })
$script:minUiModeCheck.Add_Unchecked({
    if (-not $script:applyingUiMode -and $script:minUiMode) {
      Set-MinUiMode -Enabled $false
    }
  })
$script:startWithWindowsCheck.Add_Checked({
    if (-not $script:updatingAutostartCheck) {
      Start-AutostartOperation -Action Enable
    }
  })
$script:startWithWindowsCheck.Add_Unchecked({
    if (-not $script:updatingAutostartCheck) {
      Start-AutostartOperation -Action Disable
    }
  })
$script:showHiddenCheck.Add_Checked({ Render-Items })
$script:showHiddenCheck.Add_Unchecked({ Render-Items })
  $script:resetSizeButton.Add_Click({
    $script:window.Width = 552
    $script:window.Height = 640
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:window.Left = [Math]::Max(
      $workArea.Left + 16,
      $workArea.Right - $script:window.Width - 24
    )
    $script:window.Top = $workArea.Top + 24
    Ensure-WindowVisible -Reason 'reset size' -Quiet | Out-Null
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:refreshButton.Add_Click({ Start-HealthCheck })
function Start-BottomRightResize {
  param($EventArgs)

  $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
  [WorkspaceWidgetNative]::ReleaseCapture() | Out-Null
  [WorkspaceWidgetNative]::SendMessage(
    $helper.Handle,
    0x00A1,
    [IntPtr][WorkspaceWidgetNative]::HTBOTTOMRIGHT,
    [IntPtr]::Zero
  ) | Out-Null
  $EventArgs.Handled = $true
}

$script:windowResizeGrip.Add_PreviewMouseLeftButtonDown({ Start-BottomRightResize -EventArgs $args[1] })
$script:resizeHandle.Add_PreviewMouseLeftButtonDown({ Start-BottomRightResize -EventArgs $args[1] })

$script:header.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left -and
        $eventArgs.OriginalSource -isnot [System.Windows.Controls.Button]) {
      try {
        $script:window.DragMove()
        if ($script:minUiMode) {
          Snap-MinUiToNearestEdge
          Save-State
        }
      } catch {
        # DragMove can throw when the mouse is released between event dispatches.
      }
    }
  })

$script:window.Add_MouseEnter({
    Update-WidgetOpacity
  })
$script:window.Add_MouseLeave({
    Update-WidgetOpacity -ForceBase
  })
$script:window.Add_LocationChanged({
    if (
      $script:minUiMode -and
      -not $script:applyingUiMode -and
      -not $script:snappingMinUi
    ) {
      $script:minUiSnapTimer.Stop()
      $script:minUiSnapTimer.Start()
    }
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
  })
$script:window.Add_SizeChanged({
    Update-ResponsiveHeader
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
    $script:scrollAnimationActive = $false
    $maximumOffset = [math]::Max(
      0.0,
      $script:scrollViewer.ExtentHeight - $script:scrollViewer.ViewportHeight
    )
    $script:scrollTarget = [math]::Min($maximumOffset, $script:scrollViewer.VerticalOffset)
    Update-PageDots
  })

$script:window.Add_PreviewMouseWheel({
    param($sender, $eventArgs)
    $maximum = [math]::Max(0.0, $script:scrollViewer.ExtentHeight - $script:scrollViewer.ViewportHeight)
    $step = [math]::Max(110.0, $script:scrollViewer.ViewportHeight * 0.72)
    $direction = if ($eventArgs.Delta -lt 0) { 1 } else { -1 }
    $currentOffset = $script:scrollViewer.VerticalOffset
    $baseOffset = if ($script:scrollAnimationActive) {
      $script:scrollTarget
    } else {
      $currentOffset
    }
    $script:scrollTarget = [math]::Max(
      0.0,
      [math]::Min($maximum, $baseOffset + ($direction * $step))
    )
    $distance = [math]::Abs($script:scrollTarget - $currentOffset)
    $script:scrollAnimationStartOffset = $currentOffset
    $script:scrollAnimationStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $script:scrollAnimationDurationMs = [math]::Min(
      340.0,
      [math]::Max(210.0, 175.0 + ($distance * 0.18))
    )
    $script:scrollAnimationFrames = 0
    $script:scrollAnimationActive = $distance -gt 0.5
    $eventArgs.Handled = $true
  })

$script:window.Add_DragEnter({
    param($sender, $eventArgs)
    $targets = Get-DropTargets -Data $eventArgs.Data
    Write-RuntimeLog "DragEnter formats=$($eventArgs.Data.GetFormats() -join ',') targets=$(@($targets).Count)"
    if (@($targets).Count -gt 0) {
      $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
      $script:dropOverlay.Visibility = [System.Windows.Visibility]::Visible
      $script:dropText.Visibility = [System.Windows.Visibility]::Visible
    } else {
      $eventArgs.Effects = [System.Windows.DragDropEffects]::None
    }
    $eventArgs.Handled = $true
  })
$script:window.Add_DragOver({
    param($sender, $eventArgs)
    $targets = Get-DropTargets -Data $eventArgs.Data
    $eventArgs.Effects = if (@($targets).Count -gt 0) {
      [System.Windows.DragDropEffects]::Copy
    } else {
      [System.Windows.DragDropEffects]::None
    }
    $eventArgs.Handled = $true
  })
$script:window.Add_DragLeave({
    $script:dropOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    $script:dropText.Visibility = [System.Windows.Visibility]::Collapsed
  })
$script:window.Add_Drop({
    param($sender, $eventArgs)
    $script:dropOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    $script:dropText.Visibility = [System.Windows.Visibility]::Collapsed
    $targets = Get-DropTargets -Data $eventArgs.Data
    Write-RuntimeLog "Drop formats=$($eventArgs.Data.GetFormats() -join ',') targets=$(@($targets).Count)"
    if (@($targets).Count -gt 0) {
      Add-Targets -Targets @($targets)
      $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
    }
    $eventArgs.Handled = $true
  })

$script:window.Add_SourceInitialized({
    Ensure-WindowVisible -Reason 'source initialized' | Out-Null
    Set-WindowLayerMode -Reason 'source initialized' | Out-Null
    if ($script:minUiMode) {
      Snap-MinUiToNearestEdge
    }
  })

$script:window.Add_Activated({
    if ($script:foregroundPresentationActive) {
      $script:foregroundPresentationActivated = $true
    }
  })

$script:window.Add_Deactivated({
    if (
      $script:window.IsVisible -and
      (
        $script:alwaysOnTop -or
        (
          $script:foregroundPresentationActive -and
          $script:foregroundPresentationActivated
        )
      )
    ) {
      $script:topmostReassertTimer.Stop()
      $script:topmostReassertTimer.Start()
    }
  })

$script:window.Add_Loaded({
    Render-Items
    Save-State
    $script:scrollTarget = $script:scrollViewer.VerticalOffset
    Update-PageDots
    if ([string]::IsNullOrWhiteSpace($CapturePath)) {
      Start-AutostartOperation -Action Get
      $startupOpacity = if ($script:hoverBrightness -and $script:window.IsMouseOver) {
        1.0
      } else {
        $script:baseOpacity
      }
      $script:window.Opacity = $startupOpacity
      $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(
        0.0,
        $startupOpacity,
        [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
      )
      $fadeIn.EasingFunction = [System.Windows.Media.Animation.CubicEase]::new()
      $fadeIn.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
      $fadeIn.Add_Completed({
          Update-WidgetOpacity
        })
      $script:window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)
    }
    if (-not [string]::IsNullOrWhiteSpace($CapturePath)) {
      $script:captureTimer = [System.Windows.Threading.DispatcherTimer]::new()
      $script:captureTimer.Interval = [TimeSpan]::FromMilliseconds([math]::Max(250, $CaptureDelayMs))
      $script:captureTimer.Add_Tick({
          $script:captureTimer.Stop()
          Capture-Widget -Path $CapturePath
          $script:window.Close()
        })
      $script:captureTimer.Start()
    }
  })

$script:window.Add_ContentRendered({
    Set-WindowLayerMode -Reason 'first render' | Out-Null
    if (-not $script:initialPresentationDone) {
      if (-not (Complete-InitialPresentation -Reason 'initial launch')) {
        $script:initialPresentationAttempts = 0
        $script:initialPresentationRetryTimer.Start()
      }
    }
  })

$script:window.Add_Closing({
    param($sender, $eventArgs)
    if (
      -not $script:allowExit -and
      [string]::IsNullOrWhiteSpace($CapturePath)
    ) {
      $eventArgs.Cancel = $true
      Hide-WorkspaceToTray
    }
  })

$script:window.Add_Closed({
    try {
      $script:saveTimer.Stop()
      $script:healthTimer.Stop()
      $script:healthPollTimer.Stop()
      $script:startupPollTimer.Stop()
      if ($null -ne $script:showEventTimer) {
        $script:showEventTimer.Stop()
      }
      if ($null -ne $script:minUiSnapTimer) {
        $script:minUiSnapTimer.Stop()
      }
      if ($null -ne $script:topmostReassertTimer) {
        $script:topmostReassertTimer.Stop()
      }
      if ($null -ne $script:initialPresentationRetryTimer) {
        $script:initialPresentationRetryTimer.Stop()
      }
      if ($null -ne $script:autostartPollTimer) {
        $script:autostartPollTimer.Stop()
      }
      Stop-HoverMediaPreview
      Stop-BackgroundMedia
      if ($null -ne $script:backgroundGifTimer) {
        $script:backgroundGifTimer.Stop()
      }
      if ($null -ne $script:hoverGifTimer) {
        $script:hoverGifTimer.Stop()
      }
      if ($null -ne $script:hoverWebView) {
        $script:hoverWebView.Dispose()
        $script:hoverWebView = $null
      }
      if ($null -ne $script:autostartProcess) {
        $script:autostartProcess.Dispose()
        $script:autostartProcess = $null
      }
      $script:scrollAnimationActive = $false
      [System.Windows.Media.CompositionTarget]::remove_Rendering($script:scrollRenderingHandler)
      if ($null -ne $script:trayIcon) {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
      }
      if ($null -ne $script:trayMenu) {
        $script:trayMenu.Dispose()
      }
      if ($null -ne $showEvent) {
        $showEvent.Dispose()
      }
      if ($null -ne $readyEvent) {
        $readyEvent.Dispose()
      }
      if ($null -ne $presentedEvent) {
        $presentedEvent.Dispose()
      }
      Save-State
      $script:httpClient.Dispose()
      $mutex.ReleaseMutex()
      $mutex.Dispose()
    } catch {
      Write-RuntimeLog "Shutdown cleanup failed. $($_.Exception.Message)"
    }
  })

Write-RuntimeLog "Workspace widget starting. State='$StatePath'."
$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$application.Add_DispatcherUnhandledException({
    param($sender, $eventArgs)
    Write-RuntimeLog "Unhandled UI error. $($eventArgs.Exception.ToString())"
    $eventArgs.Handled = $true
  })
try {
  $application.Run($script:window) | Out-Null
} catch {
  Write-RuntimeLog "Application failed. $($_.Exception.ToString())"
  throw
}
