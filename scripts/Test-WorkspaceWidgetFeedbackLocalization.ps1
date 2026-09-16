#requires -PSEdition Desktop
[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$workspacePath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
foreach ($path in @($experiencePath, $workspacePath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required localization source was not found: $path"
  }
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework

function Assert-That {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Import-ProductionFunction {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile(
    $Path, [ref]$tokens, [ref]$errors
  )
  if ($errors.Count -ne 0) {
    throw "Production source could not be parsed before importing $Name."
  }
  $definition = @(
    $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $Name
      }, $true)
  ) | Select-Object -First 1
  if ($null -eq $definition) {
    throw "Production function was unavailable: $Name"
  }
  $body = $definition.Body.Extent.Text.Trim()
  if (-not ($body.StartsWith('{') -and $body.EndsWith('}'))) {
    throw "Production function body had an unexpected shape: $Name"
  }
  Set-Item -Path ("Function:script:{0}" -f $Name) -Value (
    [scriptblock]::Create($body.Substring(1, $body.Length - 2))
  )
}

function Set-TestLanguage {
  param([ValidateSet('ko-KR', 'en-US')][string]$Language)
  $script:state.window.language = $Language
}

function Invoke-RecoveryCase {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)]$Ownership,
    $Health = $null
  )
  $menu = [System.Windows.Controls.MenuItem]::new()
  $menu.Tag = [pscustomobject]@{ id = $Id; name = 'Fixture service' }
  if ($null -ne $Health) {
    $script:healthStates[$Id] = [bool]$Health
  } else {
    $script:healthStates.Remove($Id) | Out-Null
  }
  $null = Set-ServerRecoveryMenuState -MenuItem $menu -Ownership $Ownership
  Write-Output -NoEnumerate $menu
}

# WidgetExperience supplies the actual locale lookup and reverse-localization
# behavior. Only the specific production recovery-menu function is extracted;
# the application bootstrap, storage, native host, and network are not loaded.
$script:state = [pscustomobject]@{
  window = [pscustomobject]@{ language = 'en-US' }
}
$script:healthStates = @{}
. $experiencePath
Import-ProductionFunction -Path $workspacePath -Name 'Set-ServerRecoveryMenuState'

$checks = [ordered]@{}
function Add-Check {
  param([string]$Name, [bool]$Value)
  $checks[$Name] = $Value
  Assert-That $Value "Feedback localization regression: $Name"
}

$cases = @(
  [pscustomobject]@{
    name = 'stoppable'; ownership = [pscustomobject]@{ state = 'Owned'; stoppable = $true }; health = $true
    header = 'Stop server...'
    toolTip = 'Ownership is verified against the saved launch and live supervisor, not the application code. Stop requests cleanup; a verified force-stop needs confirmation after timeout.'
  },
  [pscustomobject]@{
    name = 'running-unowned'; ownership = [pscustomobject]@{ state = 'RunningUnowned'; stoppable = $false }; health = $true
    header = 'Server ownership not verified'
    toolTip = 'This server was started outside the current verified launch contract. Use its own controls to stop it.'
  },
  [pscustomobject]@{
    name = 'healthy'; ownership = [pscustomobject]@{ state = 'Stopped'; stoppable = $false }; health = $true
    header = 'Server is online'
    toolTip = 'The configured health endpoint is responding.'
  },
  [pscustomobject]@{
    name = 'offline'; ownership = [pscustomobject]@{ state = 'Stopped'; stoppable = $false }; health = $false
    header = 'Restart server'
    toolTip = 'Runs the trusted Node start target and waits for the health endpoint.'
  },
  [pscustomobject]@{
    name = 'unknown'; ownership = [pscustomobject]@{ state = 'Stopped'; stoppable = $false }; health = $null
    header = 'Check and restart server'
    toolTip = 'Runs the trusted Node start target and waits for the health endpoint.'
  }
)

foreach ($language in @('en-US', 'ko-KR')) {
  Set-TestLanguage $language
  foreach ($case in $cases) {
    $id = "fixture-$language-$($case.name)"
    $menu = Invoke-RecoveryCase -Id $id -Ownership $case.ownership -Health $case.health
    $expectedHeader = Get-WidgetText $case.header
    $expectedToolTip = Get-WidgetText $case.toolTip
    Add-Check "$language-$($case.name)-header" ([string]$menu.Header -ceq $expectedHeader)
    Add-Check "$language-$($case.name)-tooltip" ([string]$menu.ToolTip -ceq $expectedToolTip)
    Add-Check "$language-$($case.name)-enabled" (
      [bool]$menu.IsEnabled -eq ($case.name -notin @('running-unowned', 'healthy'))
    )
  }
}

# A localized menu must round-trip through the production tree localizer when
# the language changes; the checks cover both Header and ToolTip, not just a
# dictionary lookup.
$roundTrip = [System.Windows.Controls.MenuItem]::new()
$roundTrip.Header = Get-WidgetText 'Server ownership not verified'
$roundTrip.ToolTip = Get-WidgetText 'This server was started outside the current verified launch contract. Use its own controls to stop it.'
Set-TestLanguage 'en-US'
Set-WidgetLocalizedTree $roundTrip
Add-Check 'localized-menu-header-roundtrip-to-english' (
  [string]$roundTrip.Header -ceq 'Server ownership not verified'
)
Add-Check 'localized-menu-tooltip-roundtrip-to-english' (
  [string]$roundTrip.ToolTip -ceq 'This server was started outside the current verified launch contract. Use its own controls to stop it.'
)
Set-TestLanguage 'ko-KR'
Set-WidgetLocalizedTree $roundTrip
Add-Check 'localized-menu-header-roundtrip-to-korean' (
  [string]$roundTrip.Header -ceq (Get-WidgetText 'Server ownership not verified')
)
Add-Check 'localized-menu-tooltip-roundtrip-to-korean' (
  [string]$roundTrip.ToolTip -ceq (Get-WidgetText 'This server was started outside the current verified launch contract. Use its own controls to stop it.')
)

# New runtime-feedback and Windows-startup strings must retain positional
# formatting across the lookup boundary. This deliberately checks the literal
# placeholder before formatting, then checks its one-time substitution.
foreach ($key in @(
    'Stop not confirmed for {0}. Check server status and the runtime log.',
    '{0} is already online',
    'Windows startup check timed out',
    'Starts with Windows at sign-in',
    'Windows startup remains off',
    'Autostart needs installer repair',
    'Could not read Windows startup status',
    'Autostart status is unavailable.',
    'Workspace is still running',
    'Choose Exit Widget in the tray to close the launcher. Servers keep running; stop them from their cards.'
  )) {
  Set-TestLanguage 'ko-KR'
  $korean = Get-WidgetText $key
  Add-Check "korean-key-present-$key" (-not [string]::Equals($korean, $key, [StringComparison]::Ordinal))
  if ($key -match '\{0\}') {
    Add-Check "korean-placeholder-preserved-$key" ($korean.Contains('{0}'))
    Add-Check "korean-placeholder-formats-$key" (-not (($korean -f 'Fixture service').Contains('{0}')))
  }
  Set-TestLanguage 'en-US'
  Add-Check "english-roundtrip-$key" ([string](Get-WidgetText $key) -ceq $key)
}

[pscustomobject]@{
  success = $true
  checks = $checks.Count
  scope = 'Production Get-WidgetText, Set-WidgetLocalizedTree, and AST-imported Set-ServerRecoveryMenuState with in-memory WPF MenuItem fixtures only.'
} | ConvertTo-Json -Compress
