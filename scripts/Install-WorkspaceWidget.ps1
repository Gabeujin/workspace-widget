[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '0.1.4',
  [string]$TaskName = 'Workspace Service Widget',
  [string]$TaskPath = '\',
  [string]$SessionId = 'manual',
  [string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$appScript = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$defaultState = Join-Path $ProjectRoot 'app\default-state.json'
$launcherScript = Join-Path $ProjectRoot 'scripts\Start-WorkspaceWidget.ps1'
$autostartScript = Join-Path $ProjectRoot 'scripts\Set-WorkspaceWidgetAutostart.ps1'
$buildScript = Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidget.ps1'
$shortcutIcon = Join-Path $ProjectRoot 'assets\workspace-widget.ico'
$statePath = Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'
$stateRoot = Split-Path -Parent $statePath
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Workspace Widget.lnk'
$startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
$startMenuShortcutPath = Join-Path $startMenuPrograms 'Workspace Widget.lnk'
$rainmeterPath = 'C:\Program Files\Rainmeter\Rainmeter.exe'
$rainmeterSettings = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'

foreach ($required in @(
    $appScript,
    $defaultState,
    $launcherScript,
    $autostartScript,
    $buildScript,
    $shortcutIcon
  )) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required widget file not found at '$required'."
  }
}

$preflightWidgetProcesses = @(
  Get-CimInstance Win32_Process `
    -Filter "Name='WorkspaceWidget.exe'" `
    -ErrorAction SilentlyContinue
)
if ($preflightWidgetProcesses.Count -gt 0) {
  throw (
    'Exit the currently running Workspace Widget from its tray menu, then ' +
    'rerun the installer. Preflight stopped before a build or release copy was created. ' +
    'PIDs: ' +
    (@($preflightWidgetProcesses | ForEach-Object { [string]$_.ProcessId }) -join ', ')
  )
}

