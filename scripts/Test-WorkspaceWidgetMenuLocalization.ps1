#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
  throw 'Run this WPF menu regression harness with Windows PowerShell -STA.'
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$widgetPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
foreach ($path in @($experiencePath,$widgetPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required source was not found: $path" }
}

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition,[Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Import-CurrentWidgetFunction {
  param([string]$Path,[string]$Name)
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -ne 0){throw "PowerShell parse failed: $Path"}
  $definition=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }.GetNewClosure(),$true))
  if($definition.Count -ne 1){throw "Expected exactly one function '$Name' in $Path"}
  $body=$definition[0].Body.Extent.Text.Trim()
  if($body.StartsWith('{') -and $body.EndsWith('}')){$body=$body.Substring(1,$body.Length-2)}
  Set-Item -Path ("Function:script:{0}" -f $Name) -Value ([scriptblock]::Create($body))
}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. $experiencePath
foreach($name in @('Convert-ToBrush','New-ContextMenuItem')) {
  Import-CurrentWidgetFunction -Path $widgetPath -Name $name
}

$script:state=[pscustomobject]@{window=[pscustomobject]@{language='en-US'}}
$server=[pscustomobject]@{id='server';name='Localization fixture';registrationType='server'}
$ordinary=[pscustomobject]@{id='ordinary';name='Ordinary fixture';registrationType='ordinary'}
$copy=('{"start":"\uc2dc\uc791","stop":"\uc885\ub8cc"}' | ConvertFrom-Json)
$checks=[ordered]@{}

$englishMenu=[Windows.Controls.ContextMenu]::new()
Add-WidgetServerMenuItems -Menu $englishMenu -Item $server
$checks.englishUsesActualWpfMenuItems=(
  $englishMenu.Items.Count -eq 2 -and
  $englishMenu.Items[0] -is [Windows.Controls.MenuItem] -and
  $englishMenu.Items[1] -is [Windows.Controls.MenuItem] -and
  $englishMenu.Items[0].Header -ceq 'Start' -and
  $englishMenu.Items[1].Header -ceq 'Stop'
)

$script:state.window.language='ko-KR'
$koreanMenu=[Windows.Controls.ContextMenu]::new()
Add-WidgetServerMenuItems -Menu $koreanMenu -Item $server
$checks.koreanUsesGetWidgetText=(
  $koreanMenu.Items.Count -eq 2 -and
  $koreanMenu.Items[0] -is [Windows.Controls.MenuItem] -and
  $koreanMenu.Items[1] -is [Windows.Controls.MenuItem] -and
  $koreanMenu.Items[0].Header -ceq $copy.start -and
  $koreanMenu.Items[1].Header -ceq $copy.stop
)

$ordinaryMenu=[Windows.Controls.ContextMenu]::new()
Add-WidgetServerMenuItems -Menu $ordinaryMenu -Item $ordinary
$checks.ordinaryHasNoServerActions=$ordinaryMenu.Items.Count -eq 0

Remove-Variable -Name state -Scope Script -ErrorAction SilentlyContinue
$checks.missingStateFallsBackToEnglish=(Get-WidgetText 'Start') -ceq 'Start'

$failed=@($checks.GetEnumerator() | Where-Object {-not $_.Value} | ForEach-Object {$_.Key})
[pscustomobject]@{
  success=$failed.Count -eq 0
  checkCount=$checks.Count
  checks=$checks
  failedChecks=$failed
  scope='AST-imported New-ContextMenuItem with the real Add-WidgetServerMenuItems helper and WPF ContextMenu instances.'
}|ConvertTo-Json -Depth 4 -Compress
if($failed.Count -gt 0){exit 1}
