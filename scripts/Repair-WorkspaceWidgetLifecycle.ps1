[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StageRoot,
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [Parameter(Mandatory = $true)][string]$ExpectedPreviousHost,
  [Parameter(Mandatory = $true)][string]$TargetRoot,
  [Parameter(Mandatory = $true)][string]$BackupRoot,
  [string]$SessionId = 'manual',
  [string]$DesktopShortcutPath,
  [string]$StartMenuShortcutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
$ExpectedPreviousHost = [IO.Path]::GetFullPath($ExpectedPreviousHost)
$targetHost = Join-Path $TargetRoot 'WorkspaceWidget.exe'
$statePath = Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'
$desktopShortcut = if ([string]::IsNullOrWhiteSpace($DesktopShortcutPath)) {
  Join-Path ([Environment]::GetFolderPath('Desktop')) 'Workspace Widget.lnk'
} else {
  [IO.Path]::GetFullPath($DesktopShortcutPath)
}
$startMenuShortcut = if ([string]::IsNullOrWhiteSpace($StartMenuShortcutPath)) {
  Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Workspace Widget.lnk'
} else {
  [IO.Path]::GetFullPath($StartMenuShortcutPath)
}

function Assert-NoReparsePoints {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)

  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrWhiteSpace($root)) { throw "$Name has no filesystem root." }
  $current = $root
  $relative = $full.Substring($root.Length).TrimStart('\')
  if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "$Name uses a reparse-point filesystem root."
  }
  foreach ($part in @($relative -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $current = Join-Path $current $part
    if (-not (Test-Path -LiteralPath $current)) { break }
    if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "$Name contains a reparse point: $current"
    }
  }
}

function Assert-PrivateTargetAcl {
  param([Parameter(Mandatory = $true)][string]$Path)

  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($sid in @(
      $currentSid,
      ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value,
      ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value
    )) {
    $allowed.Add($sid) | Out-Null
  }
  $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Modify -bor
    [Security.AccessControl.FileSystemRights]::FullControl -bor
    [Security.AccessControl.FileSystemRights]::Delete
  $currentCanWrite = $false
  foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
    if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        (($rule.FileSystemRights -band $writeMask) -eq 0)) {
      continue
    }
    try {
      $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
      throw "TargetRoot ACL identity could not be resolved: $($rule.IdentityReference.Value)"
    }
    if (-not $allowed.Contains($sid)) {
      throw "TargetRoot grants write-capable access outside the current user, Administrators, or SYSTEM: $sid"
    }
    if ([string]::Equals($sid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
      $currentCanWrite = $true
    }
  }
  if (-not $currentCanWrite) {
    throw 'TargetRoot does not explicitly grant the current user write-capable access.'
  }
}

function Resolve-ManifestPath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
    throw "$Name must be a non-empty relative path."
  }
  $normalizedRelative = $RelativePath.Replace('/', '\')
  if (@($normalizedRelative -split '\\' | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
    throw "$Name escapes its release root."
  }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $normalizedRelative))
  if (-not $candidate.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Name escapes its release root."
  }
  return $candidate
}

