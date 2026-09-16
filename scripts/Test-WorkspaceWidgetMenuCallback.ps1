[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
namespace WorkspaceWidget.Native {
  public static class ManagedServiceClient {
    public static System.Threading.Tasks.Task<string> StatusAsync(string root, string id, string digest, string health) {
      return System.Threading.Tasks.Task.FromResult("{\"state\":\"RunningUnowned\",\"stoppable\":false}");
    }
  }
}
'@
function Initialize-ManagedServerClient {}
function Get-LocalServerContractDigest { param($Item) return 'test-only' }
$script:healthStates = @{}
$runtimeRoot = 'test-only'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Set-ServerRecoveryMenuState','Update-ServerRecoveryMenuItem')) {
  $definition=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
$menu=[System.Windows.Controls.MenuItem]::new()
$menu.Tag=[pscustomobject]@{id='fixture';health='http://127.0.0.1:1/health'}
Update-ServerRecoveryMenuItem $menu
$frame=[System.Windows.Threading.DispatcherFrame]::new()
$end=[System.Windows.Threading.DispatcherTimer]::new()
$end.Interval=[TimeSpan]::FromMilliseconds(500)
$end.Tag=$frame
$end.Add_Tick({param($sender,$eventArgs) $sender.Stop(); $sender.Tag.Continue=$false})
$end.Start()
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
if ($menu.Header -ne 'Server ownership not verified' -or $menu.IsEnabled) { throw 'Async callback did not enforce foreign ownership' }
[pscustomobject]@{success=$true;scope='real WPF Dispatcher callback; fake native status transport; no server actions'} | ConvertTo-Json
