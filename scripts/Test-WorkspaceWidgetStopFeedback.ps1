[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Add-Type -TypeDefinition @'
namespace WorkspaceWidget.Native {
  public static class ManagedServiceClient {
    public static int Calls;
    public static int Timeout;
    public static bool Force;
    public static string HealthJson;
    public static string StopTarget;
    public static string StopArgs;
    public static object StopV2Async(string root, string id, string digest, string healthJson, string stopTarget, string stopArgs, bool force, int timeout) {
      Calls++; Timeout = timeout; Force = force; HealthJson = healthJson; StopTarget = stopTarget; StopArgs = stopArgs; return new object();
    }
  }
}
'@
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Widget parse failed.' }
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
. $experiencePath
$script:state = Get-Content -LiteralPath (Join-Path $ProjectRoot 'app\public-default-state.json') -Raw | ConvertFrom-Json
Initialize-ExperienceState -WindowState $script:state.window
$scriptRoot = Join-Path $ProjectRoot 'app'
foreach ($name in @('Stop-TrackedLocalServer', 'Invoke-ServerLifecycleMenuAction')) {
  $definition = $ast.Find({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true)
  if (!$definition) { throw "Missing function: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-ManagedLocalServerStatus { param($Item) return $script:status }
function Get-LocalServerContractDigest { param($Item) return 'fixture' }
function Wait-ServerLifecycleTask { param($Task, $Item) return $script:result }
function Write-RuntimeLog { param($Message) }
function Test-TrackedLocalServer { param($Item) return $true }
function Show-Toast { param($Message) $script:toast = $Message }
function Start-HealthCheck { $script:healthRefreshes++ }
$runtimeRoot = 'fixture-only'
$item = [pscustomobject]@{
  id='fixture';name='Fixture';registrationType='server';startupTarget='C:\fixture\server.mjs';startupArgs=''
  health='http://127.0.0.1:1/health';healthChecks=@([pscustomobject]@{name='Primary';url='http://127.0.0.1:1/health'})
  stopTarget=(Join-Path $scriptRoot 'managed-stop.mjs');stopArgs='--graceful'
}
$script:serverProcesses = @{fixture='retained'}
$script:pendingOpen = @{fixture='retained'}
$script:healthStates = @{fixture=$true}
$script:healthRefreshes = 0
$script:status = [pscustomobject]@{state='RunningOwned';stoppable=$true}
$script:result = [pscustomobject]@{state='Partial';success=$false;jobEmpty=$true;healthOffline=$false;receiptPath='fixture'}
$script:state.window.language = 'en-US'
Invoke-ServerLifecycleMenuAction -Item $item
if ($script:toast -ne ((Get-WidgetText 'Stop not confirmed for {0}. Check server status and the runtime log.') -f $item.name)) { throw 'English failure feedback did not match the localized template.' }
if (!$script:serverProcesses.ContainsKey('fixture') -or !$script:pendingOpen.ContainsKey('fixture') -or !$script:healthStates.fixture) {
  throw 'Partial stop discarded retained state.'
}
if ([WorkspaceWidget.Native.ManagedServiceClient]::Timeout -ne 40000 -or [WorkspaceWidget.Native.ManagedServiceClient]::Force -or
    [WorkspaceWidget.Native.ManagedServiceClient]::HealthJson -ne '["http://127.0.0.1:1/health"]' -or
    [WorkspaceWidget.Native.ManagedServiceClient]::StopTarget -ne $item.stopTarget -or
    [WorkspaceWidget.Native.ManagedServiceClient]::StopArgs -ne '--graceful') {
  throw 'Graceful stop budget or force default changed.'
}
$script:result.state='Graceful'; $script:result.success=$true; $script:result.healthOffline=$true
Invoke-ServerLifecycleMenuAction -Item $item
if ($script:toast -ne ((Get-WidgetText 'Stopped {0}') -f $item.name) -or $script:serverProcesses.ContainsKey('fixture') -or $script:pendingOpen.ContainsKey('fixture') -or $script:healthStates.fixture -or $script:healthRefreshes -ne 1) {
  throw 'Verified stop did not clear pending state and refresh health.'
}
$script:state.window.language = 'ko-KR'
$script:serverProcesses = @{fixture='retained'}
$script:pendingOpen = @{fixture='retained'}
$script:healthStates = @{fixture=$true}
$script:healthRefreshes = 0
$script:status = [pscustomobject]@{state='RunningOwned';stoppable=$true}
$script:result = [pscustomobject]@{state='Partial';success=$false;jobEmpty=$true;healthOffline=$false;receiptPath='fixture'}
Invoke-ServerLifecycleMenuAction -Item $item
if ($script:toast -ne ((Get-WidgetText 'Stop not confirmed for {0}. Check server status and the runtime log.') -f $item.name)) { throw 'Korean failure feedback did not match the localized template.' }
if (!$script:serverProcesses.ContainsKey('fixture') -or !$script:pendingOpen.ContainsKey('fixture') -or !$script:healthStates.fixture) {
  throw 'Korean partial stop discarded retained state.'
}
$script:result.state='Graceful'; $script:result.success=$true; $script:result.healthOffline=$true
Invoke-ServerLifecycleMenuAction -Item $item
if ($script:toast -ne ((Get-WidgetText 'Stopped {0}') -f $item.name) -or $script:serverProcesses.ContainsKey('fixture') -or $script:pendingOpen.ContainsKey('fixture') -or $script:healthStates.fixture -or $script:healthRefreshes -ne 1) {
  throw 'Korean verified stop did not clear pending state and refresh health.'
}
$script:status = [pscustomobject]@{state='RunningUnowned';stoppable=$false}
$calls = [WorkspaceWidget.Native.ManagedServiceClient]::Calls
if (Stop-TrackedLocalServer -Item $item) { throw 'Foreign ownership was accepted.' }
if ([WorkspaceWidget.Native.ManagedServiceClient]::Calls -ne $calls) { throw 'Foreign server received a stop.' }
$script:status = [pscustomobject]@{state='RunningOwned';stoppable=$true}
$script:result.state='NeedsForce'; $script:result.success=$false
if (Stop-TrackedLocalServer -Item $item) { throw 'Timeout was accepted as a stop.' }
if ([WorkspaceWidget.Native.ManagedServiceClient]::Force) { throw 'Force was used without confirmation.' }
[pscustomobject]@{success=$true;checks=14;scope='Actual Stop-TrackedLocalServer uses production health/stop contract helpers with mock StopV2Async transport; no real processes or user state changed'} | ConvertTo-Json
