#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework

function Assert-That {
  param([bool]$Condition, [string]$Message)
  if (!$Condition) { throw $Message }
}

$workspacePath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$source = [IO.File]::ReadAllText($workspacePath, [Text.UTF8Encoding]::new($false, $true))
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($workspacePath, [ref]$tokens, [ref]$errors)
Assert-That ($errors.Count -eq 0) 'WorkspaceWidget source does not parse.'

$script:state = [pscustomobject]@{ window = [pscustomobject]@{ language = 'ko-KR' } }
. $experiencePath
Assert-That ((Get-WidgetText '+ Add shortcut') -ceq '+ 바로가기 추가') 'Korean dictionary lookup for the footer action failed.'
$button = [System.Windows.Controls.Button]::new()
$button.Content = '+ Add shortcut'
$script:addShortcutButton = $button
$footer = [System.Windows.Controls.Border]::new()
$footer.Child = $button
$script:footer = $footer
$script:toolbar = [System.Windows.Controls.StackPanel]::new()
$script:minUiModeCheck = [System.Windows.Controls.CheckBox]::new()
$script:panelBorder = [System.Windows.Controls.Border]::new()
$script:fullHeaderIdentity = [System.Windows.Controls.StackPanel]::new()
$script:header = [System.Windows.Controls.Grid]::new()
$script:opacityPanel = [System.Windows.Controls.Border]::new()
$script:settingsPanel = [System.Windows.Controls.Border]::new()
$script:pageDotsPanel = [System.Windows.Controls.StackPanel]::new()
$script:resizeHandle = [System.Windows.Controls.Border]::new()
$script:dropText = [System.Windows.Controls.TextBlock]::new()
$script:minUiModeButton = [System.Windows.Controls.Button]::new()
function Set-ToolbarCompactMode { param([bool]$Compact) }
function Update-ResponsiveHeader { }

$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-WidgetModeVisualState' }, $true)
Assert-That ($null -ne $definition) 'Set-WidgetModeVisualState was not found.'
. ([scriptblock]::Create($definition.Extent.Text))

Set-WidgetModeVisualState -Enabled $true
Set-WidgetModeVisualState -Enabled $false
Assert-That ([string]$button.Content -ceq '+ 바로가기 추가') 'Korean footer Add shortcut text was not restored after MIN-to-full mode change.'
$script:state.window.language = 'en-US'
Set-WidgetModeVisualState -Enabled $true
Set-WidgetModeVisualState -Enabled $false
Assert-That ([string]$button.Content -ceq '+ Add shortcut') 'English footer Add shortcut text did not round-trip after mode change.'
Assert-That ($source.Contains('Content="+ Add shortcut"')) 'Footer XAML does not use the dictionary source key.'
Assert-That ($definition.Extent.Text.Contains('Set-WidgetLocalizedTree $script:footer')) 'Mode visual-state function does not relocalize the footer.'

[pscustomobject]@{
  success = $true
  checks = 4
  scope = 'Production Set-WidgetModeVisualState AST body with an in-memory WPF footer; no app window, service, or user state was used.'
} | ConvertTo-Json -Compress