$installBuildRoot = Join-Path `
  $env:LOCALAPPDATA `
  ('WorkspaceWidget\InstallBuilds\' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + "-$PID")
$buildResult = & $buildScript `
  -ProjectRoot $ProjectRoot `
  -Version $Version `
  -OutputRoot $installBuildRoot `
  -SkipInstaller |
  ConvertFrom-Json
if (
  -not $buildResult.success -or
  [string]::IsNullOrWhiteSpace([string]$buildResult.stageRoot) -or
  [string]::IsNullOrWhiteSpace([string]$buildResult.manifest)
) {
  throw 'WorkspaceWidget.exe build did not report a complete release stage.'
}

$stageRoot = [System.IO.Path]::GetFullPath([string]$buildResult.stageRoot).TrimEnd('\')
$stageManifestPath = [System.IO.Path]::GetFullPath([string]$buildResult.manifest)
$stageManifest = Get-Content -LiteralPath $stageManifestPath -Raw | ConvertFrom-Json
$fingerprintLines = @(
  $stageManifest.files |
    Sort-Object path |
    ForEach-Object { '{0}|{1}|{2}' -f $_.path, $_.size, $_.sha256 }
)
$fingerprintHasher = [System.Security.Cryptography.SHA256]::Create()
try {
  $releaseFingerprint = [BitConverter]::ToString(
    $fingerprintHasher.ComputeHash(
      [Text.Encoding]::UTF8.GetBytes(($fingerprintLines -join "`n"))
    )
  ).Replace('-', '')
} finally {
  $fingerprintHasher.Dispose()
}
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\WorkspaceWidget'
$releaseId = "$Version-$($releaseFingerprint.Substring(0, 16).ToLowerInvariant())"
$releaseRoot = Join-Path $installRoot "releases\$releaseId"

function Test-InstalledReleaseIntegrity {
  param([Parameter(Mandatory = $true)][string]$Root)

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $false
  }
  $expectedPaths = @($stageManifest.files | ForEach-Object { [string]$_.path } | Sort-Object)
  $actualPaths = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File |
      ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') } |
      Sort-Object
  )
  if ([string]::Join('|', $expectedPaths) -cne [string]::Join('|', $actualPaths)) {
    return $false
  }
  foreach ($entry in @($stageManifest.files)) {
    $candidate = Join-Path $Root ([string]$entry.path)
    $item = Get-Item -LiteralPath $candidate
    if (
      [int64]$item.Length -ne [int64]$entry.size -or
      -not [string]::Equals(
        (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash,
        [string]$entry.sha256,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      return $false
    }
  }
  return $true
}

$stageRelocatedToRelease = $false
if (Test-Path -LiteralPath $releaseRoot) {
  if (-not (Test-InstalledReleaseIntegrity -Root $releaseRoot)) {
    throw "The content-addressed release is present but failed integrity validation: $releaseRoot"
  }
} else {
  $partialReleaseRoot = "$releaseRoot.partial-$PID"
  if (Test-Path -LiteralPath $partialReleaseRoot) {
    throw "A previous incomplete release requires manual review: $partialReleaseRoot"
  }
  $installBuildPrefix = [System.IO.Path]::GetFullPath($installBuildRoot).TrimEnd('\') + '\'
  $releaseParent = Split-Path -Parent $releaseRoot
  $releasePrefix = [System.IO.Path]::GetFullPath($releaseParent).TrimEnd('\') + '\'
  if (
    -not $stageRoot.StartsWith(
      $installBuildPrefix,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    -not ([System.IO.Path]::GetFullPath($partialReleaseRoot)).StartsWith(
      $releasePrefix,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw 'The staged and release paths failed the installer move-boundary check.'
  }
  New-Item -ItemType Directory -Path $releaseParent -Force | Out-Null
  Move-Item -LiteralPath $stageRoot -Destination $partialReleaseRoot
  if (-not (Test-InstalledReleaseIntegrity -Root $partialReleaseRoot)) {
    throw "The relocated release failed integrity validation and was preserved for review: $partialReleaseRoot"
  }
  Move-Item -LiteralPath $partialReleaseRoot -Destination $releaseRoot
  $stageRelocatedToRelease = $true
}

$nativeHost = Join-Path $releaseRoot 'WorkspaceWidget.exe'
$installedAppScript = Join-Path $releaseRoot 'app\WorkspaceWidget.ps1'
$installedShortcutIcon = Join-Path $releaseRoot 'assets\workspace-widget.ico'

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $BackupRoot = Join-Path `
    $env:LOCALAPPDATA `
    "WorkspaceWidget\Backups\$SessionId\$stamp-native-widget-install"
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$backupEntries = [System.Collections.Generic.List[object]]::new()

function Add-BackupEntry {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$RelativeBackupPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    return
  }

  $destination = Join-Path $BackupRoot $RelativeBackupPath
  $destinationParent = Split-Path -Parent $destination
  New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  Copy-Item -LiteralPath $SourcePath -Destination $destination -Force

  $item = Get-Item -LiteralPath $SourcePath
  $backupEntries.Add([ordered]@{
      sessionId = $SessionId
      task = 'workspace-native-widget-install'
      timestamp = (Get-Date).ToString('o')
      sourcePath = $SourcePath
      backupPath = $destination
      size = $item.Length
      modifiedTime = $item.LastWriteTime.ToString('o')
      sha256 = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    })
}

Add-BackupEntry -SourcePath $statePath -RelativeBackupPath 'WorkspaceServiceWidget\state.json'
Add-BackupEntry -SourcePath $shortcutPath -RelativeBackupPath 'Desktop\Workspace Widget.lnk'
Add-BackupEntry -SourcePath $startMenuShortcutPath -RelativeBackupPath 'StartMenu\Workspace Widget.lnk'
Add-BackupEntry -SourcePath $rainmeterSettings -RelativeBackupPath 'Rainmeter\Rainmeter.ini'

$existingTask = Get-ScheduledTask `
  -TaskName $TaskName `
  -TaskPath $TaskPath `
  -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
  $taskBackupPath = Join-Path $BackupRoot 'scheduled-task.xml'
  Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath |
    Set-Content -LiteralPath $taskBackupPath -Encoding UTF8
  $taskBackupItem = Get-Item -LiteralPath $taskBackupPath
  $backupEntries.Add([ordered]@{
      sessionId = $SessionId
      task = 'workspace-native-widget-install'
      timestamp = (Get-Date).ToString('o')
      sourcePath = "Task Scheduler::$TaskPath$TaskName"
      backupPath = $taskBackupPath
      size = $taskBackupItem.Length
      modifiedTime = $taskBackupItem.LastWriteTime.ToString('o')
      sha256 = (Get-FileHash -LiteralPath $taskBackupPath -Algorithm SHA256).Hash
    })
}

$index = [ordered]@{
  sessionId = $SessionId
  task = 'workspace-native-widget-install'
  timestamp = (Get-Date).ToString('o')
  files = @($backupEntries)
}
$index | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BackupRoot 'index.json') -Encoding UTF8

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  Copy-Item -LiteralPath $defaultState -Destination $statePath
}

if (Test-Path -LiteralPath $rainmeterPath -PathType Leaf) {
  & $rainmeterPath '!DeactivateConfig' 'WorkspaceServiceLauncher'
}

$otherWidgetProcesses = @(
  Get-CimInstance Win32_Process `
    -Filter "Name='WorkspaceWidget.exe'" `
    -ErrorAction SilentlyContinue |
    Where-Object {
      [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -or
      -not [string]::Equals(
        [System.IO.Path]::GetFullPath([string]$_.ExecutablePath),
        $nativeHost,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    }
)
if ($otherWidgetProcesses.Count -gt 0) {
  throw (
    'A Workspace Widget process appeared after installer preflight. Exit it from ' +
    'the tray menu and rerun the installer; the installer will not force-stop it. ' +
    'PIDs: ' +
    (@($otherWidgetProcesses | ForEach-Object { [string]$_.ProcessId }) -join ', ')
  )
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$autostartOutput = & $windowsPowerShell `
  -NoLogo `
  -NoProfile `
  -NonInteractive `
  -ExecutionPolicy Bypass `
  -File $autostartScript `
  -Action Ensure `
  -ProjectRoot $releaseRoot `
  -HostPath $nativeHost `
  -TaskName $TaskName `
  -TaskPath $TaskPath
if ($LASTEXITCODE -ne 0) {
  throw "Autostart registration failed.`n$($autostartOutput -join [Environment]::NewLine)"
}
$autostartResult = $autostartOutput | ConvertFrom-Json
if (-not $autostartResult.success -or -not $autostartResult.configured) {
  throw "Autostart registration did not reach a configured state."
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $nativeHost
$shortcut.Arguments = "--state-path `"$statePath`""
$shortcut.WorkingDirectory = Split-Path -Parent $nativeHost
$shortcut.Description = 'Restart or focus the Workspace desktop launcher'
$shortcut.IconLocation = "$installedShortcutIcon,0"
$shortcut.Save()
$startMenuShortcut = $shell.CreateShortcut($startMenuShortcutPath)
$startMenuShortcut.TargetPath = $nativeHost
$startMenuShortcut.Arguments = "--state-path `"$statePath`""
$startMenuShortcut.WorkingDirectory = Split-Path -Parent $nativeHost
$startMenuShortcut.Description = 'Restart or focus the Workspace desktop launcher'
$startMenuShortcut.IconLocation = "$installedShortcutIcon,0"
$startMenuShortcut.Save()

$previousHostOverride = $env:WORKSPACE_WIDGET_HOST_PATH
try {
  $env:WORKSPACE_WIDGET_HOST_PATH = $nativeHost
  $startResult = & $launcherScript `
    -ProjectRoot $releaseRoot `
    -StatePath $statePath |
    ConvertFrom-Json
} finally {
  if ($null -eq $previousHostOverride) {
    Remove-Item Env:WORKSPACE_WIDGET_HOST_PATH -ErrorAction SilentlyContinue
  } else {
    $env:WORKSPACE_WIDGET_HOST_PATH = $previousHostOverride
  }
}

$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath

[pscustomobject]@{
  installed = $true
  runtime = 'WorkspaceWidget.exe with embedded Windows PowerShell runspace'
  nativeHost = $nativeHost
  appScript = $installedAppScript
  releaseRoot = $releaseRoot
  releaseId = $releaseId
  releaseFingerprint = $releaseFingerprint
  installBuildRoot = $installBuildRoot
  stageRelocatedToRelease = $stageRelocatedToRelease
  statePath = $statePath
  shortcutPath = $shortcutPath
  startMenuShortcutPath = $startMenuShortcutPath
  backupRoot = $BackupRoot
  taskName = $TaskName
  taskPath = $TaskPath
  taskEnabled = $task.Settings.Enabled
  taskConfigured = $autostartResult.configured
  taskUserControlGranted = $autostartResult.securityDescriptorApplied
  launchPathPrivate = $autostartResult.launchPathPrivate
  taskState = $task.State.ToString()
  lastTaskResult = $taskInfo.LastTaskResult
  taskExecute = $task.Actions[0].Execute
  taskArguments = $task.Actions[0].Arguments
  processId = $startResult.processId
  oldRainmeterSkinDeactivated = Test-Path -LiteralPath $rainmeterPath -PathType Leaf
} | ConvertTo-Json -Depth 5
