#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  throw 'Run this regression with Windows PowerShell -STA.'
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$script:assertions = 0
function Assert-That([bool]$Condition, [string]$Message) {
  $script:assertions++
  if (-not $Condition) { throw $Message }
}
function Import-WidgetFunction([string]$Name) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw 'Application parse failed.' }
  $definitions = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }.GetNewClosure(), $true))
  if ($definitions.Count -ne 1) { throw "Expected exactly one production function: $Name" }
  $body = $definitions[0].Body.Extent.Text.Trim()
  Set-Item -Path ("Function:script:{0}" -f $Name) -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}
function Get-LogicalNodes($Root) {
  if ($null -eq $Root -or $Root -isnot [System.Windows.DependencyObject]) { return }
  Write-Output -NoEnumerate $Root
  foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) {
    Get-LogicalNodes $child
  }
}
function Invoke-Button($Button) {
  $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
}
. $experiencePath
$experienceSource=[IO.File]::ReadAllText($experiencePath,[Text.UTF8Encoding]::new($false,$true))
$appSource=[IO.File]::ReadAllText($appPath,[Text.UTF8Encoding]::new($false,$true))
Assert-That (([regex]::Matches($experienceSource,'(?m)^function Show-WidgetSettings\s*\{')).Count -eq 1) 'Settings must have exactly one implementation.'
Assert-That (-not $appSource.Contains('function Show-AppearanceDialogLegacy')) 'The obsolete appearance window remains in production.'
Assert-That ($appSource -match "Show-WidgetSettings\s+-InitialPage\s+'?Appearance'?") 'Appearance entry point is not routed to unified settings.'
foreach ($name in @('Convert-ToBrush','New-TextBlock','New-ButtonTemplate','Set-DialogComboBoxStyle')) {
  Import-WidgetFunction $name
}
$tabs=[System.Windows.Controls.TabControl]::new()
Set-WidgetSettingsTabStyle $tabs
$tab=[System.Windows.Controls.TabItem]::new(); $tab.Header='Appearance & media'
$tabs.Items.Add($tab) | Out-Null
$tabs.Measure([System.Windows.Size]::new(426,500)); $tabs.Arrange([System.Windows.Rect]::new(0,0,426,500)); $tabs.UpdateLayout()
$tab.ApplyTemplate() | Out-Null
$surface=$tab.Template.FindName('TabSurface',$tab)
Assert-That ($null -ne $surface) 'Settings tabs still rely on the native light template.'
Assert-That ($surface.Background.ToString() -eq '#FF245B97') 'Selected tab background is not the owned dark palette.'
Assert-That ($tab.Foreground.ToString() -eq '#FFF6F9FF') 'Selected tab text contrast regressed.'

