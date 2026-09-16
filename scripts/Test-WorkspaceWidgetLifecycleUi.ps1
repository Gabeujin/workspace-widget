#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot, [string]$HostPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Current UI coverage: the product renders independent Start/Stop entries from
# WidgetExperience, plus a responsive progress dialog and an exit that preserves
# separately supervised servers.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
function Import-CurrentWidgetFunction {
  param([string]$Path, [string]$Name)
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "PowerShell parse failed: $Path" }
  $definition = @($ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }.GetNewClosure(), $true))
  if ($definition.Count -ne 1) { throw "Expected one function '$Name' in $Path" }
  $body = $definition[0].Body.Extent.Text.Trim()
  if ($body.StartsWith('{') -and $body.EndsWith('}')) {
    $body = $body.Substring(1, $body.Length - 2)
  }
  Set-Item -Path ("Function:script:{0}" -f $Name) -Value ([scriptblock]::Create($body))
}
. $experiencePath
foreach ($name in @('Convert-ToBrush', 'New-ContextMenuItem', 'Wait-ServerLifecycleTask', 'Exit-WorkspaceWidget')) {
  Import-CurrentWidgetFunction -Path $sourcePath -Name $name
}
$script:state = Get-Content -LiteralPath (Join-Path $ProjectRoot 'app\public-default-state.json') -Raw | ConvertFrom-Json
Initialize-ExperienceState -WindowState $script:state.window
$script:state.window.language = 'en-US'
$scriptRoot = Join-Path $ProjectRoot 'app'
$script:events = [Collections.Generic.List[string]]::new()
$script:healthRefreshes = 0; $script:throwStart = $false; $script:throwStop = $false
function Queue-NodeStart { param($Item, [bool]$OpenWhenHealthy, [bool]$RestartTrackedProcess)
  if ($script:throwStart) { throw 'start fixture failure' }
  $script:events.Add(('start:{0}:{1}:{2}' -f $Item.id, $OpenWhenHealthy, $RestartTrackedProcess))
}
function Stop-TrackedLocalServer { param($Item, [switch]$ConfirmForce, [switch]$AllowMissing)
  if ($script:throwStop) { throw 'stop fixture failure' }
  $script:events.Add(('stop:{0}:{1}:{2}' -f $Item.id, [bool]$ConfirmForce, [bool]$AllowMissing))
  return [bool]$script:stopResult
}
function Start-HealthCheck { $script:healthRefreshes++ }
function Show-Toast { param([string]$Message) $script:lastToast = $Message }
function Write-RuntimeLog { param([string]$Message) $script:events.Add("log:$Message") }
$server = [pscustomobject]@{id='server';name='Fixture server';registrationType='server';startupTarget='C:\fixture\server.mjs';startupArgs='';health='http://127.0.0.1:4519/health';healthChecks=@([pscustomobject]@{name='Primary';url='http://127.0.0.1:4519/health'});stopTarget=(Join-Path $scriptRoot 'managed-stop.mjs');stopArgs=''}
$ordinary = [pscustomobject]@{id='ordinary';name='Fixture app';registrationType='ordinary';target='C:\Windows\notepad.exe';healthChecks=@()}
$serverMenu = [Windows.Controls.ContextMenu]::new(); $ordinaryMenu = [Windows.Controls.ContextMenu]::new()
Add-WidgetServerMenuItems -Menu $serverMenu -Item $server
Add-WidgetServerMenuItems -Menu $ordinaryMenu -Item $ordinary
$start = $serverMenu.Items[0]; $stop = $serverMenu.Items[1]
$start.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
$startNoImplicitRestart = $script:events -contains 'start:server:False:False'
$script:stopResult = $true
$stop.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
$gracefulStop = ($script:events -contains 'stop:server:True:True') -and $script:healthRefreshes -eq 1
$script:stopResult = $false
$stop.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
$failedStopFeedback = $script:lastToast -eq 'Server stop was not confirmed. No unowned process was stopped.'
$script:throwStart = $true
$start.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
$startErrorCaught = $script:lastToast -eq 'Could not start the server. Check its start script and health URLs.' -and @($script:events | Where-Object { $_ -match '^log:Server start action failed\.' }).Count -eq 1
$script:throwStop = $true
$stop.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
$stopErrorCaught = $script:lastToast -eq 'Server stop was not confirmed. No unowned process was stopped.' -and @($script:events | Where-Object { $_ -match '^log:Server stop action failed\.' }).Count -eq 1
$script:window = [Windows.Window]::new()
$script:window.Width = 220; $script:window.Height = 80; $script:window.ShowInTaskbar = $false
$script:window.Show()
$script:trayIcon = [pscustomobject]@{Visible=$true}
$script:allowExit = $false; $script:closed = $false; $StartupProbe = $false
$script:window.Add_Closed({ $script:closed = $true })
$progressTask = [Threading.Tasks.Task]::FromResult('{"success":true,"state":"Graceful","jobEmpty":true,"healthOffline":true}')
$progressResult = Wait-ServerLifecycleTask -Task $progressTask -Item $server -Action Stop
Exit-WorkspaceWidget
$checks = [ordered]@{
  productionHelperHealthJson = (Get-ItemHealthJson $server) -eq '["http://127.0.0.1:4519/health"]'
  productionHelperOrdinaryHasNoHealthJson = (Get-ItemHealthJson $ordinary) -eq '[]'
  productionLanguageHelperEnglish = (Get-WidgetText 'Start') -eq 'Start'
  separateStartStopItems = $serverMenu.Items.Count -eq 2 -and $start.Header -eq 'Start' -and $stop.Header -eq 'Stop'
  ordinaryHasNoServerActions = $ordinaryMenu.Items.Count -eq 0
  startDoesNotImplicitlyRestart = $startNoImplicitRestart
  gracefulStopRequestsConfirmationPath = $gracefulStop
  stopFailureShowsSafeFeedback = $failedStopFeedback
  startErrorsAreCaught = $startErrorCaught
  stopErrorsAreCaught = $stopErrorCaught
  progressDialogCompletes = [bool]$progressResult.success -and $progressResult.state -eq 'Graceful'
  exitPreservesServers = [bool]$script:allowExit -and $script:closed -and -not [bool]$script:trayIcon.Visible -and
    @($script:events | Where-Object { $_ -match '^log:Workspace exit requested.*Managed servers keep running' }).Count -eq 1
}
$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
[pscustomobject]@{success=$failed.Count -eq 0;checks=$checks;failedChecks=$failed;scope='Actual separate Start/Stop WPF callbacks, progress dialog, and exit preservation with production WidgetExperience helpers and fixture-only lifecycle functions.'}|ConvertTo-Json -Depth 5
if ($failed.Count -gt 0) { exit 1 }
