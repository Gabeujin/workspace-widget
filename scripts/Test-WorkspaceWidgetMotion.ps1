#requires -PSEdition Desktop
[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
  throw 'Run this WPF-only regression harness with Windows PowerShell -STA.'
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$widgetPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
foreach ($required in @($experiencePath, $widgetPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required motion source was not found: $required"
  }
}

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  $script:assertions++
  if (-not $Condition) { throw $Message }
}

function Invoke-DispatcherFor {
  param([Parameter(Mandatory = $true)][int]$Milliseconds)
  $frame = [System.Windows.Threading.DispatcherFrame]::new()
  $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::SystemIdle)
  $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
  $timer.Add_Tick({
    param($sender, $eventArgs)
    $sender.Stop()
    $frame.Continue = $false
  })
  $timer.Start()
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Get-WindowBaseValues {
  param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)
  return [ordered]@{
    Left = [double]$Window.GetAnimationBaseValue([System.Windows.Window]::LeftProperty)
    Top = [double]$Window.GetAnimationBaseValue([System.Windows.Window]::TopProperty)
    Width = [double]$Window.GetAnimationBaseValue([System.Windows.Window]::WidthProperty)
    Height = [double]$Window.GetAnimationBaseValue([System.Windows.Window]::HeightProperty)
  }
}

function Get-TransitionDiagnostic {
  param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)
  $timer = $script:widgetTransition
  return [ordered]@{
    base = Get-WindowBaseValues $Window
    hasAnimatedProperties = [bool]$Window.HasAnimatedProperties
    saveCalls = $script:saveCalls
    timerEnabled = if ($null -eq $timer) { $false } else { [bool]$timer.IsEnabled }
    target = if ($null -eq $script:widgetTransitionTarget) { $null } else { [ordered]@{
      Left = $script:widgetTransitionTarget.Left
      Top = $script:widgetTransitionTarget.Top
      Width = $script:widgetTransitionTarget.Width
      Height = $script:widgetTransitionTarget.Height
    } }
  }
}

