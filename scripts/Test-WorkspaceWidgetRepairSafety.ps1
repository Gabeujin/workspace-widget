#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$repairScript = Join-Path $ProjectRoot 'scripts\Repair-WorkspaceWidgetLifecycle.ps1'
if (-not (Test-Path -LiteralPath $repairScript -PathType Leaf)) { throw 'Repair script was not found.' }

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-RepairFixture {
  param([Parameter(Mandatory = $true)][hashtable]$Arguments, [switch]$ExpectFailure)

  $priorErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive `
      -ExecutionPolicy Bypass -File $repairScript @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $priorErrorActionPreference
  }
  if ($ExpectFailure) {
    Assert-That ($exitCode -ne 0) 'Repair unexpectedly accepted an unsafe fixture.'
    return ($output -join [Environment]::NewLine)
  }
  if ($exitCode -ne 0) { throw "Repair fixture failed: $($output -join [Environment]::NewLine)" }
  return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Set-PrivateFixtureAcl {
  param([Parameter(Mandatory = $true)][string]$Path)

  $items = @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
  foreach ($item in $items) {
    $acl = if ($item.PSIsContainer) {
      [Security.AccessControl.DirectorySecurity]::new()
    } else {
      [Security.AccessControl.FileSecurity]::new()
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($item.PSIsContainer) {
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
      [Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($sid in @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
      )) {
      $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,
        [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $item.FullName -AclObject $acl
  }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('widget-repair-safety-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stageRoot = Join-Path $fixtureRoot 'stage'
$previousRoot = Join-Path $fixtureRoot 'previous'
$targetRoot = Join-Path $fixtureRoot 'target'
$shortcutRoot = Join-Path $fixtureRoot 'shortcuts'
$backupRoot = Join-Path $fixtureRoot 'backups'
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'assets'), $previousRoot, $shortcutRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $stageRoot 'WorkspaceWidget.exe'), 'fixture-host', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $stageRoot 'assets\workspace-widget.ico'), 'fixture-icon', [Text.UTF8Encoding]::new($false))
$previousHost = Join-Path $previousRoot 'WorkspaceWidget.exe'
[IO.File]::WriteAllText($previousHost, 'previous-host', [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $targetRoot 'assets') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $stageRoot 'WorkspaceWidget.exe') -Destination (Join-Path $targetRoot 'WorkspaceWidget.exe')
Copy-Item -LiteralPath (Join-Path $stageRoot 'assets\workspace-widget.ico') -Destination (Join-Path $targetRoot 'assets\workspace-widget.ico')
Set-PrivateFixtureAcl -Path $targetRoot
$manifestPath = Join-Path $fixtureRoot 'manifest.json'
$manifest = [ordered]@{
  product = 'Workspace Widget'
  files = @(
    [ordered]@{ path = 'WorkspaceWidget.exe'; size = (Get-Item (Join-Path $stageRoot 'WorkspaceWidget.exe')).Length; sha256 = (Get-FileHash (Join-Path $stageRoot 'WorkspaceWidget.exe') -Algorithm SHA256).Hash },
    [ordered]@{ path = 'assets\workspace-widget.ico'; size = (Get-Item (Join-Path $stageRoot 'assets\workspace-widget.ico')).Length; sha256 = (Get-FileHash (Join-Path $stageRoot 'assets\workspace-widget.ico') -Algorithm SHA256).Hash }
  )
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$shell = New-Object -ComObject WScript.Shell
$desktopShortcut = Join-Path $shortcutRoot 'desktop.lnk'
$startShortcut = Join-Path $shortcutRoot 'start.lnk'
foreach ($shortcutPath in @($desktopShortcut, $startShortcut)) {
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $previousHost
  $shortcut.Arguments = '--state-path fixture.json'
  $shortcut.Description = 'fixture shortcut'
  $shortcut.Hotkey = 'CTRL+ALT+W'
  $shortcut.WindowStyle = 7
  $shortcut.WorkingDirectory = $previousRoot
  $shortcut.IconLocation = "$previousRoot\fixture.ico,0"
  $shortcut.Save()
}
$desktopHash = (Get-FileHash $desktopShortcut -Algorithm SHA256).Hash
$startHash = (Get-FileHash $startShortcut -Algorithm SHA256).Hash
$base = @{
  StageRoot = $stageRoot
  ManifestPath = $manifestPath
  ExpectedPreviousHost = $previousHost
  SessionId = 'repair-safety'
  BackupRoot = $backupRoot
  DesktopShortcutPath = $desktopShortcut
  StartMenuShortcutPath = $startShortcut
}

$successArgs = @{} + $base; $successArgs.TargetRoot = $targetRoot
$result = Invoke-RepairFixture -Arguments $successArgs
Assert-That ([bool]$result.success -and [IO.Path]::GetFullPath([string]$result.targetRoot) -eq $targetRoot) `
  'Repair did not produce the isolated side-by-side target.'
$index = Get-Content -LiteralPath (Join-Path $backupRoot 'index.json') -Raw -Encoding utf8 | ConvertFrom-Json
Assert-That ([bool]$index.retargeted -and @($index.backupEntries).Count -eq 2) `
  'Repair did not write the final exact backup index.'
foreach ($entry in @($index.backupEntries)) {
  Assert-That ((Test-Path -LiteralPath $entry.backupPath -PathType Leaf) -and
    (Get-FileHash -LiteralPath $entry.backupPath -Algorithm SHA256).Hash -eq $entry.sha256) `
    'A repair shortcut backup did not exactly match its indexed hash.'
}
Assert-That ($desktopHash -eq (Get-FileHash (Join-Path $backupRoot 'Desktop\Workspace Widget.lnk') -Algorithm SHA256).Hash -and
  $startHash -eq (Get-FileHash (Join-Path $backupRoot 'StartMenu\Workspace Widget.lnk') -Algorithm SHA256).Hash) `
  'Repair did not preserve the original shortcut bytes in the fixture backup.'
foreach ($shortcutPath in @($desktopShortcut, $startShortcut)) {
  $readback = $shell.CreateShortcut($shortcutPath)
  Assert-That ([IO.Path]::GetFullPath($readback.TargetPath) -eq (Join-Path $targetRoot 'WorkspaceWidget.exe') -and
    $readback.Arguments -ceq '--state-path fixture.json' -and $readback.Description -ceq 'fixture shortcut') `
    'Repair did not preserve approved shortcut fields while retargeting the fixture.'
}

