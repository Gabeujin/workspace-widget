[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'WorkspaceServiceWidget\state.json'),
  [switch]$NoDesktopAttach
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$StatePath = [System.IO.Path]::GetFullPath(
  [Environment]::ExpandEnvironmentVariables($StatePath)
)

function Get-WorkspaceWidgetInstanceNames {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $normalizedPath = [System.IO.Path]::GetFullPath($Path).Trim().ToLowerInvariant()
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString(
      $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
    ).Replace('-', '').ToLowerInvariant().Substring(0, 24)
  } finally {
    $hasher.Dispose()
  }
  $prefix = "Local\WorkspaceServiceWidget-$hash"
  return [pscustomobject][ordered]@{
    ready = "$prefix-Ready-v2"
    show = "$prefix-Show-v3"
    presented = "$prefix-Presented-v2"
  }
}

$instanceNames = Get-WorkspaceWidgetInstanceNames -Path $StatePath

$appScript = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
if (-not (Test-Path -LiteralPath $appScript -PathType Leaf)) {
  throw "Workspace widget application not found at '$appScript'."
}
$appScript = [System.IO.Path]::GetFullPath($appScript)
$appFilePattern = '(?i)-File\s+(?:"{0}"|{0})(?:\s|$)' -f [regex]::Escape($appScript)
$nativeHost = @(
  $env:WORKSPACE_WIDGET_HOST_PATH,
  (Join-Path $ProjectRoot 'WorkspaceWidget.exe')
) |
  Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
    (Test-Path -LiteralPath $_ -PathType Leaf)
  } |
  Select-Object -First 1
if (-not [string]::IsNullOrWhiteSpace($nativeHost)) {
  $nativeHost = [System.IO.Path]::GetFullPath($nativeHost)
}

function Get-WorkspaceWidgetProcess {
  $nativeProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='WorkspaceWidget.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        [string]$_.CommandLine -notmatch '(?i)\s--service-supervisor\s' -and
        -not [string]::IsNullOrWhiteSpace($nativeHost) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        [string]::Equals(
          [System.IO.Path]::GetFullPath([string]$_.ExecutablePath),
          $nativeHost,
          [System.StringComparison]::OrdinalIgnoreCase
        )
      }
  )
  $legacyProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
        $_.CommandLine -match $appFilePattern -and
        $_.CommandLine -notmatch '\s-Probe(?:\s|$)' -and
        $_.CommandLine -notmatch '\s-CapturePath(?:\s|$)'
      }
  )
  return @($nativeProcesses) + @($legacyProcesses)
}

function Request-ExistingWorkspaceWidget {
  $existingReadyEvent = $null
  $existingShowEvent = $null
  $existingPresentedEvent = $null
  try {
    $existingReadyEvent = [System.Threading.EventWaitHandle]::OpenExisting(
      $instanceNames.ready
    )
    if (-not $existingReadyEvent.WaitOne([TimeSpan]::FromSeconds(3))) {
      return $null
    }
    $existingShowEvent = [System.Threading.EventWaitHandle]::OpenExisting(
      $instanceNames.show
    )
    $existingPresentedEvent = [System.Threading.EventWaitHandle]::OpenExisting(
      $instanceNames.presented
    )
    $existingPresentedEvent.Reset() | Out-Null
    $existingShowEvent.Set() | Out-Null
    if (-not $existingPresentedEvent.WaitOne([TimeSpan]::FromSeconds(5))) {
      throw 'The running Workspace Widget did not confirm that its window was presented.'
    }
    $running = @(Get-WorkspaceWidgetProcess)
    return [pscustomobject]@{
      started = $false
      alreadyRunning = $true
      restored = $true
      uiReady = $true
      processId = if ($running.Count -gt 0) { [int]$running[0].ProcessId } else { 0 }
      statePath = $StatePath
      runtime = if (@($running | Where-Object { $_.Name -ieq 'WorkspaceWidget.exe' }).Count -gt 0) {
        'WorkspaceWidget.exe'
      } else {
        'Legacy Windows PowerShell'
      }
    }
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    return $null
  } finally {
    if ($null -ne $existingPresentedEvent) {
      $existingPresentedEvent.Dispose()
    }
    if ($null -ne $existingShowEvent) {
      $existingShowEvent.Dispose()
    }
    if ($null -ne $existingReadyEvent) {
      $existingReadyEvent.Dispose()
    }
  }
}

$existingResult = Request-ExistingWorkspaceWidget
if ($null -ne $existingResult) {
  $existingResult | ConvertTo-Json
  exit 0
}

$readyCreated = $false
$readyEvent = [System.Threading.EventWaitHandle]::new(
  $false,
  [System.Threading.EventResetMode]::ManualReset,
  $instanceNames.ready,
  [ref]$readyCreated
)
$readyEvent.Reset() | Out-Null

try {
  if (-not [string]::IsNullOrWhiteSpace($nativeHost)) {
    $arguments = @(
      '--state-path', "`"$StatePath`""
    )
    if ($NoDesktopAttach) {
      $arguments += '--no-desktop-attach'
    }
    $childProcess = Start-Process `
      -FilePath $nativeHost `
      -ArgumentList ($arguments -join ' ') `
      -WorkingDirectory (Split-Path -Parent $nativeHost) `
      -PassThru
    $runtime = 'WorkspaceWidget.exe'
  } else {
    $arguments = @(
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-WindowStyle', 'Hidden',
      '-ExecutionPolicy', 'Bypass',
      '-File', "`"$appScript`"",
      '-ProjectRoot', "`"$ProjectRoot`"",
      '-StatePath', "`"$StatePath`""
    )
    if ($NoDesktopAttach) {
      $arguments += '-NoDesktopAttach'
    }
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childProcess = Start-Process `
      -FilePath $windowsPowerShell `
      -ArgumentList ($arguments -join ' ') `
      -WorkingDirectory $ProjectRoot `
      -WindowStyle Hidden `
      -PassThru
    $runtime = 'Legacy Windows PowerShell'
  }

  $deadline = (Get-Date).AddSeconds(15)
  $uiReady = $false
  do {
    if ($readyEvent.WaitOne(350)) {
      $uiReady = $true
      break
    }
    $childProcess.Refresh()
    if ($childProcess.HasExited) {
      break
    }
  } while ((Get-Date) -lt $deadline)

  $running = @(Get-WorkspaceWidgetProcess)
  if (-not $uiReady -or ($running.Count -eq 0 -and $childProcess.HasExited)) {
    $runtimeLog = Join-Path (Split-Path -Parent $StatePath) 'runtime.log'
    $logTail = if (Test-Path -LiteralPath $runtimeLog) {
      (Get-Content -LiteralPath $runtimeLog -Tail 10) -join [Environment]::NewLine
    } else {
      'No runtime log was created.'
    }
    throw "Workspace widget UI did not become ready within 15 seconds.`n$logTail"
  }

  [pscustomobject]@{
    started = $true
    alreadyRunning = $false
    uiReady = $uiReady
    processId = if ($running.Count -gt 0) {
      [int]$running[0].ProcessId
    } else {
      [int]$childProcess.Id
    }
    statePath = $StatePath
    desktopAttached = -not $NoDesktopAttach
    runtime = $runtime
    executable = if (-not [string]::IsNullOrWhiteSpace($nativeHost)) {
      $nativeHost
    } else {
      $windowsPowerShell
    }
  } | ConvertTo-Json
} finally {
  $readyEvent.Dispose()
}