function Assert-DistinctRepairRoots {
  $previousRoot = Split-Path -Parent $ExpectedPreviousHost
  foreach ($candidate in @($StageRoot, $previousRoot)) {
    if ([string]::Equals($TargetRoot, $candidate, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($targetHost, $ExpectedPreviousHost, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'TargetRoot must be separate from the staged and explicitly approved previous release roots.'
    }
  }
}

foreach ($path in @($StageRoot, $ManifestPath, $ExpectedPreviousHost)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Required repair input was not found: $path" }
}
if ((Get-Item -LiteralPath $StageRoot).PSIsContainer -ne $true) {
  throw 'StageRoot must be a directory.'
}
Assert-NoReparsePoints -Path $StageRoot -Name 'StageRoot'
Assert-NoReparsePoints -Path $ManifestPath -Name 'ManifestPath'
Assert-NoReparsePoints -Path $ExpectedPreviousHost -Name 'ExpectedPreviousHost'
Assert-NoReparsePoints -Path $TargetRoot -Name 'TargetRoot'
Assert-DistinctRepairRoots

$runningWidget = @(Get-CimInstance Win32_Process -Filter "Name='WorkspaceWidget.exe'" -ErrorAction Stop)
$blockingWidget = @($runningWidget | Where-Object {
  $processPath = [string]$_.ExecutablePath
  $commandLine = [string]$_.CommandLine
  # An unreadable identity is not permission to replace a potentially active host.
  if ([string]::IsNullOrWhiteSpace($processPath) -or [string]::IsNullOrWhiteSpace($commandLine)) { return $true }
  $isTarget = [string]::Equals($processPath, $targetHost, [StringComparison]::OrdinalIgnoreCase)
  $isPrevious = [string]::Equals($processPath, $ExpectedPreviousHost, [StringComparison]::OrdinalIgnoreCase)
  $isSupervisor = $commandLine -match '^\s*(?:"[^"]+"|\S+)\s+--service-supervisor\s+[a-fA-F0-9]{32}\s*$'
  # The previous release remains on disk, so its authenticated service host may
  # outlive the UI. A process using the destination release always blocks repair.
  return $isTarget -or ($isPrevious -and -not $isSupervisor)
})
if ($blockingWidget.Count -ne 0) {
  throw 'The selected Widget UI or destination host is still running. Exit that UI first; service supervisors and unrelated test windows are not stopped by this repair.'
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$manifest.product -ne 'Workspace Widget' -or @($manifest.files).Count -eq 0) {
  throw 'The repair manifest is not a Workspace Widget release manifest.'
}
$manifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in @($manifest.files)) {
  $relativePath = [string]$entry.path
  [void](Resolve-ManifestPath -Root $StageRoot -RelativePath $relativePath -Name 'manifest file path')
  [void](Resolve-ManifestPath -Root $TargetRoot -RelativePath $relativePath -Name 'manifest file path')
  if (-not $manifestPaths.Add($relativePath.Replace('/', '\'))) {
    throw "The repair manifest has a duplicate file path: $relativePath"
  }
}

function Test-ReleaseManifest {
  param([Parameter(Mandatory = $true)][string]$Root)

  $expected = @($manifest.files | ForEach-Object { ([string]$_.path).Replace('/', '\') } | Sort-Object)
  $actual = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File |
      ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') } |
      Sort-Object
  )
  if ([string]::Join('|', $expected) -cne [string]::Join('|', $actual)) { return $false }
  foreach ($entry in @($manifest.files)) {
    $path = Resolve-ManifestPath -Root $Root -RelativePath ([string]$entry.path) -Name 'manifest file path'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $path
    if ([int64]$item.Length -ne [int64]$entry.size) { return $false }
    if (-not [string]::Equals((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash,
        [string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

if (-not (Test-ReleaseManifest -Root $StageRoot)) {
  throw 'The staged release does not exactly match its manifest.'
}
if (Test-Path -LiteralPath $TargetRoot) {
  Assert-PrivateTargetAcl -Path $TargetRoot
  if (-not (Test-ReleaseManifest -Root $TargetRoot)) {
    throw 'The side-by-side repair target already exists but failed manifest verification.'
  }
} else {
  New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
  Assert-NoReparsePoints -Path $TargetRoot -Name 'TargetRoot'
  Assert-PrivateTargetAcl -Path $TargetRoot
  foreach ($entry in @($manifest.files)) {
    $source = Resolve-ManifestPath -Root $StageRoot -RelativePath ([string]$entry.path) -Name 'manifest file path'
    $destination = Resolve-ManifestPath -Root $TargetRoot -RelativePath ([string]$entry.path) -Name 'manifest file path'
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
  }
  if (-not (Test-ReleaseManifest -Root $TargetRoot)) {
    throw 'The side-by-side repair target failed manifest readback and was preserved for review.'
  }
}

$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
Assert-NoReparsePoints -Path $BackupRoot -Name 'BackupRoot'
$backupEntries = @()
$shell = New-Object -ComObject WScript.Shell
$shortcutRecords = @()

foreach ($shortcutPath in @($desktopShortcut, $startMenuShortcut)) {
  if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    throw "Required existing shortcut was not found: $shortcutPath"
  }
  $shortcut = $shell.CreateShortcut($shortcutPath)
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$shortcut.TargetPath),
      $ExpectedPreviousHost, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Shortcut target did not match the explicitly approved previous host: $shortcutPath"
  }
  $shortcutKind = if ([string]::Equals($shortcutPath, $desktopShortcut,
      [StringComparison]::OrdinalIgnoreCase)) { 'Desktop' } else { 'StartMenu' }
  $backupPath = Join-Path $BackupRoot (Join-Path $shortcutKind 'Workspace Widget.lnk')
  New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
  $sourceHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash
  Copy-Item -LiteralPath $shortcutPath -Destination $backupPath -ErrorAction Stop
  if (-not [string]::Equals((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash,
      $sourceHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Shortcut backup hash did not match its source: $shortcutPath"
  }
  $shortcutItem = Get-Item -LiteralPath $shortcutPath
  $backupEntries += [ordered]@{
    sourcePath = $shortcutPath
    backupPath = $backupPath
    size = $shortcutItem.Length
    modifiedTime = $shortcutItem.LastWriteTime.ToString('o')
    sha256 = $sourceHash
  }
  $shortcutRecords += [ordered]@{
    path = $shortcutPath
    arguments = [string]$shortcut.Arguments
    description = [string]$shortcut.Description
    hotkey = [string]$shortcut.Hotkey
    windowStyle = [int]$shortcut.WindowStyle
  }
}

$indexPath = Join-Path $BackupRoot 'index.json'
function Write-VerifiedRepairIndex {
  param([Parameter(Mandatory = $true)][bool]$Retargeted, [string]$LaunchCommand)

  [ordered]@{
    sessionId = $SessionId
    task = 'workspace-widget-lifecycle-repair'
    timestamp = (Get-Date).ToString('o')
    stageRoot = $StageRoot
    manifestPath = $ManifestPath
    targetRoot = $TargetRoot
    targetHost = $targetHost
    backupEntries = $backupEntries
    shortcutPreflight = $shortcutRecords
    retargeted = $Retargeted
    noScheduledTaskMutation = $true
    noAutostartMutation = $true
    noRainmeterMutation = $true
    launchCommand = $LaunchCommand
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $indexPath -Encoding utf8

  $readback = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 | ConvertFrom-Json
  if ([string]$readback.sessionId -cne $SessionId -or
      [string]$readback.task -cne 'workspace-widget-lifecycle-repair' -or
      [bool]$readback.retargeted -ne $Retargeted -or
      @($readback.backupEntries).Count -ne $backupEntries.Count) {
    throw 'The shortcut backup index did not survive exact readback before retargeting.'
  }
  foreach ($entry in @($backupEntries)) {
    $stored = @($readback.backupEntries | Where-Object { [string]$_.sourcePath -ceq [string]$entry.sourcePath })
    if ($stored.Count -ne 1 -or [string]$stored[0].backupPath -cne [string]$entry.backupPath -or
        [int64]$stored[0].size -ne [int64]$entry.size -or [string]$stored[0].sha256 -cne [string]$entry.sha256 -or
        -not (Test-Path -LiteralPath ([string]$entry.backupPath) -PathType Leaf) -or
        -not [string]::Equals((Get-FileHash -LiteralPath ([string]$entry.backupPath) -Algorithm SHA256).Hash,
          [string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) {
      throw "The shortcut backup index did not exactly preserve: $($entry.sourcePath)"
    }
  }
}

Write-VerifiedRepairIndex -Retargeted $false

foreach ($record in $shortcutRecords) {
  $shortcutPath = [string]$record.path
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $targetHost
  $shortcut.WorkingDirectory = $TargetRoot
  $shortcut.IconLocation = "$TargetRoot\assets\workspace-widget.ico,0"
  $shortcut.Save()
  $readback = $shell.CreateShortcut($shortcutPath)
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$readback.TargetPath),
      $targetHost, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Shortcut readback did not reach the side-by-side repair host: $shortcutPath"
  }
  if ([string]$readback.Arguments -cne [string]$record.arguments -or
      [string]$readback.Description -cne [string]$record.description -or
      [string]$readback.Hotkey -cne [string]$record.hotkey -or
      [int]$readback.WindowStyle -ne [int]$record.windowStyle -or
      -not [string]::Equals([IO.Path]::GetFullPath([string]$readback.WorkingDirectory),
        $TargetRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([string]$readback.IconLocation,
        "$TargetRoot\assets\workspace-widget.ico,0", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Shortcut readback changed an unapproved field: $shortcutPath"
  }
}

Write-VerifiedRepairIndex -Retargeted $true -LaunchCommand "& '$targetHost' --state-path '$statePath'"

[pscustomobject]@{
  success = $true
  targetRoot = $TargetRoot
  targetHost = $targetHost
  backupRoot = $BackupRoot
  launchCommand = "& '$targetHost' --state-path '$statePath'"
} | ConvertTo-Json -Compress