$aliasArgs = @{} + $base; $aliasArgs.TargetRoot = $stageRoot; $aliasArgs.BackupRoot = Join-Path $fixtureRoot 'alias-backup'
[void](Invoke-RepairFixture -Arguments $aliasArgs -ExpectFailure)

$escapeManifest = Join-Path $fixtureRoot 'escape-manifest.json'
([ordered]@{ product = 'Workspace Widget'; files = @([ordered]@{ path = '..\escape.bin'; size = 1; sha256 = ('0' * 64) }) }) |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $escapeManifest -Encoding utf8
$escapeArgs = @{} + $base; $escapeArgs.ManifestPath = $escapeManifest; $escapeArgs.TargetRoot = Join-Path $fixtureRoot 'escape-target'; $escapeArgs.BackupRoot = Join-Path $fixtureRoot 'escape-backup'
[void](Invoke-RepairFixture -Arguments $escapeArgs -ExpectFailure)
Assert-That (-not (Test-Path -LiteralPath $escapeArgs.TargetRoot)) 'Escaping manifest created a target path.'

$junctionDestination = Join-Path $fixtureRoot 'junction-destination'
$junctionTarget = Join-Path $fixtureRoot 'junction-target'
New-Item -ItemType Directory -Path $junctionDestination -Force | Out-Null
New-Item -ItemType Junction -Path $junctionTarget -Target $junctionDestination | Out-Null
$junctionArgs = @{} + $base; $junctionArgs.TargetRoot = $junctionTarget; $junctionArgs.BackupRoot = Join-Path $fixtureRoot 'junction-backup'
[void](Invoke-RepairFixture -Arguments $junctionArgs -ExpectFailure)

$broadTarget = Join-Path $fixtureRoot 'broad-target'
New-Item -ItemType Directory -Path $broadTarget -Force | Out-Null
$acl = Get-Acl -LiteralPath $broadTarget
$everyone = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid, $null)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone,
  [Security.AccessControl.FileSystemRights]::Modify, [Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $broadTarget -AclObject $acl
$broadArgs = @{} + $base; $broadArgs.TargetRoot = $broadTarget; $broadArgs.BackupRoot = Join-Path $fixtureRoot 'broad-backup'
[void](Invoke-RepairFixture -Arguments $broadArgs -ExpectFailure)

[pscustomobject]@{
  success = $true
  fixtureRoot = $fixtureRoot
  assertions = 15
  scope = 'retained temporary shortcut fixtures; no installed app, service, state, or scheduled task mutation'
} | ConvertTo-Json -Compress