function Wait-ForBoundsTransitionCompletion {
  param(
    [Parameter(Mandatory = $true)][System.Windows.Window]$Window,
    [ValidateRange(250, 5000)][int]$TimeoutMilliseconds = 2000
  )
  $watch = [Diagnostics.Stopwatch]::StartNew()
  do {
    $timer = $script:widgetTransition
    if ($null -eq $script:widgetTransitionTarget -and
        ($null -eq $timer -or -not $timer.IsEnabled) -and
        -not $Window.HasAnimatedProperties) {
      return $true
    }
    Invoke-DispatcherFor 20
  } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
  return $false
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

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Windows.Forms
$script:assertions = 0

# These assertions intentionally cover the integration source that cannot be
# dot-sourced safely: WorkspaceWidget.ps1 contains application bootstrap code.
$widgetSource = Get-Content -LiteralPath $widgetPath -Raw -Encoding utf8
foreach ($claim in @(
  'BeginAnimation\(\$dp,\$null\)',
  '\$script:widgetTransitionTarget=\$null',
  'GetAnimationBaseValue\(\[System\.Windows\.Window\]::LeftProperty\)',
  'GetAnimationBaseValue\(\[System\.Windows\.Window\]::WidthProperty\)',
  'Start-WidgetBoundsTransition -FromLeft',
  'Get-WidgetWorkingArea',
  'modeWorkArea\.right-\$script:window\.Width'
)) {
  Assert-That ($widgetSource -match $claim) "Static motion/restore contract was not found: $claim"
}
$restoreIndex=$widgetSource.IndexOf('$script:window.SetValue($dp,[double]$script:widgetTransitionTarget[$property])')
$clearIndex=$widgetSource.IndexOf('$script:widgetTransitionTarget=$null')
$newTargetIndex=$widgetSource.IndexOf('Start-WidgetBoundsTransition -FromLeft')
Assert-That ($restoreIndex -ge 0 -and $restoreIndex -lt $clearIndex -and $clearIndex -lt $newTargetIndex) `
  'Set-MinUiMode no longer restores and clears an interrupted target before creating the new mode target.'

# WidgetExperience has no bootstrap side effects, so test its real WPF helpers.
. $experiencePath
Import-CurrentWidgetFunction -Path $widgetPath -Name 'Set-MinUiMode'

$script:state = [pscustomobject]@{
  window = [pscustomobject]@{ language = 'en-US'; reduceMotion = $false }
}
$script:minUiWidth = 96.0
$script:minUiMode = $false
$script:widgetTransition = $null
Assert-That ($null -ne (Get-Variable -Name widgetTransitionTarget -Scope Script -ErrorAction SilentlyContinue)) `
  'Production experience helpers must initialize transition target before the first UI click.'
$script:saveCalls = 0
function Save-State { $script:saveCalls++ }

# Preserve the production reduce-motion guard as a source-level contract, then
# force the otherwise real transition helper in this isolated WPF unit fixture.
$experienceSource = Get-Content -LiteralPath $experiencePath -Raw -Encoding utf8
Assert-That ($experienceSource -match 'Test-WidgetMotionEnabled\) -or -not \$script:window\.IsVisible') `
  'Start-WidgetBoundsTransition no longer guards reduce-motion or invisibility.'
function Test-WidgetMotionEnabled { return -not [bool]$script:state.window.reduceMotion }

$window = [System.Windows.Window]::new()
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Opacity = 0
$window.Left = 300
$window.Top = 180
$window.Width = 520
$window.Height = 580
$script:window = $window

try {
  $window.Show()
  Invoke-DispatcherFor 30
  $expected = Get-WindowBaseValues $window

  # Reversing while the first transition is pending must cancel the old timer,
  # retain the base geometry, and leave no animation value after the second ends.
  Start-WidgetBoundsTransition -FromLeft 48 -FromTop 32 -FromWidth 96 -FromHeight 320
  Invoke-DispatcherFor 35
  # A Window can write a rendered/native resize back to the DP base while its
  # animation clock is active. Inject that same base-value mutation explicitly
  # so this remains deterministic across Windows compositor versions.
  $window.Height = 341
  $baseDuringFirstTransition = Get-WindowBaseValues $window
  Assert-That ([math]::Abs($expected.Height - $baseDuringFirstTransition.Height) -gt 0.001) `
    'The active Window Height base value was not mutated for the reversal regression fixture.'
  Start-WidgetBoundsTransition -FromLeft 86 -FromTop 50 -FromWidth 110 -FromHeight 340
  $firstTransitionCompleted = Wait-ForBoundsTransitionCompletion -Window $window
  Invoke-DispatcherFor 100
  $actual = Get-WindowBaseValues $window
  Assert-That $firstTransitionCompleted ('Animation reversal did not reach its completion boundary: ' +
    ((Get-TransitionDiagnostic $window) | ConvertTo-Json -Compress))
  foreach ($property in $expected.Keys) {
    Assert-That ([math]::Abs($expected[$property] - $actual[$property]) -lt 0.001) `
      "Animation reversal changed the persisted base $property value."
  }
  Assert-That (-not $window.HasAnimatedProperties) 'The final bounds animation did not release its WPF animation clocks.'
  Assert-That ($script:saveCalls -eq 1) 'Reversed motion persisted more than the final transition.'
  Assert-That ($null -ne $script:widgetTransition -and -not $script:widgetTransition.IsEnabled) `
    'The final bounds-transition timer remained enabled.'

  # A rapid full -> MIN -> full change must discard the interrupted MIN target
  # and capture the newly restored full bounds for the second transition.
  $window.Width=430
  Invoke-DispatcherFor 20
  $script:state=[pscustomobject]@{window=[pscustomobject]@{
    language='en-US'; reduceMotion=$false; left=300.0; top=180.0; width=430.0; height=580.0; opacity=1.0
    minUiMode=$false; minUiLeft=300.0; minUiTop=180.0; minUiHeight=580.0; minUiOpacity=1.0
  }}
  $script:minUiMode=$false; $script:minUiOpacity=1.0; $script:baseOpacity=1.0
  $script:applyingUiMode=$false; $script:updatingAutostartCheck=$false
  $script:panelBorder=[System.Windows.Controls.Border]::new()
  $script:fullHeaderIdentity=[System.Windows.Controls.Border]::new()
  $script:header=[System.Windows.Controls.Grid]::new()
  $script:toolbar=[System.Windows.Controls.StackPanel]::new()
  $script:opacityPanel=[System.Windows.Controls.Border]::new()
  $script:settingsPanel=[System.Windows.Controls.Border]::new()
  $script:footer=[System.Windows.Controls.Border]::new()
  $script:pageDotsPanel=[System.Windows.Controls.StackPanel]::new()
  $script:resizeHandle=[System.Windows.Controls.Border]::new()
  $script:dropText=[System.Windows.Controls.TextBlock]::new()
  $script:minUiModeButton=[System.Windows.Controls.Button]::new()
  $script:minUiModeCheck=[System.Windows.Controls.CheckBox]::new()
  $script:opacitySlider=[System.Windows.Controls.Slider]::new()
  $script:opacityValue=[System.Windows.Controls.TextBlock]::new()
  function Get-WidgetWorkingArea { [pscustomobject]@{left=0.0;top=0.0;right=1920.0;bottom=1080.0;height=1080.0} }
  function Snap-MinUiToNearestEdge { param([double]$AnchorCenter) }
  function Set-ToolbarCompactMode { param([bool]$Compact) }
  function Update-ResponsiveHeader { }
  function Ensure-WindowVisible { param([string]$Reason,[switch]$Quiet) return $true }
  function Render-Items { }
  function Update-WidgetOpacity { }
  function Write-RuntimeLog { param([string]$Message) }
  $modeExpected=Get-WindowBaseValues $window
  Set-MinUiMode -Enabled $true
  Invoke-DispatcherFor 35
  Assert-That ([math]::Abs($modeExpected.Width-430.0) -lt 0.001 -and
    [math]::Abs($script:widgetTransitionTarget.Width-$script:minUiWidth) -lt 0.001) `
    'The MIN transition did not retain its actual narrow target before interruption.'
  Set-MinUiMode -Enabled $false
  Assert-That ([math]::Abs($script:widgetTransitionTarget.Width-430.0) -lt 0.001 -and
    [math]::Abs($script:widgetTransitionTarget.Width-$modeExpected.Width) -lt 0.001 -and
    [math]::Abs($script:widgetTransitionTarget.Height-$modeExpected.Height) -lt 0.001) `
    'The restored full transition reused the interrupted MIN target.'
  $modeTransitionCompleted = Wait-ForBoundsTransitionCompletion -Window $window
  Invoke-DispatcherFor 100
  $modeActual=Get-WindowBaseValues $window
  Assert-That $modeTransitionCompleted ('Rapid MIN/full transition did not reach its completion boundary: ' +
    ((Get-TransitionDiagnostic $window) | ConvertTo-Json -Compress))
  foreach($property in $modeExpected.Keys){
    Assert-That ([math]::Abs($modeExpected[$property]-$modeActual[$property]) -lt 0.001) `
      "Rapid MIN/full change did not persist the final full $property bounds."
  }
  Assert-That (-not $window.HasAnimatedProperties -and $null -eq $script:widgetTransitionTarget) `
    'Rapid MIN/full change left an animation clock or stale transition target.'

  # A reduce-motion change while a transition is active must cancel the owned
  # timer, restore the captured base once, and never persist an intermediate
  # native Window value.
  $cancelExpected=Get-WindowBaseValues $window
  $saveCallsBeforeCancel=$script:saveCalls
  Start-WidgetBoundsTransition -FromLeft 86 -FromTop 50 -FromWidth 110 -FromHeight 340
  Invoke-DispatcherFor 35
  $script:state.window.reduceMotion=$true
  Start-WidgetBoundsTransition -FromLeft 86 -FromTop 50 -FromWidth 110 -FromHeight 340
  Invoke-DispatcherFor 40
  $cancelActual=Get-WindowBaseValues $window
  foreach($property in $cancelExpected.Keys){
    Assert-That ([math]::Abs($cancelExpected[$property]-$cancelActual[$property]) -lt 0.001) `
      "Reduced-motion cancellation did not restore the $property base value."
  }
  Assert-That ($null -eq $script:widgetTransitionTarget -and
    ($null -eq $script:widgetTransition -or -not $script:widgetTransition.IsEnabled) -and
    -not $window.HasAnimatedProperties) 'Reduced-motion cancellation left a transition resource active.'
  Assert-That ($script:saveCalls -eq $saveCallsBeforeCancel) 'Reduced-motion cancellation persisted an interrupted transition.'
  $script:state.window.reduceMotion=$false

  # Dynamic localization is executed against the actual tree helper, including
  # Content, Text, ToolTip, and AutomationProperties on an already-built tree.
  $root = [System.Windows.Controls.StackPanel]::new()
  $button = [System.Windows.Controls.Button]::new(); $button.Content = 'Settings'; $button.ToolTip = 'Language'
  $text = [System.Windows.Controls.TextBlock]::new(); $text.Text = 'Start'
  [System.Windows.Automation.AutomationProperties]::SetName($button, 'Start')
  $root.Children.Add($button) | Out-Null; $root.Children.Add($text) | Out-Null
  $script:state.window.language = 'ko-KR'
  Set-WidgetLocalizedTree $root
  Assert-That ($button.Content -ceq '설정' -and $button.ToolTip -ceq '언어' -and $text.Text -ceq '시작' -and
    ([System.Windows.Automation.AutomationProperties]::GetName($button) -ceq '시작')) `
    'Dynamic Korean labels did not update every supported existing property.'
  $script:state.window.language = 'en-US'
  Set-WidgetLocalizedTree $root
  Assert-That ($button.Content -ceq 'Settings' -and $button.ToolTip -ceq 'Language' -and $text.Text -ceq 'Start' -and
    ([System.Windows.Automation.AutomationProperties]::GetName($button) -ceq 'Start')) `
    'Dynamic English labels did not restore existing localized properties.'
} finally {
  if ($null -ne $script:widgetTransition) { $script:widgetTransition.Stop() }
  if ($window.IsVisible) { $window.Close() }
}

[pscustomobject]@{
  success = $true
  assertions = $script:assertions
  exercised = @('animation-reversal', 'base-value-persistence', 'mode-target-replacement', 'dynamic-localization')
  nativeHeightBaseDuringAnimation = $baseDuringFirstTransition.Height
  staticOnly = @('Save-State source persistence')
} | ConvertTo-Json -Compress
