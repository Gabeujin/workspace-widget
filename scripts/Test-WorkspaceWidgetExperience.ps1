[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$manifestPath = Join-Path $ProjectRoot 'assets\semantic-icons\manifest.json'
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($path in @($appPath, $experiencePath, $manifestPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $failures.Add("Required file is missing: $path")
  }
}

if ($failures.Count -eq 0) {
  # WorkspaceWidget.ps1 deliberately invokes Windows PowerShell for its probes.
  # Parse through that same host so an UTF-8-no-BOM helper cannot pass only in pwsh.
  $parseCommand = @"
`$tokens = `$null
`$errors = `$null
[System.Management.Automation.Language.Parser]::ParseFile('$($experiencePath.Replace("'", "''"))', [ref]`$tokens, [ref]`$errors) | Out-Null
`$errors | ForEach-Object { "`$(`$_.Extent.StartLineNumber):`$(`$_.Extent.StartColumnNumber): `$(`$_.Message)" }
if (`$errors.Count -gt 0) { exit 1 }
"@
  $parseEncodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($parseCommand)
  )
  $parseOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $parseEncodedCommand 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $failures.Add("WidgetExperience.ps1 does not parse in Windows PowerShell: $($parseOutput -join ' ')")
  }

  $source = [System.IO.File]::ReadAllText($experiencePath, [System.Text.UTF8Encoding]::new($false))
  $appContent = [System.IO.File]::ReadAllText($appPath, [System.Text.UTF8Encoding]::new($false))
  foreach ($functionName in @(
      'Initialize-ExperienceState', 'Show-WidgetSettings',
      'Start-WidgetBoundsTransition', 'Add-WidgetFilePicker',
      'Update-WidgetLanguage', 'Test-WidgetInteractiveOrigin',
      'Test-WidgetMotionEnabled'
    )) {
    if ($source -notmatch "(?m)^function\s+$functionName\b") {
      $failures.Add("Missing experience helper: $functionName")
    }
  }

  $experienceForCommand = $experiencePath.Replace("'", "''")
  $experienceCommand = @"
Add-Type -AssemblyName PresentationFramework
. '$experienceForCommand'
`$script:state = [pscustomobject]@{
  window = [pscustomobject]@{ language = 'ko-KR'; reduceMotion = `$false; edgeSnap = `$true }
}
`$button = [System.Windows.Controls.Button]::new()
`$button.Content = Get-WidgetText 'Settings'
Set-WidgetLocalizedTree `$button
`$korean = [string]`$button.Content
`$script:state.window.language = 'en-US'
Set-WidgetLocalizedTree `$button
`$english = [string]`$button.Content
`$script:state.window.language = 'ko-KR'
Set-WidgetLocalizedTree `$button
`$roundTrip = [string]`$button.Content
if (`$korean -ne (Get-WidgetText 'Settings') -or `$english -ne 'Settings' -or `$roundTrip -ne `$korean) {
  throw 'Locale round trip failed.'
}
`$interactive = [System.Windows.Controls.Button]::new()
if (-not (Test-WidgetInteractiveOrigin `$interactive)) {
  throw 'Interactive ButtonBase origin was not detected.'
}
`$script:state.window.reduceMotion = `$true
if (Test-WidgetMotionEnabled) { throw 'Reduce motion did not disable Widget motion.' }
[pscustomobject]@{ success = `$true; korean = `$korean; english = `$english; roundTrip = `$roundTrip } | ConvertTo-Json -Compress
"@
  $experienceEncodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($experienceCommand)
  )
  $experienceOutput = @(& powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand $experienceEncodedCommand 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $failures.Add("Widget experience helper behavior failed: $($experienceOutput -join ' ')")
  } else {
    try {
      $experienceResult = ($experienceOutput -join [Environment]::NewLine) | ConvertFrom-Json
      if (-not $experienceResult.success -or
          [string]$experienceResult.english -ne 'Settings' -or
          [string]$experienceResult.korean -ne [string]$experienceResult.roundTrip) {
        $failures.Add('Widget locale ko-en-ko result was incomplete.')
      }
    } catch {
      $failures.Add("Widget experience helper did not return valid JSON: $($experienceOutput -join ' ')")
    }
  }

  $dragInteractionSafe = (
    $source -match 'function\s+Test-WidgetInteractiveOrigin' -and
    $source -match 'ButtonBase' -and
    $source -match 'VisualTreeHelper\]::GetParent' -and
    $source -match 'FrameworkContentElement' -and
    $appContent -match 'Test-WidgetInteractiveOrigin\s+\$eventArgs\.OriginalSource'
  )
  if (-not $dragInteractionSafe) {
    $failures.Add('Header dragging does not prove that nested interactive controls are excluded.')
  }

  $wheelStart = $appContent.IndexOf('$script:window.Add_PreviewMouseWheel({')
  $wheelScope = if ($wheelStart -ge 0) { $appContent.Substring($wheelStart, [math]::Min(1800, $appContent.Length - $wheelStart)) } else { '' }
  $loadedStart = $appContent.IndexOf('$script:window.Add_Loaded({')
  $loadedScope = if ($loadedStart -ge 0) { $appContent.Substring($loadedStart, [math]::Min(1800, $appContent.Length - $loadedStart)) } else { '' }
  if ($wheelScope -notmatch 'Test-WidgetMotionEnabled' -or $loadedScope -notmatch 'Test-WidgetMotionEnabled') {
    $failures.Add('Reduce motion does not gate both Widget smooth scroll and startup fade.')
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
  foreach ($icon in @($manifest.icons)) {
    foreach ($asset in @([string]$icon.svg, [string]$icon.png)) {
      if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $manifestPath) $asset) -PathType Leaf)) {
        $failures.Add("Semantic icon '$($icon.id)' declares a missing asset: $asset")
      }
    }
  }
}

[pscustomobject]@{
  success = $failures.Count -eq 0
  failures = @($failures)
} | ConvertTo-Json -Depth 4

if ($failures.Count -gt 0) { exit 1 }