# The assertions below construct the actual production editor without running
# application bootstrap, external media, services, or writing the user's state.
$script:state = [pscustomobject]@{window=[pscustomobject]@{
  language='ko-KR'
  appearance=[pscustomobject]@{
    theme='Monochrome'; accentColor='#FFAFC7FF'; panelColor='#F016181D'
    cardColor='#EA23262D'; cardHoverColor='#F2383D47'; textColor='#FFF7F8FA'
    backgroundMedia=''; backgroundMediaKind='auto'; backgroundMediaOpacity=0.7
    backgroundVideoMuted=$true
  }
}}
$script:applyCalls=0; $script:saveCalls=0; $script:saveSucceeds=$true
function Apply-Appearance { $script:applyCalls++ }
function Save-State { $script:saveCalls++; return $script:saveSucceeds }
function Write-RuntimeLog { param([string]$Message) }
function Resolve-MediaKind { param($Source,$ConfiguredKind) return 'image' }
function Test-MediaSource { param($Source,$ConfiguredKind) return ($Source -eq '' -or $Source -eq 'fixture.png') }
$dialog=[System.Windows.Window]::new()
try {
  $editor=New-WidgetAppearanceSettingsPanel -Dialog $dialog
  $dialog.Content=$editor
  $controls=$editor.Tag
  foreach($name in @('theme','accent','panel','card','cardHover','text','media','opacity','mute','apply','cancel','error')) {
    Assert-That ($null -ne $controls[$name]) "Missing production control: $name"
  }
  foreach($button in @(Get-LogicalNodes $editor | Where-Object {$_ -is [System.Windows.Controls.Button]})) {
    Assert-That ($null -ne $button.Template) 'An appearance action relies on the system button template.'
    Assert-That ($button.Foreground.ToString() -in @('#FFF6F9FF','#FFFFFFFF')) 'An appearance action has unreadable text color.'
    Assert-That ($null -ne $button.Background -and $button.Background.ToString() -notin @('#FFFFFFFF','#00FFFFFF')) 'An appearance action has a light or transparent unowned background.'
  }
  $before=ConvertTo-Json $script:state.window.appearance -Compress
  Assert-That ($script:saveCalls -eq 0 -and $script:applyCalls -eq 0) 'Constructing the editor must not change persisted appearance.'
  Assert-That ([string]$controls.theme.SelectedItem.Tag -eq 'Monochrome') 'Saved theme ID must survive construction.'
  $themeIds=@($controls.theme.Items | ForEach-Object {[string]$_.Tag}) -join '|'
  Assert-That ($themeIds -eq 'Midnight|Neon|Sakura|Monochrome|Custom') 'Preset IDs changed.'
  foreach($locale in @('ko-KR','en-US','ko-KR')) {
    $script:state.window.language=$locale
    Set-WidgetLocalizedTree $editor
    Assert-That ((@($controls.theme.Items | ForEach-Object {[string]$_.Tag}) -join '|') -ceq $themeIds) 'Localization changed stored theme IDs.'
    Assert-That ($controls.apply.Content -ceq (Get-WidgetText 'Apply')) 'Apply button did not follow locale.'
    Assert-That ($controls.mute.Content -ceq (Get-WidgetText 'Mute background video')) 'Mute control did not follow locale.'
    foreach($node in @(Get-LogicalNodes $editor)) {
      foreach($property in @('Text','Content','Header','ToolTip')) {
        if($node -is [System.Windows.Controls.TextBox] -and $property -ne 'ToolTip'){continue}
        $value=$node.PSObject.Properties[$property]
        if($null -eq $value -or $value.Value -isnot [string]){continue}
        $text=[string]$value.Value
        if($locale -eq 'ko-KR' -and $script:widgetWords.ContainsKey($text) -and $script:widgetWords[$text] -cne $text){
          throw "Unlocalized production editor text: $text"
        }
      }
    }
    Assert-That ($controls.accent.Text -ceq '#FFAFC7FF') 'Locale switch changed a color input.'
  }
  $controls.accent.Text='not-a-color'
  Invoke-Button $controls.apply
  Assert-That ((ConvertTo-Json $script:state.window.appearance -Compress) -ceq $before) 'Invalid color changed appearance state.'
  Assert-That ($script:applyCalls -eq 0 -and $script:saveCalls -eq 0) 'Invalid color applied or saved.'
  Assert-That (-not [string]::IsNullOrWhiteSpace([string]$controls.error.Text)) 'Invalid color has no inline feedback.'
  Invoke-Button $controls.cancel
  Assert-That ($controls.accent.Text -ceq '#FFAFC7FF') 'Cancel did not restore the saved color draft.'
  $controls.media.Text='untrusted.invalid'
  Invoke-Button $controls.apply
  Assert-That ((ConvertTo-Json $script:state.window.appearance -Compress) -ceq $before) 'Invalid media changed appearance state.'
  Assert-That ($script:applyCalls -eq 0 -and $script:saveCalls -eq 0) 'Invalid media applied or saved.'
  Invoke-Button $controls.cancel
  $controls.accent.Text='#FF112233'; $controls.media.Text='fixture.png'; $controls.opacity.Value=0.4
  Invoke-Button $controls.apply
  Assert-That ($script:state.window.appearance.theme -eq 'Custom') 'Edited preset colors did not become Custom.'
  Assert-That ($controls.theme.SelectedItem.Tag -eq 'Custom') 'Applied custom colors still display the old preset name.'
  Assert-That ($script:state.window.appearance.accentColor -ceq '#FF112233') 'Valid edited color was not applied.'
  Assert-That ($script:state.window.appearance.backgroundMedia -ceq 'fixture.png') 'Valid media was not applied.'
  Assert-That ([math]::Abs($script:state.window.appearance.backgroundMediaOpacity - 0.4) -lt 0.001) 'Media opacity was not applied.'
  Assert-That ($script:applyCalls -eq 1 -and $script:saveCalls -eq 1) 'Valid Apply must apply and save exactly once.'
  $controls.media.Text='unsaved-draft.png'
  $reopened=New-WidgetAppearanceSettingsPanel -Dialog $dialog
  Assert-That ($reopened.Tag.media.Text -ceq 'fixture.png') 'Reopening leaked an unapplied media draft.'
  Assert-That ($script:saveCalls -eq 1) 'Reopening unexpectedly saved state.'
  $applied=ConvertTo-Json $script:state.window.appearance -Compress
  $script:saveSucceeds=$false
  $controls.media.Text=''; Invoke-Button $controls.apply
  Assert-That ((ConvertTo-Json $script:state.window.appearance -Compress) -ceq $applied) 'A failed save left an unsaved appearance active.'
  Assert-That (-not [string]::IsNullOrWhiteSpace([string]$controls.error.Text)) 'Failed persistence has no inline feedback.'
  $script:saveSucceeds=$true
  foreach($width in @(426,506)) {
    $editor.Measure([System.Windows.Size]::new($width,[double]::PositiveInfinity))
    $editor.Arrange([System.Windows.Rect]::new(0,0,$width,$editor.DesiredSize.Height))
    $editor.UpdateLayout()
    Assert-That ($editor.DesiredSize.Width -le ($width + 1)) 'Editor overflows the supported settings width.'
  }
  [pscustomobject]@{success=$true;assertions=$script:assertions;scope='Production WPF editor controls, locale round trips, draft validation, apply/cancel, layout measure; no user state or external media was touched'} | ConvertTo-Json
} finally { $dialog.Content=$null; $dialog.Close() }
