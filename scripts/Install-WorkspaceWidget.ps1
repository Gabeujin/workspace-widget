[CmdletBinding()]
param(
  [string]$ProjectRoot,
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

$nativeHost = @(
  (Join-Path $ProjectRoot 'WorkspaceWidget.exe'),
  (Join-Path $ProjectRoot 'artifacts\staging\WorkspaceWidget\WorkspaceWidget.exe')
) |
  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
  Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($nativeHost)) {
  $buildResult = & $buildScript -ProjectRoot $ProjectRoot -SkipInstaller |
    ConvertFrom-Json
  if (-not $buildResult.success) {
    throw 'WorkspaceWidget.exe build did not report success.'
  }
  $nativeHost = Join-Path ([string]$buildResult.stageRoot) 'WorkspaceWidget.exe'
}
$nativeHost = [System.IO.Path]::GetFullPath($nativeHost)

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

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$autostartOutput = & $windowsPowerShell `
  -NoLogo `
  -NoProfile `
  -NonInteractive `
  -ExecutionPolicy Bypass `
  -File $autostartScript `
  -Action Ensure `
  -ProjectRoot $ProjectRoot `
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
$shortcut.IconLocation = "$shortcutIcon,0"
$shortcut.Save()

$startResult = & $launcherScript -ProjectRoot $ProjectRoot -StatePath $statePath | ConvertFrom-Json

$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath

[pscustomobject]@{
  installed = $true
  runtime = 'WorkspaceWidget.exe with embedded Windows PowerShell runspace'
  nativeHost = $nativeHost
  appScript = $appScript
  statePath = $statePath
  shortcutPath = $shortcutPath
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
