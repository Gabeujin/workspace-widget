#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot)

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
foreach ($path in @($experiencePath, $widgetPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required source was not found: $path" }
}

function Assert-That {
  param([bool]$Condition, [string]$Message)
  $script:assertions++
  if (-not $Condition) { throw $Message }
}

function Invoke-DispatcherFor {
  param([ValidateRange(1, 5000)][int]$Milliseconds)
  $frame = [System.Windows.Threading.DispatcherFrame]::new()
  $timer = [System.Windows.Threading.DispatcherTimer]::new()
  $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
  $timer.Add_Tick({ param($sender, $eventArgs) $sender.Stop(); $frame.Continue = $false })
  $timer.Start()
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-ForTransitionEnd {
  param([System.Windows.Window]$Window)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  do {
    if (($null -eq $script:widgetTransition -or -not $script:widgetTransition.IsEnabled) -and
        -not $Window.HasAnimatedProperties) { return $true }
    Invoke-DispatcherFor 20
  } while ($watch.ElapsedMilliseconds -lt 2500)
  return $false
}

function Assert-EffectiveBoundsMonotonic {
  param(
    [System.Windows.Window]$Window,
    [ValidateSet('Shrink', 'Expand')][string]$Direction
  )
  $widths = [Collections.Generic.List[double]]::new()
  $heights = [Collections.Generic.List[double]]::new()
  $watch = [Diagnostics.Stopwatch]::StartNew()
  do {
    $widths.Add([double]$Window.ActualWidth)
    $heights.Add([double]$Window.ActualHeight)
    if (($null -eq $script:widgetTransition -or -not $script:widgetTransition.IsEnabled) -and
        -not $Window.HasAnimatedProperties) { break }
    Invoke-DispatcherFor 10
  } while ($watch.ElapsedMilliseconds -lt 2500)
  Assert-That ($widths.Count -ge 8 -and $heights.Count -eq $widths.Count) `
    "$Direction transition did not expose enough compositor samples."
  for ($index = 1; $index -lt $widths.Count; $index++) {
    $widthDelta = $widths[$index] - $widths[$index - 1]
    $heightDelta = $heights[$index] - $heights[$index - 1]
    if ($Direction -eq 'Shrink') {
      Assert-That ($widthDelta -le 2.0) "Shrink width bounced upward by $widthDelta pixels."
      Assert-That ($heightDelta -le 2.0) "Shrink height bounced upward by $heightDelta pixels."
    } else {
      Assert-That ($widthDelta -ge -2.0) "Expand width bounced downward by $widthDelta pixels."
      Assert-That ($heightDelta -ge -2.0) "Expand height bounced downward by $heightDelta pixels."
    }
  }
  return [pscustomobject]@{ samples = $widths.Count; finalWidth = $widths[$widths.Count - 1]; finalHeight = $heights[$heights.Count - 1] }
}

function Get-FunctionAst {
  param([string]$Path, [string]$Name)
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if (@($errors).Count) { throw "PowerShell parse failed: $Path" }
  $matches = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true))
  if ($matches.Count -ne 1) { throw "Expected exactly one function '$Name' in $Path" }
  return $matches[0]
}

function Import-FunctionAst {
  param([string]$Path, [string]$Name)
  $definition = Get-FunctionAst -Path $Path -Name $Name
  $body = $definition.Body.Extent.Text.Trim()
  if ($body.StartsWith('{') -and $body.EndsWith('}')) { $body = $body.Substring(1, $body.Length - 2) }
  Set-Item -Path ("Function:script:{0}" -f $Name) -Value ([scriptblock]::Create($body))
}

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$script:assertions = 0

# WidgetExperience has no bootstrap side effects. Load its actual transition
# functions, and import the real opacity setter from the bootstrap-owned file.
. $experiencePath
Import-FunctionAst -Path $widgetPath -Name 'Set-WidgetOpacity'
Import-FunctionAst -Path $widgetPath -Name 'Initialize-WidgetSharedOpacity'

$transitionAst = Get-FunctionAst -Path $experiencePath -Name 'Start-WidgetBoundsTransition'
$parameterNames = @($transitionAst.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($required in @('FromLeft', 'FromTop', 'FromWidth', 'FromHeight', 'TargetLeft', 'TargetTop', 'TargetWidth', 'TargetHeight', 'OnCommitted')) {
  Assert-That ($parameterNames -contains $required) "Bounds transition must expose explicit $required."
}
Assert-That ($transitionAst.Extent.Text -notmatch '\.SetValue\(') `
  'Start-WidgetBoundsTransition must not commit target dependency-property values before its animation clock.'

$minModeAst = Get-FunctionAst -Path $widgetPath -Name 'Set-MinUiMode'
$minModeText = $minModeAst.Extent.Text
Assert-That ($minModeText -match 'Start-WidgetBoundsTransition[\s\S]*-TargetWidth[\s\S]*-OnCommitted') `
  'Set-MinUiMode must supply explicit target bounds and a deferred completion callback.'
Assert-That ($minModeText -notmatch '\$script:baseOpacity\s*=') `
  'Set-MinUiMode must retain the shared opacity profile instead of swapping base opacity by mode.'
$widgetSource = Get-Content -LiteralPath $widgetPath -Raw -Encoding utf8
foreach ($migrationClaim in @(
  'function Initialize-WidgetSharedOpacity',
  'sharedOpacityVersion',
  '$script:baseOpacity=Initialize-WidgetSharedOpacity',
  '$script:state.window.minUiOpacity = [double]$script:state.window.opacity'
)) {
  Assert-That ($widgetSource.Contains($migrationClaim)) `
    "Shared-opacity migration/save mirror was not found: $migrationClaim"
}

$legacyMin = [pscustomobject]@{ opacity = 0.57; minUiOpacity = 0.93 }
$resolvedMin = Initialize-WidgetSharedOpacity -WindowState $legacyMin -IsMinUi $true
Assert-That ([math]::Abs($resolvedMin - 0.93) -lt 0.001 -and
  [math]::Abs($legacyMin.opacity - 0.93) -lt 0.001 -and
  [math]::Abs($legacyMin.minUiOpacity - 0.93) -lt 0.001 -and $legacyMin.sharedOpacityVersion -eq 1) `
  'First shared-opacity migration did not preserve the visible MIN profile and mirror aliases.'
$resolvedMinReload = Initialize-WidgetSharedOpacity -WindowState $legacyMin -IsMinUi $false
Assert-That ([math]::Abs($resolvedMinReload - 0.93) -lt 0.001) `
  'Migrated state did not retain its canonical shared opacity on reload.'
$legacyFull = [pscustomobject]@{ opacity = 0.57; minUiOpacity = 0.93 }
$resolvedFull = Initialize-WidgetSharedOpacity -WindowState $legacyFull -IsMinUi $false
Assert-That ([math]::Abs($resolvedFull - 0.57) -lt 0.001 -and
  [math]::Abs($legacyFull.opacity - 0.57) -lt 0.001 -and [math]::Abs($legacyFull.minUiOpacity - 0.57) -lt 0.001) `
  'First shared-opacity migration did not preserve the visible FULL profile and mirror aliases.'

$script:state = [pscustomobject]@{ window = [pscustomobject]@{ reduceMotion = $false } }
$script:minUiWidth = 96.0
$script:minUiMode = $false
$script:widgetTransition = $null
$script:widgetTransitionTarget = $null
$script:lastAppliedOpacity = -1.0
function Test-WidgetMotionEnabled { return -not [bool]$script:state.window.reduceMotion }
function Write-RuntimeLog { param([string]$Message) }

$window = [System.Windows.Window]::new()
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.MinWidth = 96
$window.MinHeight = 320
$window.Opacity = 1.0
$window.Left = -10000
$window.Top = -10000
$window.Width = 520
$window.Height = 580
$script:window = $window

try {
  $window.Show(); Invoke-DispatcherFor 30

  # The real opacity setter is mode-agnostic: its only profile is the supplied
  # value, clamped to the supported window range.
  Set-WidgetOpacity -Value 0.57
  Assert-That ([math]::Abs($window.Opacity - 0.57) -lt 0.001) 'Shared opacity was not applied to the visible WPF window.'
  Set-WidgetOpacity -Value 2.0
  Assert-That ([math]::Abs($window.Opacity - 1.0) -lt 0.001) 'Opacity upper clamp changed.'
  Set-WidgetOpacity -Value 0.01
  Assert-That ([math]::Abs($window.Opacity - 0.35) -lt 0.001) 'Opacity lower clamp changed.'

  $window.Opacity = 0.57
  $commits = [Collections.Generic.List[bool]]::new()
  $script:stagedVisualCommitted = $false
  Start-WidgetBoundsTransition -FromLeft $window.Left -FromTop $window.Top -FromWidth $window.ActualWidth -FromHeight $window.ActualHeight `
    -TargetLeft 64 -TargetTop 40 -TargetWidth 96 -TargetHeight 360 `
    -OnCommitted { param([bool]$Settled) $commits.Add($Settled); $script:stagedVisualCommitted = $true } | Out-Null
  Assert-That ($commits.Count -eq 0 -and -not $script:stagedVisualCommitted) `
    'MIN-only visual state committed before the bounds transition settled.'
  $effectiveWidth = [double]$window.ActualWidth
  Assert-That ($effectiveWidth -ge 96.0 -and $effectiveWidth -le 520.0) `
    'The first transition frame jumped outside its explicit source/target width bounds.'
  Assert-That ([math]::Abs([double]$script:widgetTransitionTarget.Width - 96.0) -lt 0.001) `
    'The active transition did not retain the explicit narrow target.'
  Assert-That ([math]::Abs($window.Opacity - 0.57) -lt 0.001) `
    'Bounds transition changed the shared opacity profile.'
  $shrinkSample = Assert-EffectiveBoundsMonotonic -Window $window -Direction Shrink
  Invoke-DispatcherFor 50
  Assert-That ($window.ActualWidth -le 98.0 -and $window.ActualHeight -le 362.0) `
    'Shrink transition did not settle at its narrow target.'
  Assert-That ($commits.Count -eq 1 -and $commits[0] -and $script:stagedVisualCommitted) `
    'Settled transition did not commit staged visual state exactly once.'
  Assert-That (-not $window.HasAnimatedProperties) 'Settled transition retained WPF clocks.'

  $expandCommits = [Collections.Generic.List[bool]]::new()
  Start-WidgetBoundsTransition -FromLeft $window.Left -FromTop $window.Top -FromWidth $window.ActualWidth -FromHeight $window.ActualHeight `
    -TargetLeft 300 -TargetTop 180 -TargetWidth 520 -TargetHeight 580 `
    -OnCommitted { param([bool]$Settled) $expandCommits.Add($Settled) } | Out-Null
  $expandSample = Assert-EffectiveBoundsMonotonic -Window $window -Direction Expand
  Invoke-DispatcherFor 50
  Assert-That ($window.ActualWidth -ge 518.0 -and $window.ActualHeight -ge 578.0) `
    'Expand transition did not settle at its full target.'
  Assert-That ($expandCommits.Count -eq 1 -and $expandCommits[0] -and -not $window.HasAnimatedProperties) `
    'Expand transition did not commit once and release its clocks.'

  $cancelCommits = [Collections.Generic.List[bool]]::new()
  Start-WidgetBoundsTransition -FromLeft $window.Left -FromTop $window.Top -FromWidth $window.ActualWidth -FromHeight $window.ActualHeight `
    -TargetLeft 64 -TargetTop 40 -TargetWidth 96 -TargetHeight 360 `
    -OnCommitted { param([bool]$Settled) $cancelCommits.Add($Settled) } | Out-Null
  Invoke-DispatcherFor 35
  Cancel-WidgetBoundsTransition -Reason 'isolated regression cancellation' | Out-Null
  Invoke-DispatcherFor 30
  Assert-That ($cancelCommits.Count -eq 1 -and -not $cancelCommits[0]) 'Cancellation did not invoke its deferred callback once with Settled=false.'
  Assert-That (-not $window.HasAnimatedProperties) 'Cancellation retained bounds animation clocks.'
  Assert-That ([math]::Abs($window.Opacity - 0.57) -lt 0.001) 'Cancellation changed the shared opacity profile.'

  $script:state.window.reduceMotion = $true
  $reducedMotionCommits = [Collections.Generic.List[bool]]::new()
  Start-WidgetBoundsTransition -FromLeft $window.Left -FromTop $window.Top -FromWidth $window.ActualWidth -FromHeight $window.ActualHeight `
    -TargetLeft 64 -TargetTop 40 -TargetWidth 96 -TargetHeight 360 `
    -OnCommitted { param([bool]$Settled) $reducedMotionCommits.Add($Settled) } | Out-Null
  Assert-That ($reducedMotionCommits.Count -eq 1 -and -not $reducedMotionCommits[0] -and -not $window.HasAnimatedProperties) `
    'Reduced-motion transition must commit through the deferred callback without a clock.'
  Assert-That ([math]::Abs($window.Opacity - 0.57) -lt 0.001) 'Reduced-motion commit changed the shared opacity profile.'
} finally {
  if ($null -ne $script:widgetTransition) { $script:widgetTransition.Stop() }
  if ($window.IsVisible) { $window.Close() }
}

[pscustomobject]@{
  success = $true
  assertions = $script:assertions
  exercised = @('shared-opacity', 'staged-visual-commit', 'explicit-bounds', 'cancellation', 'reduced-motion')
  limitations = @('No video-frame rate or compositor smoothness claim', 'No cross-monitor physical-display claim')
} | ConvertTo-Json -Compress
