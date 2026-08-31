[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$TaskName = 'Workspace Service Widget',
  [string]$TaskPath = '\',
  [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'),
  [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Workspace Widget.lnk'),
  [switch]$ExerciseAutostart,
  [switch]$InstalledProduct
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$appScript = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$hostSource = Join-Path $ProjectRoot 'native\WorkspaceWidgetHost.cs'
$defaultStatePath = Join-Path $ProjectRoot 'app\default-state.json'
$publicDefaultStatePath = Join-Path $ProjectRoot 'app\public-default-state.json'
$startScript = Join-Path $ProjectRoot 'scripts\Start-WorkspaceWidget.ps1'
$autostartScript = Join-Path $ProjectRoot 'scripts\Set-WorkspaceWidgetAutostart.ps1'
$installScript = Join-Path $ProjectRoot 'scripts\Install-WorkspaceWidget.ps1'
$nodeRestoreScript = Join-Path `
  $ProjectRoot `
  'scripts\Restore-WorkspaceWidgetNodeRuntime.ps1'
$releaseVerifier = Join-Path `
  $ProjectRoot `
  'scripts\Test-WorkspaceWidgetRelease.ps1'
$networkBoundaryTest = Join-Path `
  $ProjectRoot `
  'scripts\Test-WorkspaceWidgetNetworkBoundary.ps1'
$officialSecurityTest = Join-Path `
  $ProjectRoot `
  'scripts\Test-OfficialSecurityBaseline.ps1'
$officialSecurityBaseline = Join-Path `
  $ProjectRoot `
  'security\official-security-baseline.json'
$officialSecurityReview = Join-Path `
  $ProjectRoot `
  'security\official-security-review.json'
$iconBuilder = Join-Path $ProjectRoot 'scripts\New-WorkspaceWidgetIcon.ps1'
$semanticIconTest = Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidgetSemanticIcons.ps1'
$semanticIconManifest = Join-Path $ProjectRoot 'assets\semantic-icons\manifest.json'
$baseBuilder = Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidget.ps1'
$msixBuilder = Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidgetMsix.ps1'
$msixVerifier = Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidgetMsix.ps1'
$msixManifestTemplate = Join-Path `
  $ProjectRoot `
  'packaging\msix\AppxManifest.template.xml'
$storeReleaseGuide = Join-Path $ProjectRoot 'docs\MICROSOFT-STORE-RELEASE.md'
$privacyPolicy = Join-Path $ProjectRoot 'PRIVACY.md'
$shortcutIcon = Join-Path $ProjectRoot 'assets\workspace-widget.ico'
$shortcutLogo = Join-Path $ProjectRoot 'assets\workspace-widget-logo.png'
$nodeFixture = Join-Path $ProjectRoot 'tests\fixtures\node-health-app\server.js'
$shortcutFixtureRoot = Join-Path `
  ([System.IO.Path]::GetTempPath()) `
  'WorkspaceWidgetTests'
$shortcutFixture = Join-Path `
  $shortcutFixtureRoot `
  'shortcut-resolution-fixture.lnk'
$gitIgnorePath = Join-Path $ProjectRoot '.gitignore'
$rainmeterIni = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
$installedRoot = Join-Path $env:LOCALAPPDATA 'Programs\WorkspaceWidget'
$installedHostPath = Join-Path $installedRoot 'WorkspaceWidget.exe'
$configuredHostCandidates = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
  $configuredShell = $null
  $configuredShortcut = $null
  try {
    $configuredShell = New-Object -ComObject WScript.Shell
    $configuredShortcut = $configuredShell.CreateShortcut($ShortcutPath)
    if (-not [string]::IsNullOrWhiteSpace([string]$configuredShortcut.TargetPath)) {
      $configuredHostCandidates.Add([string]$configuredShortcut.TargetPath)
    }
  } finally {
    if (
      $null -ne $configuredShortcut -and
      [Runtime.InteropServices.Marshal]::IsComObject($configuredShortcut)
    ) {
      [void][Runtime.InteropServices.Marshal]::ReleaseComObject($configuredShortcut)
    }
    if (
      $null -ne $configuredShell -and
      [Runtime.InteropServices.Marshal]::IsComObject($configuredShell)
    ) {
      [void][Runtime.InteropServices.Marshal]::ReleaseComObject($configuredShell)
    }
  }
}
$configuredTask = Get-ScheduledTask `
  -TaskName $TaskName `
  -TaskPath $TaskPath `
  -ErrorAction SilentlyContinue
if ($null -ne $configuredTask) {
  $configuredHostCandidates.Add([string]$configuredTask.Actions[0].Execute)
}
$configuredHostCandidates.Add($installedHostPath)
$installedPrefix = $installedRoot.TrimEnd('\') + '\'
$installedHostPath = @(
  $configuredHostCandidates |
    Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and
      (Test-Path -LiteralPath $_ -PathType Leaf) -and
      [System.IO.Path]::GetFullPath($_).StartsWith(
        $installedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
      ) -and
      [System.IO.Path]::GetFileName($_) -ieq 'WorkspaceWidget.exe'
    } |
    Select-Object -First 1
)[0]
$runtimeProjectRoot = $ProjectRoot
$runtimeAppScript = $appScript
if ($InstalledProduct) {
  if (
    [string]::IsNullOrWhiteSpace($installedHostPath) -or
    -not (Test-Path -LiteralPath $installedHostPath -PathType Leaf)
  ) {
    throw 'InstalledProduct was requested, but no installed content-addressed host was found.'
  }
  $runtimeProjectRoot = Split-Path -Parent $installedHostPath
  $runtimeAppScript = Join-Path $runtimeProjectRoot 'app\WorkspaceWidget.ps1'
}

if (-not (Test-Path -LiteralPath $shortcutFixtureRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $shortcutFixtureRoot -Force | Out-Null
}
$shortcutShell = $null
$shortcutObject = $null
try {
  $shortcutShell = New-Object -ComObject WScript.Shell
  $shortcutObject = $shortcutShell.CreateShortcut($shortcutFixture)
  $shortcutObject.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'
  $shortcutObject.Arguments = '"{0}"' -f (Join-Path $env:WINDIR 'win.ini')
  $shortcutObject.WorkingDirectory = Join-Path $env:WINDIR 'System32'
  $shortcutObject.IconLocation = '{0},0' -f (
    Join-Path $env:WINDIR 'System32\notepad.exe'
  )
  $shortcutObject.WindowStyle = 3
  $shortcutObject.Save()
} finally {
  if (
    $null -ne $shortcutObject -and
    [Runtime.InteropServices.Marshal]::IsComObject($shortcutObject)
  ) {
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject(
      $shortcutObject
    ) | Out-Null
  }
  if (
    $null -ne $shortcutShell -and
    [Runtime.InteropServices.Marshal]::IsComObject($shortcutShell)
  ) {
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject(
      $shortcutShell
    ) | Out-Null
  }
}

$requiredFiles = @(
    $appScript,
    $hostSource,
    $defaultStatePath,
    $publicDefaultStatePath,
    $startScript,
    $autostartScript,
  $installScript,
  $nodeRestoreScript,
  $releaseVerifier,
  $networkBoundaryTest,
  $officialSecurityTest,
  $officialSecurityBaseline,
  $officialSecurityReview,
  $iconBuilder,
  $semanticIconTest,
  $semanticIconManifest,
  $baseBuilder,
  $msixBuilder,
  $msixVerifier,
  $msixManifestTemplate,
  $storeReleaseGuide,
  $privacyPolicy,
  $shortcutIcon,
  $shortcutLogo,
  $nodeFixture,
  $shortcutFixture,
  $gitIgnorePath,
  $runtimeAppScript,
  $StatePath,
  $ShortcutPath
)

$files = foreach ($file in $requiredFiles) {
  [pscustomobject]@{
    path = $file
    exists = Test-Path -LiteralPath $file -PathType Leaf
  }
}

$defaultState = Get-Content -LiteralPath $defaultStatePath -Raw | ConvertFrom-Json
$publicDefaultState = Get-Content `
  -LiteralPath $publicDefaultStatePath `
  -Raw |
  ConvertFrom-Json
$runtimeState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$probe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $runtimeAppScript `
  -ProjectRoot $runtimeProjectRoot `
  -StatePath $StatePath `
  -Probe | ConvertFrom-Json
$semanticIconProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $semanticIconTest `
  -ProjectRoot $ProjectRoot | ConvertFrom-Json
$portListener = [System.Net.Sockets.TcpListener]::new(
  [System.Net.IPAddress]::Loopback,
  0
)
$portListener.Start()
$startupProbePort = ([System.Net.IPEndPoint]$portListener.LocalEndpoint).Port
$portListener.Stop()
$startupProbeNonce = [guid]::NewGuid().ToString('N')
$startupProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $runtimeAppScript `
  -ProjectRoot $runtimeProjectRoot `
  -StartupProbe `
  -StartupProbeTarget $nodeFixture `
  -StartupProbeHealth "http://127.0.0.1:$startupProbePort/health" `
  -StartupProbeArgs "$startupProbePort $startupProbeNonce" `
  -StartupProbeExpectedToken $startupProbeNonce | ConvertFrom-Json
$shortcutProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -ExecutionPolicy Bypass `
  -File $runtimeAppScript `
  -ProjectRoot $runtimeProjectRoot `
  -ShortcutProbePath $shortcutFixture | ConvertFrom-Json
$geometryProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $appScript `
  -ProjectRoot $ProjectRoot `
  -GeometryProbe | ConvertFrom-Json
$stateRecoveryRoot = Join-Path `
  ([System.IO.Path]::GetTempPath()) `
  ('WorkspaceWidgetStateRecovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateRecoveryRoot -Force | Out-Null
$stateRecoveryPath = Join-Path $stateRecoveryRoot 'state.json'
$futureState = Get-Content -LiteralPath $defaultStatePath -Raw | ConvertFrom-Json
$futureState.schemaVersion = 99
$previousState = Get-Content -LiteralPath $defaultStatePath -Raw | ConvertFrom-Json
[System.IO.File]::WriteAllText(
  $stateRecoveryPath,
  ($futureState | ConvertTo-Json -Depth 10),
  [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
  "$stateRecoveryPath.previous",
  ($previousState | ConvertTo-Json -Depth 10),
  [System.Text.UTF8Encoding]::new($false)
)
$futureStateHashBefore = (Get-FileHash -LiteralPath $stateRecoveryPath -Algorithm SHA256).Hash
$futurePreviousHashBefore = (Get-FileHash -LiteralPath "$stateRecoveryPath.previous" -Algorithm SHA256).Hash
$futureStateProbeOutput = @(
  & powershell.exe `
    -NoProfile `
    -NonInteractive `
    -STA `
    -ExecutionPolicy Bypass `
    -File $appScript `
    -ProjectRoot $ProjectRoot `
    -StatePath $stateRecoveryPath `
    -StateLifecycleProbe 2>&1
)
$futureStateProbeExit = $LASTEXITCODE
$futureStateProbe = ($futureStateProbeOutput -join [Environment]::NewLine) |
  ConvertFrom-Json
$futureStateHashAfter = (Get-FileHash -LiteralPath $stateRecoveryPath -Algorithm SHA256).Hash
$futurePreviousHashAfter = (Get-FileHash -LiteralPath "$stateRecoveryPath.previous" -Algorithm SHA256).Hash

$malformedStatePath = Join-Path $stateRecoveryRoot 'malformed-state.json'
[System.IO.File]::WriteAllText(
  $malformedStatePath,
  '{not valid json',
  [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
  "$malformedStatePath.previous",
  ($previousState | ConvertTo-Json -Depth 10),
  [System.Text.UTF8Encoding]::new($false)
)
$stateRecoveryProbe = & powershell.exe `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $appScript `
  -ProjectRoot $ProjectRoot `
  -StatePath $malformedStatePath `
  -Probe | ConvertFrom-Json

$packageIsolationRoot = Join-Path `
  ([System.IO.Path]::GetTempPath()) `
  ('WorkspaceWidgetPackageIsolation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $packageIsolationRoot -Force | Out-Null
[System.IO.File]::WriteAllBytes(
  (Join-Path $packageIsolationRoot 'WorkspaceWidget.exe'),
  [byte[]]@(0)
)
$packageIsolationState = Join-Path $packageIsolationRoot 'state.json'
Copy-Item -LiteralPath $defaultStatePath -Destination $packageIsolationState
$previousNodeOverride = $env:WORKSPACE_WIDGET_NODE
try {
  $env:WORKSPACE_WIDGET_NODE = Join-Path $env:WINDIR 'System32\notepad.exe'
  $packageIsolationProbe = & powershell.exe `
    -NoProfile `
    -NonInteractive `
    -STA `
    -ExecutionPolicy Bypass `
    -File $appScript `
    -ProjectRoot $packageIsolationRoot `
    -StatePath $packageIsolationState `
    -Probe | ConvertFrom-Json
} finally {
  if ($null -eq $previousNodeOverride) {
    Remove-Item Env:WORKSPACE_WIDGET_NODE -ErrorAction SilentlyContinue
  } else {
    $env:WORKSPACE_WIDGET_NODE = $previousNodeOverride
  }
}

$appContent = Get-Content -LiteralPath $appScript -Raw
$hostContent = Get-Content -LiteralPath $hostSource -Raw
$startContent = Get-Content -LiteralPath $startScript -Raw
$installContent = Get-Content -LiteralPath $installScript -Raw
$autostartContent = Get-Content -LiteralPath $autostartScript -Raw
$gitIgnoreContent = Get-Content -LiteralPath $gitIgnorePath -Raw
$privateEvidenceIgnorePattern = '(?m)^' +
  [regex]::Escape(('qual' + 'ity/')) +
  '\r?$'
$nodeRestoreContent = Get-Content -LiteralPath $nodeRestoreScript -Raw
$releaseVerifierContent = Get-Content -LiteralPath $releaseVerifier -Raw
$baseBuilderContent = Get-Content -LiteralPath $baseBuilder -Raw
$msixBuilderContent = Get-Content -LiteralPath $msixBuilder -Raw
$msixVerifierContent = Get-Content -LiteralPath $msixVerifier -Raw
$msixManifestContent = Get-Content -LiteralPath $msixManifestTemplate -Raw
$task = Get-ScheduledTask `
  -TaskName $TaskName `
  -TaskPath $TaskPath `
  -ErrorAction SilentlyContinue
$taskInfo = if ($null -ne $task) {
  Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
} else {
  $null
}
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$autostartProjectRoot = if (
  -not [string]::IsNullOrWhiteSpace([string]$installedHostPath) -and
  (Test-Path -LiteralPath $installedHostPath -PathType Leaf)
) {
  Split-Path -Parent $installedHostPath
} else {
  $runtimeProjectRoot
}
function Invoke-AutostartHelper {
  param(
    [ValidateSet('Get', 'Enable', 'Disable')]
    [string]$Action
  )

  $output = & $windowsPowerShell `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $autostartScript `
    -Action $Action `
    -ProjectRoot $autostartProjectRoot `
    -HostPath $installedHostPath `
    -TaskName $TaskName `
    -TaskPath $TaskPath
  if ([string]::IsNullOrWhiteSpace(($output -join [Environment]::NewLine))) {
    throw "Autostart helper returned no result for '$Action'."
  }
  return $output | ConvertFrom-Json
}

$autostartStatus = Invoke-AutostartHelper -Action Get

$autostartRoundTrip = [ordered]@{
  requested = [bool]$ExerciseAutostart
  success = $true
  initialState = $autostartStatus.state
  toggledState = $null
  restoredState = $autostartStatus.state
  error = $null
}
if ($ExerciseAutostart) {
  $toggleApplied = $false
  $restoreAction = $null
  try {
    if (-not $autostartStatus.configured) {
      throw "Autostart must be configured before the round-trip test. State=$($autostartStatus.state)"
    }
    $toggleAction = if ($autostartStatus.enabled) { 'Disable' } else { 'Enable' }
    $restoreAction = if ($autostartStatus.enabled) { 'Enable' } else { 'Disable' }
    $toggleResult = Invoke-AutostartHelper -Action $toggleAction
    if (-not $toggleResult.success) {
      throw "Autostart toggle failed. $($toggleResult.error)"
    }
    if ([bool]$toggleResult.enabled -eq [bool]$autostartStatus.enabled) {
      throw 'Autostart toggle reported success without changing the enabled state.'
    }
    $toggleApplied = $true
    $autostartRoundTrip.toggledState = $toggleResult.state
  } catch {
    $autostartRoundTrip.success = $false
    $autostartRoundTrip.error = $_.Exception.Message
  } finally {
    if ($toggleApplied) {
      try {
        $restoreResult = Invoke-AutostartHelper -Action $restoreAction
        if (-not $restoreResult.success) {
          throw "Autostart restore failed. $($restoreResult.error)"
        }
        $autostartRoundTrip.restoredState = $restoreResult.state
        if ([bool]$restoreResult.enabled -ne [bool]$autostartStatus.enabled) {
          throw 'Autostart restore completed with the wrong enabled state.'
        }
      } catch {
        $autostartRoundTrip.success = $false
        $restoreError = $_.Exception.Message
        $autostartRoundTrip.error = if (
          [string]::IsNullOrWhiteSpace([string]$autostartRoundTrip.error)
        ) {
          $restoreError
        } else {
          "$($autostartRoundTrip.error) Restore: $restoreError"
        }
      }
    }
  }
}

if (-not ('WorkspaceWidgetWindowLayerProbe' -as [type])) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WorkspaceWidgetWindowLayerProbe
{
    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TOPMOST = 0x00000008L;
    private const uint GW_OWNER = 4;
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr state);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr state);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out RECT bounds);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong32(IntPtr window, int index);

    public static bool IsTopmost(IntPtr window)
    {
        long style = IntPtr.Size == 8
            ? GetWindowLongPtr64(window, GWL_EXSTYLE).ToInt64()
            : GetWindowLong32(window, GWL_EXSTYLE);
        return (style & WS_EX_TOPMOST) == WS_EX_TOPMOST;
    }

    public static IntPtr GetOwner(IntPtr window)
    {
        return GetWindow(window, GW_OWNER);
    }

    public static uint GetProcessId(IntPtr window)
    {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        return processId;
    }

    public static RECT GetBounds(IntPtr window)
    {
        RECT bounds;
        GetWindowRect(window, out bounds);
        return bounds;
    }

    public static IntPtr FindVisibleWindowForProcess(uint targetProcessId)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(
            delegate(IntPtr window, IntPtr state)
            {
                IntPtr owner = GetOwner(window);
                uint ownerProcessId = owner == IntPtr.Zero
                    ? 0
                    : GetProcessId(owner);
                if (
                    GetProcessId(window) == targetProcessId &&
                    IsWindowVisible(window) &&
                    (
                        owner == IntPtr.Zero ||
                        ownerProcessId != targetProcessId
                    )
                )
                {
                    result = window;
                    return false;
                }
                return true;
            },
            IntPtr.Zero);
        return result;
    }
}
'@
}

$nativeProcesses = @(
  Get-CimInstance Win32_Process -Filter "Name='WorkspaceWidget.exe'" -ErrorAction SilentlyContinue
)
$legacyProcesses = @(
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
      $_.CommandLine -match '(?i)-STA\b.*-File\s+(?:"[^"]*\\WorkspaceWidget\.ps1"|[^\s]*\\WorkspaceWidget\.ps1)' -and
      $_.CommandLine -notmatch '\s-Probe(?:\s|$)' -and
      $_.CommandLine -notmatch '\s-CapturePath(?:\s|$)'
    }
)
$processes = @($nativeProcesses) + @($legacyProcesses)
$expectedWidgetProcessId = if ($processes.Count -eq 1) {
  [uint32]$processes[0].ProcessId
} else {
  [uint32]0
}
$widgetWindowHandle = if ($expectedWidgetProcessId -gt 0) {
  [WorkspaceWidgetWindowLayerProbe]::FindVisibleWindowForProcess(
    $expectedWidgetProcessId
  )
} else {
  [IntPtr]::Zero
}
$windowBounds = if ($widgetWindowHandle -ne [IntPtr]::Zero) {
  $nativeBounds = [WorkspaceWidgetWindowLayerProbe]::GetBounds($widgetWindowHandle)
  [pscustomobject]@{
    left = [int]$nativeBounds.Left
    top = [int]$nativeBounds.Top
    right = [int]$nativeBounds.Right
    bottom = [int]$nativeBounds.Bottom
    width = [int]$nativeBounds.Right - [int]$nativeBounds.Left
    height = [int]$nativeBounds.Bottom - [int]$nativeBounds.Top
  }
} else {
  $null
}
$monitorIntersections = @(
  if ($null -ne $windowBounds) {
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
      $visibleWidth = [math]::Max(
        0,
        [math]::Min($windowBounds.right, $screen.WorkingArea.Right) -
          [math]::Max($windowBounds.left, $screen.WorkingArea.Left)
      )
      $visibleHeight = [math]::Max(
        0,
        [math]::Min($windowBounds.bottom, $screen.WorkingArea.Bottom) -
          [math]::Max($windowBounds.top, $screen.WorkingArea.Top)
      )
      [pscustomobject]@{
        deviceName = $screen.DeviceName
        visibleWidth = [int]$visibleWidth
        visibleHeight = [int]$visibleHeight
      }
    }
  }
)
$windowOnVisibleMonitor = @(
  $monitorIntersections |
    Where-Object {
      $_.visibleWidth -ge 48 -and
      $_.visibleHeight -ge 48
    }
).Count -gt 0
$windowLayerProbe = [pscustomobject]@{
  found = $widgetWindowHandle -ne [IntPtr]::Zero
  visible = (
    $widgetWindowHandle -ne [IntPtr]::Zero -and
    [WorkspaceWidgetWindowLayerProbe]::IsWindowVisible($widgetWindowHandle)
  )
  topmost = (
    $widgetWindowHandle -ne [IntPtr]::Zero -and
    [WorkspaceWidgetWindowLayerProbe]::IsTopmost($widgetWindowHandle)
  )
  owner = if ($widgetWindowHandle -ne [IntPtr]::Zero) {
    [WorkspaceWidgetWindowLayerProbe]::GetOwner($widgetWindowHandle).ToInt64()
  } else {
    $null
  }
  processId = if ($widgetWindowHandle -ne [IntPtr]::Zero) {
    [int][WorkspaceWidgetWindowLayerProbe]::GetProcessId($widgetWindowHandle)
  } else {
    $null
  }
  bounds = $windowBounds
  onVisibleMonitor = $windowOnVisibleMonitor
  monitorIntersections = $monitorIntersections
}

$shell = $null
$shortcut = $null
$shortcutSnapshot = $null
try {
  $shell = New-Object -ComObject WScript.Shell
  if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcutSnapshot = [pscustomobject]@{
      targetPath = [string]$shortcut.TargetPath
      arguments = [string]$shortcut.Arguments
      workingDirectory = [string]$shortcut.WorkingDirectory
      iconLocation = [string]$shortcut.IconLocation
      windowStyle = [int]$shortcut.WindowStyle
    }
  }
} finally {
  if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
  }
  if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
  }
}

$geometryMonitorIntersections = @(
  foreach ($area in @($geometryProbe.workingAreas)) {
    $visibleWidth = [math]::Max(
      0.0,
      [math]::Min(
        [double]$geometryProbe.geometry.left + [double]$geometryProbe.geometry.width,
        [double]$area.right
      ) - [math]::Max(
        [double]$geometryProbe.geometry.left,
        [double]$area.left
      )
    )
    $visibleHeight = [math]::Max(
      0.0,
      [math]::Min(
        [double]$geometryProbe.geometry.top + [double]$geometryProbe.geometry.height,
        [double]$area.bottom
      ) - [math]::Max(
        [double]$geometryProbe.geometry.top,
        [double]$area.top
      )
    )
    [pscustomobject]@{
      deviceName = [string]$area.deviceName
      visibleWidth = $visibleWidth
      visibleHeight = $visibleHeight
    }
  }
)
$geometryOnVisibleMonitor = @(
  $geometryMonitorIntersections |
    Where-Object {
      $_.visibleWidth -ge 48 -and
      $_.visibleHeight -ge 48
    }
).Count -gt 0

$healthTargets = @(
  $runtimeState.items |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.health) } |
    ForEach-Object { [string]$_.health }
)
$healthChecks = foreach ($url in $healthTargets) {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
    [pscustomobject]@{
      url = $url
      online = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
      statusCode = [int]$response.StatusCode
    }
  } catch {
    [pscustomobject]@{
      url = $url
      online = $false
      statusCode = $null
      error = $_.Exception.Message
    }
  }
}

$rainmeterConfig = if (Test-Path -LiteralPath $rainmeterIni -PathType Leaf) {
  Get-Content -LiteralPath $rainmeterIni -Raw
} else {
  ''
}

$iconBytes = [System.IO.File]::ReadAllBytes($shortcutIcon)
$iconFrameCount = [BitConverter]::ToUInt16($iconBytes, 4)
$iconFrames = for ($index = 0; $index -lt $iconFrameCount; $index++) {
  $offset = 6 + ($index * 16)
  [pscustomobject]@{
    width = if ($iconBytes[$offset] -eq 0) { 256 } else { [int]$iconBytes[$offset] }
    height = if ($iconBytes[$offset + 1] -eq 0) { 256 } else { [int]$iconBytes[$offset + 1] }
    bits = [BitConverter]::ToUInt16($iconBytes, $offset + 6)
  }
}
$legacyMatch = [regex]::Match(
  $rainmeterConfig,
  '(?ms)^\[WorkspaceServiceLauncher\]\r?\n(?<body>.*?)(?=^\[|\z)'
)
$legacyBody = if ($legacyMatch.Success) {
  $legacyMatch.Groups['body'].Value
} else {
  ''
}

$checks = [ordered]@{
  requiredFiles = @($files | Where-Object { -not $_.exists }).Count -eq 0
  defaultStateValid = [int]$defaultState.schemaVersion -eq 4 -and
    $defaultState.PSObject.Properties.Name -contains 'items'
  runtimeStateValid = [int]$runtimeState.schemaVersion -eq 4 -and
    $runtimeState.PSObject.Properties.Name -contains 'items'
  featureProbe = $probe.success -and
    $probe.supports.dragWindow -and
    $probe.supports.resizeWindow -and
    $probe.supports.dragDropFiles -and
    $probe.supports.dragDropUrls -and
    $probe.supports.smoothWheel -and
    $probe.supports.addEditHideSort -and
    $probe.supports.urlPortSubtitle -and
    $probe.supports.healthEndpoint -and
    $probe.supports.bundledNodeStartup -and
    $probe.supports.offlineServerRecovery -and
    $probe.supports.statePersistence -and
    $probe.supports.trayLifecycle -and
    $probe.supports.minUiMode -and
    $probe.supports.autostartSetting -and
    $probe.supports.startupReadiness -and
    $probe.supports.lnkTargetResolution -and
    $probe.supports.visibleWorkAreaRecovery -and
    $probe.supports.mediaCustomization -and
    $probe.supports.semanticIcons -and
    $probe.supports.customThemes -and
    $probe.supports.youtubeHoverPreview
  semanticIconLibrary = $semanticIconProbe.success -and
    [double]$semanticIconProbe.score -ge 99.0 -and
    [int]$semanticIconProbe.iconCount -eq 8 -and
    @($semanticIconProbe.blockingFailures).Count -eq 0
  lnkTargetResolution = $shortcutProbe.success -and
    $shortcutProbe.kind -eq 'lnk' -and
    $shortcutProbe.shortcutResolved -and
    [string]::Equals(
      [string]$shortcutProbe.sourceShortcut,
      $shortcutFixture,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    [System.IO.Path]::GetExtension([string]$shortcutProbe.target) -ine '.lnk' -and
    [string]::Equals(
      [string]$shortcutProbe.target,
      (Join-Path $env:WINDIR 'System32\notepad.exe'),
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    (Test-Path -LiteralPath ([string]$shortcutProbe.target) -PathType Leaf) -and
    -not [string]::IsNullOrWhiteSpace([string]$shortcutProbe.launchArguments) -and
    (Test-Path -LiteralPath ([string]$shortcutProbe.workingDirectory) -PathType Container) -and
    [string]$shortcutProbe.iconLocation -match '(?i)notepad\.exe,0$' -and
    [int]$shortcutProbe.launchWindowStyle -eq 3 -and
    $appContent -match 'function Resolve-ShortcutRegistration' -and
    $appContent -match 'Resolve-ShortcutRegistration -Path \(\[string\]\$originalTarget\)' -and
    $appContent -match 'Resolve-ShortcutRegistration -Path \$targetInput' -and
    $appContent -match '\$existingArguments' -and
    $appContent -match '\$existingWorkingDirectory' -and
    $appContent -match 'Get-NormalizedWorkingDirectory' -and
    $appContent -match 'launchArguments = \$launchArguments' -and
    $appContent -match '\$launch\.ArgumentList = \[string\]\$Item\.launchArguments' -and
    $appContent -match '\$launch\.WorkingDirectory = \$launchWorkingDirectory' -and
    $appContent -match '\$launchWorkingDirectory = \$env:USERPROFILE' -and
    $appContent -match 'GetIconResource' -and
    $appContent -match 'ExtractIconEx' -and
    @(
      $runtimeState.items |
        Where-Object {
          $_.PSObject.Properties.Name -notcontains 'launchArguments' -or
          $_.PSObject.Properties.Name -notcontains 'workingDirectory' -or
          $_.PSObject.Properties.Name -notcontains 'sourceShortcut'
        }
    ).Count -eq 0
  windowVisibilityRecovery = $windowLayerProbe.found -and
    $windowLayerProbe.visible -and
    $windowLayerProbe.onVisibleMonitor -and
    $geometryProbe.success -and
    $geometryProbe.geometry.adjusted -and
    [double]$geometryProbe.configuredWidth -eq 430 -and
    [double]$geometryProbe.actualWidth -eq 96 -and
    [double]$geometryProbe.effectiveWidth -eq 430 -and
    [double]$geometryProbe.geometry.width -eq 430 -and
    $geometryOnVisibleMonitor -and
    $appContent -match 'function Resolve-VisibleWindowGeometry' -and
    $appContent -match 'Get-EffectiveWindowDimension' -and
    $appContent -match 'function Ensure-WindowVisible' -and
    $appContent -match '\$geometry = Resolve-VisibleWindowGeometry' -and
    $appContent -match "Ensure-WindowVisible -Reason 'source initialized'" -and
    $appContent -match 'Ensure-WindowVisible -Reason \$Reason -Persist' -and
    $appContent -match '\$visibilityReason = if \(\$Initial\).*''ui mode change'''
  urlPortSubtitle = @($runtimeState.items | Where-Object {
      $_.target -match '^https?://[^/]+:\d+' -and $_.subtitle -notmatch '^Port \d+$'
    }).Count -eq 0
  healthAndNodeStartup = $startupProbe.success -and
    $startupProbe.statusCode -eq 200 -and
    [bool]$startupProbe.expectedTokenMatched -and
    [string]$startupProbe.health -eq "http://127.0.0.1:$startupProbePort/health" -and
    $startupProbe.bundledNodeVersion -match '^v\d+\.' -and
    $appContent -match 'Queue-NodeStartAndOpen' -and
    $appContent -match 'Get-NodePackageScript'
  offlineServerRecovery = $appContent -match 'function Queue-NodeServerRecovery' -and
    $appContent -match 'function Update-ServerRecoveryMenuItem' -and
    $appContent -match "Header 'Check and restart server'" -and
    $appContent -match "Header 'Configure server restart\.\.\.'" -and
    $appContent -match '\$MenuItem\.Header = if \(\$healthKnown\) \{ ''Restart server'' \}' -and
    $appContent -match '\$MenuItem\.IsEnabled = \$false' -and
    $appContent -match 'openWhenHealthy = \$OpenWhenHealthy' -and
    $appContent -match 'Stop-TrackedLocalServer -Item \$pendingOpen\.item -ConfirmForce' -and
    $appContent -match 'function Stop-ProcessTree' -and
    $appContent -match 'Unsaved server work may be lost'
  packagedRuntimeIsolation = $appContent -match '\$packageRuntimeEnforced' -and
    $appContent -match "'PackageLocal'" -and
    $appContent -match "'PackageLocalMissing'" -and
    $appContent -match '\$nodeCandidates = @\(\$packageNodePath\)' -and
    [bool]$packageIsolationProbe.packageRuntimeEnforced -and
    -not [bool]$packageIsolationProbe.bundledNodeAvailable -and
    [string]$packageIsolationProbe.nodeRuntimeSource -eq 'PackageLocalMissing' -and
    [string]::IsNullOrWhiteSpace([string]$packageIsolationProbe.bundledNodePath)
  boundedStateAndMedia = $appContent -match '\$script:maximumStateBytes = 4MB' -and
    $appContent -match '\$script:maximumShortcutCount = 250' -and
    $appContent -match '\$script:maximumManagedCacheBytes = 128MB' -and
    $appContent -match 'function Get-ValidatedLocalMediaInfo'
  strictUrlAndStartupBoundary = $appContent -match 'function Get-ValidatedWebUri' -and
    $appContent -match 'function Resolve-NodeStartupConfiguration' -and
    $appContent -match 'Automatic Node startup requires a loopback health URL'
  wpfRuntime = $appContent -match 'PresentationFramework' -and
    $appContent -match 'AllowDrop="True"' -and
    $appContent -match 'ResizeMode="CanResize"' -and
    $appContent -match 'Background="Transparent"\s+BorderThickness="0"\s+Padding="0"\s+ShowInTaskbar="False"' -and
    $appContent -match '\$script:window\.Background = \[System\.Windows\.Media\.Brushes\]::Transparent' -and
    $appContent -match '\$script:panelBorder\.Background = Convert-ToBrush \(' -and
    $appContent -match 'Set-ColorAlpha -Color \$script:themePalette\.panel -Alpha 255' -and
    $appContent -match 'DragMove\(\)'
  opacityAndHover = $appContent -match 'OpacitySlider' -and
    $appContent -match 'hoverBrightness' -and
    $appContent -match 'function Update-WidgetOpacity' -and
    $appContent -match 'FillBehavior.*Stop' -and
    $appContent -match 'BeginAnimation\(\s*\[System\.Windows\.Window\]::OpacityProperty,\s*\$null' -and
    [double]$runtimeState.window.opacity -ge 0.35 -and
    [double]$runtimeState.window.opacity -le 1.0
  alwaysOnTopSetting = $appContent -match 'AlwaysOnTopCheck' -and
    $appContent -match '\$script:window\.Topmost = \$script:alwaysOnTop' -and
    $appContent -match 'function Set-WindowLayerMode' -and
    $appContent -match 'HWND_TOPMOST' -and
    $appContent -match 'SetWindowPos' -and
    $appContent -match 'GetWindowOwner' -and
    $appContent -match "reason='source initialized'|Reason 'source initialized'" -and
    $appContent -match 'topmostReassertTimer' -and
    $appContent -match "Always on top changed\. enabled=True" -and
    $runtimeState.window.PSObject.Properties.Name -contains 'alwaysOnTop' -and
    $defaultState.window.PSObject.Properties.Name -contains 'alwaysOnTop'
  alwaysOnTopRuntime = if ([bool]$runtimeState.window.alwaysOnTop) {
    $windowLayerProbe.found -and
    $windowLayerProbe.visible -and
    $windowLayerProbe.topmost -and
    [int64]$windowLayerProbe.owner -eq 0 -and
    $processes.Count -eq 1 -and
    [int]$windowLayerProbe.processId -eq [int]$processes[0].ProcessId
  } else {
    $windowLayerProbe.found -and -not $windowLayerProbe.topmost
  }
  minUiMode = $appContent -match 'MinUiModeCheck' -and
    $appContent -match 'function Set-MinUiMode' -and
    $appContent -match 'function Snap-MinUiToNearestEdge' -and
    $appContent -match 'minUiSnapTimer' -and
    $appContent -match '\$script:minUiWidth = 96\.0' -and
    $appContent -match 'Set-ToolbarCompactMode -Compact \$true' -and
    $appContent -match '\$card\.Width = if \(\$isMinUi\) \{ 62 \}' -and
    $runtimeState.window.PSObject.Properties.Name -contains 'minUiMode' -and
    $defaultState.window.PSObject.Properties.Name -contains 'minUiMode' -and
    [double]$defaultState.window.minUiOpacity -eq 0.35
  responsiveHeader = $appContent -match 'x:Name="HeaderLogo"' -and
    $appContent -match 'x:Name="HeaderTitleText"' -and
    $appContent -match 'x:Name="HeaderHealthStatus"' -and
    $appContent -match 'function Update-ResponsiveHeader' -and
    $appContent -match 'ActualWidth -lt 500' -and
    $appContent -match 'Set-ToolbarCompactMode -Compact \$compactTitle' -and
    $appContent -match 'Update-ResponsiveHeader'
  autostartSetting = $appContent -match 'StartWithWindowsCheck' -and
    $appContent -match 'AutostartStatusText' -and
    $appContent -match 'function Start-AutostartOperation' -and
    $appContent -match '\$nativeHostPath' -and
    $appContent -match "'--autostart'" -and
    $appContent -match "'DisabledByUser'" -and
    $appContent -match "'DisabledByPolicy'" -and
    $appContent -match "Start-AutostartOperation -Action Enable" -and
    $appContent -match "Start-AutostartOperation -Action Disable" -and
    $hostContent -match 'HasPackageIdentity' -and
    $hostContent -match 'RunPackagedAutostartAction' -and
    $hostContent -match 'PackagedStartupTaskId = "WorkspaceWidgetStartup"' -and
    $hostContent -match 'RequestEnableAsync' -and
    $hostContent -match 'Directory\.CreateDirectory\(processWorkingDirectory\)' -and
    $appContent -match '\$processInfo\.WorkingDirectory = \$runtimeRoot' -and
    $autostartContent -match "ValidateSet\('Get', 'Enable', 'Disable', 'Ensure', 'Repair', 'Unregister'\)" -and
    $autostartContent -match 'Disable-ScheduledTask' -and
    $autostartContent -match 'productMarker' -and
    $autostartContent -match 'Get-CurrentUserTaskControl' -and
    $autostartContent -match 'multipleInstances' -and
    $autostartStatus.userCanControl -and
    $autostartRoundTrip.success
  storeMsixSourceContract = $msixManifestContent -match 'RuntimeBehavior="win32App"' -and
    $msixManifestContent -match 'Category="windows\.startupTask"' -and
    $msixManifestContent -match 'TaskId="WorkspaceWidgetStartup"' -and
    $msixManifestContent -match 'rescap:Capability Name="runFullTrust"' -and
    $msixBuilderContent -match '\[switch\]\$StoreSubmission' -and
    $msixBuilderContent -match '\[string\]\$PackageVersion' -and
    $msixBuilderContent -match 'nonzero first segment' -and
    $msixBuilderContent -match 'Partner Center Product identity' -and
    $msixBuilderContent -match 'store-package-receipt\.json' -and
    $msixBuilderContent -match 'scripts\\Set-WorkspaceWidgetAutostart\.ps1' -and
    $msixBuilderContent -match 'packageSigned = \$false' -and
    $msixBuilderContent -match 'clean-git-rebuild' -and
    $msixBuilderContent -match '\$sourceBuildParameters' -and
    $msixBuilderContent -match 'candidateVerified' -and
    $baseBuilderContent -match '\[string\]\$CompilerPath' -and
    $baseBuilderContent -match '\(\?:/\|-\)deterministic' -and
    $msixVerifierContent -match '\[switch\]\$StoreCandidate' -and
    $msixVerifierContent -match 'receiptFilesMatchPackage' -and
    $msixVerifierContent -match 'producerPackageUnsigned' -and
    $msixVerifierContent -match 'storeVersionPolicy' -and
    $msixVerifierContent -match 'startupTaskContract' -and
    $msixVerifierContent -match 'capabilityAllowlist' -and
    $msixVerifierContent -match 'committedBuildInputs'
  releaseIntegrityBeforeExecution = $nodeRestoreContent -match '\$runtimeIsReusable = \$false' -and
    $nodeRestoreContent -match '\$runtimeCacheManifestPath' -and
    $nodeRestoreContent -match 'function Get-ArchiveRuntimeInventory' -and
    $nodeRestoreContent -match 'function Test-RuntimeMatchesArchive' -and
    $nodeRestoreContent -match 'Get-FileHash -LiteralPath \$cachedPath' -and
    $nodeRestoreContent -notmatch '\$cachedVersion = \(&' -and
    $releaseVerifierContent -match '\$preExecutionIntegrityFailures' -and
    $releaseVerifierContent -match 'Release candidate execution was refused' -and
    $releaseVerifierContent -match '\$mediaProbe = & powershell\.exe'
  contentAddressedLocalInstall = $installContent -match 'Test-InstalledReleaseIntegrity' -and
    $installContent -match 'releases\\\$releaseId' -and
    $installContent -match 'will not force-stop it' -and
    $installContent -match '\.partial-\$PID' -and
    $installContent -match 'installer move-boundary check' -and
    $installContent -match 'Move-Item -LiteralPath \$stageRoot -Destination \$partialReleaseRoot' -and
    $installContent -notmatch 'Stop-Process'
  startupReadiness = $startContent -match 'Get-WorkspaceWidgetInstanceNames' -and
    $startContent -match '\$instanceNames\.ready' -and
    $startContent -match '\$readyEvent\.Reset\(\) \| Out-Null' -and
    $startContent -match '\$readyEvent\.WaitOne\(350\)' -and
    $startContent -match '\$appFilePattern' -and
    $startContent -match 'existingReadyEvent\.WaitOne' -and
    $startContent -match 'WorkspaceWidget\.exe' -and
    $appContent -match 'Get-WorkspaceWidgetInstanceNames' -and
    $appContent -match '\$instanceNames\.ready' -and
    $appContent -match 'Add_ContentRendered' -and
    $appContent -match '\$readyEvent\.Set\(\)'
  youtubeIdentifiedWebViewRequest = $appContent -match 'function Get-YouTubeEmbedUri' -and
    $appContent -match 'function Start-YouTubeHoverNavigation' -and
    $appContent -match 'CreateWebResourceRequest' -and
    $appContent -match 'NavigateWithWebResourceRequest' -and
    $appContent -match 'AddWebResourceRequestedFilter' -and
    $appContent -match 'add_WebResourceRequested' -and
    $appContent -match "SetHeader\(\s*'Referer'" -and
    $appContent -match 'Referer: \$\(\$script:youtubeEmbedReferrer\)' -and
    $appContent -match 'widget_referrer=' -and
    $appContent -match 'hoverPendingYouTubeVideoId' -and
    $appContent -match 'EnsureCoreWebView2Async'
  remoteCustomIconPreview = $appContent -match 'function Get-RemoteCustomIconAsset' -and
    $appContent -match 'function Save-NormalizedCustomIconBitmap' -and
    $appContent -match 'function Test-PublicRemoteIconUri' -and
    $appContent -match 'IsIPv4MappedToIPv6' -and
    $appContent -match '\$bytes\[0\] -eq 100' -and
    $appContent -match 'function Test-SafeSvgIcon' -and
    $appContent -match '\[long\]\$MaximumBytes = 2097152' -and
    $appContent -match 'larger than the \$maximumSizeLabel limit' -and
    $appContent -match 'CapturePreviewAsync' -and
    $appContent -match 'I confirm this preview is the icon I want' -and
    $appContent -match 'customIconCache = \$customIconCache' -and
    $appContent -match '\$cacheKey \+ ''-card\.png''' -and
    $appContent -match 'PixelWidth -gt 8192' -and
    $appContent -match '\$pixelCount -gt 32000000' -and
    $appContent -match 'HTTPS icon preview' -and
    $appContent -match 'Local card copy in use' -and
    $appContent -match 'existing local card copy remains active' -and
    $appContent -match '\$refreshCustomIconPreview \$true'
  hostProjectRootConfinement = $hostContent -match 'executable-owned application root' -and
    $hostContent -match 'StringComparison\.OrdinalIgnoreCase' -and
    $startContent -notmatch "'--project-root'" -and
    $installContent -notmatch '--project-root' -and
    $appContent -notmatch "'--project-root'"
  remoteNetworkBoundary = $appContent -match 'function Get-RemoteRasterMediaSource' -and
    $appContent -match "-MaximumBytes 10485760" -and
    $appContent -match "-CacheDirectoryName 'MediaCache'" -and
    $appContent -match 'if \(\$kind -eq ''video''\) \{\s*return \$false' -and
    $appContent -match 'public static class WorkspaceWidgetPinnedHttpsClient' -and
    $appContent -match 'new TcpClient\(address\.AddressFamily\)' -and
    $appContent -match 'new SslStream\(' -and
    $appContent -match 'ValidateRemoteCertificate\(' -and
    $appContent -match 'tls\.BeginAuthenticateAsClient\(' -and
    $appContent -match 'tls\.EndAuthenticateAsClient\(' -and
    $appContent -match 'TlsHandshakeTimesOutForProbe' -and
    $appContent -match 'SslProtocols\.None' -and
    $appContent -match 'MaximumChunkMetadataBytes = 65536' -and
    $appContent -match 'function Resolve-PublicRemoteIconAddresses' -and
    $appContent -match 'function Select-PublicRemoteIconAddresses' -and
    $appContent -match 'function Invoke-PinnedRemoteAssetRequest' -and
    $appContent -match 'Resolve-PublicRemoteIconAddresses -Uri \$Uri' -and
    $appContent -match 'MaximumCount 4' -and
    $appContent -match 'AddSeconds\(10\)' -and
    $appContent -match 'The remote asset request timed out' -and
    $appContent -match '\[switch\]\$NetworkBoundaryProbe'
  webViewIsolation = $appContent -match 'IsWebMessageEnabled = \$false' -and
    $appContent -match 'AreHostObjectsAllowed = \$false' -and
    $appContent -match 'add_NewWindowRequested' -and
    $appContent -match 'add_PermissionRequested' -and
    $appContent -match 'CoreWebView2PermissionState\]::Deny' -and
    $appContent -match 'add_DownloadStarting' -and
    $appContent -match '\$downloadArgs\.Cancel = \$true' -and
    $appContent -match '\$uri\.DnsSafeHost -eq ''www\.youtube-nocookie\.com'''
  publicSourceHygiene = $gitIgnoreContent -match $privateEvidenceIgnorePattern -and
    $gitIgnoreContent -match '(?m)^design/\r?$' -and
    $gitIgnoreContent -match '(?m)^\.env\r?$' -and
    $gitIgnoreContent -match '(?m)^\*\.pfx\r?$' -and
    $gitIgnoreContent -match '(?m)^packaging/msix/store-identity\.json\r?$' -and
    @($defaultState.items).Count -eq 0 -and
    @($publicDefaultState.items).Count -eq 0 -and
    (
      Get-FileHash -LiteralPath $defaultStatePath -Algorithm SHA256
    ).Hash -eq (
      Get-FileHash -LiteralPath $publicDefaultStatePath -Algorithm SHA256
    ).Hash
  clipboardCustomIconPreview = $appContent -match 'function Save-ClipboardCustomIconAsset' -and
    $appContent -match '\[System\.Windows\.Clipboard\]::ContainsImage\(\)' -and
    $appContent -match 'Paste clipboard image' -and
    $appContent -match 'clipboard-\[0-9a-f\]\{64\}-card\\\.png' -and
    $appContent -match 'Clipboard image loaded' -and
    $appContent -match 'Get-SignedRemoteIconExpiry'
  keyboardAndDialogAccessibility = $appContent -match '\$button\.Focusable = \$true' -and
    $appContent -match 'Add_GotKeyboardFocus' -and
    $appContent -match 'AutomationProperties\]::SetLabeledBy' -and
    $appContent -match 'AutomationProperties\]::SetLiveSetting' -and
    $appContent -match '\$dialogScroll = \[System\.Windows\.Controls\.ScrollViewer\]::new\(\)'
  buttonHoverContrast = $appContent -match 'function New-ButtonTemplate' -and
    $appContent -match 'Property="IsMouseOver"' -and
    $appContent -match 'TargetName="ContentHost" Property="TextElement\.Foreground" Value="#FFFFFFFF"' -and
    $appContent -match 'Setter Property="Foreground" Value="#FFFFFFFF"'
  removeShortcut = $appContent -match 'function Remove-ItemRegistration' -and
    $appContent -match "Header 'Remove shortcut\.\.\.'" -and
    $appContent -match 'The original file, application, folder, or URL will not be deleted'
  trayLifecycle = $appContent -match 'System\.Windows\.Forms\.NotifyIcon' -and
    $appContent -match "ToolStripMenuItem\]::new\('Open Workspace'\)" -and
    $appContent -match "ToolStripMenuItem\]::new\('Exit'\)" -and
    $appContent -match 'function Hide-WorkspaceToTray' -and
    $appContent -match 'function Show-WorkspaceFromTray' -and
    $appContent -match 'function Exit-WorkspaceWidget' -and
    $appContent -match 'AutomationName ''Hide to tray''' -and
    $appContent -match 'Add_Closing' -and
    $startContent -match 'Get-WorkspaceWidgetInstanceNames' -and
    $startContent -match '\$instanceNames\.show' -and
    $startContent -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
  persistence = $appContent -match 'Save-State' -and
    $appContent -match '\[System\.IO\.File\]::Replace' -and
    $appContent -match '\$StatePath\.previous' -and
    $appContent -match '\[int\]\$candidateState\.schemaVersion -gt 4' -and
    $appContent -match 'LocationChanged' -and
    $appContent -match 'SizeChanged'
  stateRecoveryFallback = [bool]$stateRecoveryProbe.success -and
    [int]$stateRecoveryProbe.schemaVersion -eq 4 -and
    [int]$stateRecoveryProbe.itemCount -eq 0 -and
    [string]$stateRecoveryProbe.stateSourcePath -eq "$malformedStatePath.previous"
  futureStateFailClosed = $futureStateProbeExit -ne 0 -and
    $futureStateProbeExit -eq 3 -and
    -not [bool]$futureStateProbe.success -and
    [int]$futureStateProbe.exitCode -eq 3 -and
    [string]$futureStateProbe.error -match 'newer than the supported schema 4' -and
    $futureStateHashBefore -eq $futureStateHashAfter -and
    $futurePreviousHashBefore -eq $futurePreviousHashAfter -and
    $appContent -match 'catch \[System\.NotSupportedException\]'
  smoothWheelAndPaging = $appContent -match 'PreviewMouseWheel' -and
    $appContent -match 'scrollTarget' -and
    $appContent -match 'CompositionTarget.*add_Rendering' -and
    $appContent -match 'scrollAnimationDurationMs' -and
    $appContent -match 'Update-PageDots'
  shellIcons = $appContent -match 'SHGetFileInfo' -and
    $appContent -match 'GetShellIcon'
  multiResolutionIcon = $iconFrameCount -ge 7 -and
    @($iconFrames | Where-Object { $_.bits -ne 32 }).Count -eq 0 -and
    @($iconFrames | Where-Object { $_.width -eq 16 }).Count -eq 1 -and
    @($iconFrames | Where-Object { $_.width -eq 256 }).Count -eq 1
  cleanContextMenuTemplate = $appContent -match 'TargetType="\{x:Type MenuItem\}"' -and
    $appContent -match 'FocusVisualStyle = \$null'
  widgetRunning = $processes.Count -eq 1
  taskExists = $null -ne $task -and $autostartStatus.exists
  taskConfigured = $autostartStatus.configured -and
    $autostartStatus.state -in @('Enabled', 'Disabled')
  taskUserControllable = [bool]$autostartStatus.userCanControl
  taskInteractive = $null -ne $task -and $task.Principal.LogonType.ToString() -eq 'Interactive'
  taskLimited = $null -ne $task -and $task.Principal.RunLevel.ToString() -eq 'Limited'
  taskDetachedLauncher = $null -ne $task -and
    -not [string]::IsNullOrWhiteSpace([string]$installedHostPath) -and
    $task.Actions[0].Execute -match '(?i)WorkspaceWidget\.exe$' -and
    [string]::Equals(
      [System.IO.Path]::GetFullPath([string]$task.Actions[0].Execute),
      [System.IO.Path]::GetFullPath([string]$installedHostPath),
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    [string]::Equals(
      [System.IO.Path]::GetFullPath([string]$task.Actions[0].WorkingDirectory).TrimEnd('\'),
      [System.IO.Path]::GetFullPath((Split-Path -Parent $installedHostPath)).TrimEnd('\'),
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    [string]::IsNullOrWhiteSpace([string]$task.Actions[0].Arguments) -and
    [string]$task.Settings.ExecutionTimeLimit -eq 'PT0S'
  taskStatusRecorded = $null -ne $taskInfo
  shortcutExists = $null -ne $shortcutSnapshot
  shortcutLaunchesWrapper = $null -ne $shortcutSnapshot -and
    $shortcutSnapshot.targetPath -match '(?i)WorkspaceWidget\.exe$' -and
    $shortcutSnapshot.iconLocation -match 'workspace-widget\.ico'
  allServicesOnline = @($healthChecks | Where-Object { -not $_.online }).Count -eq 0
  healthTargetsFromState = @($healthChecks).Count -eq @($healthTargets).Count
  legacyRainmeterDeactivated = -not $legacyMatch.Success -or $legacyBody -match '(?m)^Active=0\r?$'
  noLegacyLauncherDependency = $startContent -notmatch 'Rainmeter'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })

[pscustomobject]@{
  success = $failed.Count -eq 0
  failedChecks = @($failed | ForEach-Object { $_.Key })
  checks = $checks
  probe = $probe
  semanticIconProbe = $semanticIconProbe
  startupProbe = $startupProbe
  shortcutProbe = $shortcutProbe
  geometryProbe = $geometryProbe
  stateRecoveryProbe = $stateRecoveryProbe
  autostart = $autostartStatus
  autostartRoundTrip = $autostartRoundTrip
  iconFrames = $iconFrames
  health = $healthChecks
  process = if ($processes.Count -gt 0) {
    [pscustomobject]@{
      processId = [int]$processes[0].ProcessId
      commandLine = [string]$processes[0].CommandLine
    }
  } else {
    $null
  }
  windowLayer = $windowLayerProbe
  shortcut = if ($null -ne $shortcutSnapshot) {
    [pscustomobject]@{
      path = $ShortcutPath
      target = $shortcutSnapshot.targetPath
      arguments = $shortcutSnapshot.arguments
      workingDirectory = $shortcutSnapshot.workingDirectory
      iconLocation = $shortcutSnapshot.iconLocation
      windowStyle = $shortcutSnapshot.windowStyle
    }
  } else {
    $null
  }
  task = if ($null -ne $task) {
    [pscustomobject]@{
      taskPath = $TaskPath
      state = $task.State.ToString()
      enabled = $task.Settings.Enabled
      configured = $autostartStatus.configured
      userId = $task.Principal.UserId
      logonType = $task.Principal.LogonType.ToString()
      execute = $task.Actions[0].Execute
      arguments = $task.Actions[0].Arguments
      delay = $task.Triggers[0].Delay
      lastTaskResult = $taskInfo.LastTaskResult
    }
  } else {
    $null
  }
} | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
  exit 1
}
