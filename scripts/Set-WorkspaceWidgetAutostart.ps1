[CmdletBinding()]
param(
  [ValidateSet('Get', 'Enable', 'Disable', 'Ensure', 'Repair', 'Unregister')]
  [string]$Action = 'Get',
  [string]$ProjectRoot,
  [string]$HostPath,
  [string]$TaskName = 'Workspace Service Widget',
  [string]$TaskPath = '\',
  [ValidateRange(0, 3600)]
  [int]$DelaySeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')

if ([string]::IsNullOrWhiteSpace($TaskPath)) {
  $TaskPath = '\'
}
if (-not $TaskPath.StartsWith('\')) {
  $TaskPath = "\$TaskPath"
}
if (-not $TaskPath.EndsWith('\')) {
  $TaskPath = "$TaskPath\"
}

$productMarker = '[WorkspaceWidget.Autostart.v1]'
$description = "Starts Workspace Widget after Windows sign-in. $productMarker"
$hostExecutable = Join-Path $ProjectRoot 'WorkspaceWidget.exe'
$silentLauncher = Join-Path $ProjectRoot 'scripts\Launch-WorkspaceWidget.vbs'
$legacyExecute = Join-Path $env:SystemRoot 'System32\wscript.exe'
$legacyArguments = "`"$silentLauncher`""
$expectedExecute = if (
  -not [string]::IsNullOrWhiteSpace($HostPath) -and
  (Test-Path -LiteralPath $HostPath -PathType Leaf)
) {
  [System.IO.Path]::GetFullPath($HostPath)
} elseif (Test-Path -LiteralPath $hostExecutable -PathType Leaf) {
  $hostExecutable
} elseif (
  -not [string]::IsNullOrWhiteSpace($env:WORKSPACE_WIDGET_HOST_PATH) -and
  (Test-Path -LiteralPath $env:WORKSPACE_WIDGET_HOST_PATH -PathType Leaf)
) {
  [System.IO.Path]::GetFullPath($env:WORKSPACE_WIDGET_HOST_PATH)
} else {
  $legacyExecute
}
$expectedArguments = if (
  [string]::Equals(
    $expectedExecute,
    $legacyExecute,
    [System.StringComparison]::OrdinalIgnoreCase
  )
) {
  $legacyArguments
} else {
  ''
}
$expectedRuntime = if (
  [string]::Equals(
    $expectedExecute,
    $legacyExecute,
    [System.StringComparison]::OrdinalIgnoreCase
  )
) {
  'LegacyWScript'
} else {
  'NativeHost'
}
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $currentIdentity.User.Value
$currentAccount = $currentIdentity.Name
$expectedDelay = if ($DelaySeconds -gt 0) { "PT$($DelaySeconds)S" } else { $null }

function Test-EqualPath {
  param(
    [AllowNull()][string]$Left,
    [AllowNull()][string]$Right
  )

  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
  }

  try {
    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
    return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return [string]::Equals(
      $Left.Trim().TrimEnd('\'),
      $Right.Trim().TrimEnd('\'),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  }
}

function Resolve-IdentitySid {
  param([AllowNull()][string]$Identity)

  if ([string]::IsNullOrWhiteSpace($Identity)) {
    return $null
  }
  if ($Identity -match '^S-\d-\d+(?:-\d+)+$') {
    return $Identity
  }

  try {
    return (
      [System.Security.Principal.NTAccount]::new($Identity).Translate(
        [System.Security.Principal.SecurityIdentifier]
      )
    ).Value
  } catch {
    return $Identity
  }
}

function Test-LaunchPathPrivate {
  $unsafeIdentities = @(
    'Everyone',
    'NT AUTHORITY\Authenticated Users',
    'BUILTIN\Users'
  )
  $writeMask = (
    [System.Security.AccessControl.FileSystemRights]::Write -bor
    [System.Security.AccessControl.FileSystemRights]::Modify -bor
    [System.Security.AccessControl.FileSystemRights]::FullControl
  )

  try {
    $acl = Get-Acl -LiteralPath $ProjectRoot
    foreach ($rule in $acl.Access) {
      if (
        $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        $unsafeIdentities -contains [string]$rule.IdentityReference -and
        (([int64]$rule.FileSystemRights -band [int64]$writeMask) -ne 0)
      ) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-ExactTask {
  try {
    return Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
  } catch [Microsoft.Management.Infrastructure.CimException] {
    if ($_.Exception.Message -match 'cannot find|찾을 수|No MSFT_ScheduledTask') {
      return $null
    }
    throw
  }
}

function Get-CurrentUserTaskControl {
  try {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folderPath = $TaskPath.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
      $folderPath = '\'
    }
    $registeredTask = $scheduler.GetFolder($folderPath).GetTask($TaskName)
    $securityDescriptor = $registeredTask.GetSecurityDescriptor(15)
    $rawDescriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new(
      $securityDescriptor
    )
    if ($null -eq $rawDescriptor.DiscretionaryAcl) {
      throw 'The task does not expose a discretionary access-control list.'
    }

    $identitySids = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )
    $identitySids.Add($currentSid) | Out-Null
    foreach ($groupSid in $currentIdentity.Groups) {
      $identitySids.Add($groupSid.Value) | Out-Null
    }

    [uint32]$allowedMask = 0
    [uint32]$deniedMask = 0
    foreach ($ace in $rawDescriptor.DiscretionaryAcl) {
      if (
        $ace -isnot [System.Security.AccessControl.QualifiedAce] -or
        $null -eq $ace.SecurityIdentifier -or
        -not $identitySids.Contains($ace.SecurityIdentifier.Value)
      ) {
        continue
      }

      [uint32]$aceMask = $ace.AccessMask
      if ($ace.AceQualifier -eq [System.Security.AccessControl.AceQualifier]::AccessDenied) {
        $deniedMask = [uint32]($deniedMask -bor $aceMask)
      } elseif (
        $ace.AceQualifier -eq [System.Security.AccessControl.AceQualifier]::AccessAllowed
      ) {
        $allowedMask = [uint32]($allowedMask -bor $aceMask)
      }
    }

    [uint32]$fullControlMask = 0x001F01FF
    [uint64]$inverseDeniedMask = (
      [uint64][uint32]::MaxValue -bxor [uint64]$deniedMask
    )
    [uint32]$effectiveMask = [uint32](
      [uint64]$allowedMask -band $inverseDeniedMask
    )
    $canControl = (
      ($effectiveMask -band $fullControlMask) -eq $fullControlMask
    )

    return [pscustomobject]@{
      canControl = $canControl
      effectiveMask = ('0x{0:X8}' -f $effectiveMask)
      error = if ($canControl) {
        $null
      } else {
        'The current user does not have full control of the scheduled task.'
      }
    }
  } catch {
    return [pscustomobject]@{
      canControl = $false
      effectiveMask = $null
      error = $_.Exception.Message
    }
  }
}

function Get-AutostartStatus {
  try {
    $task = Get-ExactTask
  } catch [System.UnauthorizedAccessException] {
    return [pscustomobject]@{
      state = 'PermissionDenied'
      exists = $null
      enabled = $null
      configured = $false
      owned = $false
      legacyOwned = $false
      userCanControl = $false
      drift = @('permission')
      error = $_.Exception.Message
    }
  } catch {
    if ($_.Exception.Message -match 'Access is denied|액세스가 거부') {
      return [pscustomobject]@{
        state = 'PermissionDenied'
        exists = $null
        enabled = $null
        configured = $false
        owned = $false
        legacyOwned = $false
        userCanControl = $false
        drift = @('permission')
        error = $_.Exception.Message
      }
    }
    throw
  }

  if ($null -eq $task) {
    return [pscustomobject]@{
      state = 'Missing'
      exists = $false
      enabled = $false
      configured = $false
      owned = $false
      legacyOwned = $false
      userCanControl = $null
      drift = @()
      error = $null
    }
  }

  $drift = [System.Collections.Generic.List[string]]::new()
  $taskDescription = [string]$task.Description
  $owned = $taskDescription.Contains($productMarker)
  $actionObject = @($task.Actions | Select-Object -First 1)[0]
  $triggerObject = @($task.Triggers | Select-Object -First 1)[0]
  $actionMatches = (
    $task.Actions.Count -eq 1 -and
    (Test-EqualPath -Left ([string]$actionObject.Execute) -Right $expectedExecute) -and
    [string]::Equals(
      ([string]$actionObject.Arguments).Trim(),
      $expectedArguments,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    (Test-EqualPath -Left ([string]$actionObject.WorkingDirectory) -Right $ProjectRoot)
  )
  $legacyActionMatches = (
    $task.Actions.Count -eq 1 -and
    (Test-EqualPath -Left ([string]$actionObject.Execute) -Right $legacyExecute) -and
    [string]::Equals(
      ([string]$actionObject.Arguments).Trim(),
      $legacyArguments,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    (Test-EqualPath -Left ([string]$actionObject.WorkingDirectory) -Right $ProjectRoot)
  )
  $legacyOwned = (
    (
      -not $owned -and
      $actionMatches -and
      $taskDescription -like 'Starts the movable Workspace desktop launcher*'
    ) -or (
      $owned -and
      $legacyActionMatches
    )
  )

  if (-not $owned) {
    $drift.Add('productMarker')
  }
  if ($task.Actions.Count -ne 1) {
    $drift.Add('actionCount')
  } elseif (-not $actionMatches) {
    $drift.Add('action')
  }

  $principalSid = Resolve-IdentitySid -Identity ([string]$task.Principal.UserId)
  if (-not [string]::Equals($principalSid, $currentSid, [System.StringComparison]::OrdinalIgnoreCase)) {
    $drift.Add('principal')
  }
  if ([string]$task.Principal.LogonType -ne 'Interactive') {
    $drift.Add('logonType')
  }
  if ([string]$task.Principal.RunLevel -ne 'Limited') {
    $drift.Add('runLevel')
  }

  $isLogonTrigger = (
    $task.Triggers.Count -eq 1 -and
    $triggerObject.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
  )
  if (-not $isLogonTrigger) {
    $drift.Add('trigger')
  } else {
    $triggerSid = Resolve-IdentitySid -Identity ([string]$triggerObject.UserId)
    if (-not [string]::Equals($triggerSid, $currentSid, [System.StringComparison]::OrdinalIgnoreCase)) {
      $drift.Add('triggerUser')
    }
    $actualDelay = [string]$triggerObject.Delay
    if (-not [string]::Equals($actualDelay, [string]$expectedDelay, [System.StringComparison]::OrdinalIgnoreCase)) {
      $drift.Add('triggerDelay')
    }
    if (-not [bool]$triggerObject.Enabled) {
      $drift.Add('triggerEnabled')
    }
  }

  if (-not [bool]$task.Settings.StartWhenAvailable) {
    $drift.Add('startWhenAvailable')
  }
  if ([bool]$task.Settings.DisallowStartIfOnBatteries) {
    $drift.Add('disallowStartIfOnBatteries')
  }
  if ([bool]$task.Settings.StopIfGoingOnBatteries) {
    $drift.Add('stopIfGoingOnBatteries')
  }
  $expectedExecutionTimeLimit = if ($expectedRuntime -eq 'NativeHost') {
    'PT0S'
  } else {
    'PT2M'
  }
  if ([string]$task.Settings.ExecutionTimeLimit -ne $expectedExecutionTimeLimit) {
    $drift.Add('executionTimeLimit')
  }
  if ([string]$task.Settings.MultipleInstances -ne 'IgnoreNew') {
    $drift.Add('multipleInstances')
  }
  if ([int]$task.Settings.RestartCount -ne 3) {
    $drift.Add('restartCount')
  }
  if ([string]$task.Settings.RestartInterval -ne 'PT1M') {
    $drift.Add('restartInterval')
  }

  $taskControl = Get-CurrentUserTaskControl
  $userCanControl = [bool]$taskControl.canControl
  if (-not $userCanControl) {
    $drift.Add('taskSecurity')
  }

  $configured = $owned -and $drift.Count -eq 0
  $enabled = [bool]$task.Settings.Enabled
  $state = if (-not $userCanControl) {
    'PermissionDenied'
  } elseif (-not $configured) {
    'Drifted'
  } elseif ($enabled) {
    'Enabled'
  } else {
    'Disabled'
  }

  $taskInfo = try {
    Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
  } catch {
    $null
  }

  return [pscustomobject]@{
    state = $state
    exists = $true
    enabled = $enabled
    configured = $configured
    owned = $owned
    legacyOwned = $legacyOwned
    userCanControl = $userCanControl
    controlMask = $taskControl.effectiveMask
    drift = @($drift)
    error = $taskControl.error
    taskPath = $TaskPath
    taskName = $TaskName
    userSid = $currentSid
    execute = [string]$actionObject.Execute
    arguments = [string]$actionObject.Arguments
    workingDirectory = [string]$actionObject.WorkingDirectory
    delay = if ($null -ne $triggerObject) { [string]$triggerObject.Delay } else { $null }
    lastTaskResult = if ($null -ne $taskInfo) { [int]$taskInfo.LastTaskResult } else { $null }
  }
}

function Set-CurrentUserTaskSecurity {
  try {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folderPath = $TaskPath.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
      $folderPath = '\'
    }
    $folder = $scheduler.GetFolder($folderPath)
    $registeredTask = $folder.GetTask($TaskName)
    $securityDescriptor = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;$currentSid)"
    $registeredTask.SetSecurityDescriptor($securityDescriptor, 0)
    $taskControl = Get-CurrentUserTaskControl
    if (-not $taskControl.canControl) {
      throw "Task security verification failed. $($taskControl.error)"
    }
    return $true
  } catch {
    throw "Could not grant the current user control of '$TaskPath$TaskName'. $($_.Exception.Message)"
  }
}

function Register-OwnedTask {
  param([bool]$Enabled)

  if (-not (Test-Path -LiteralPath $expectedExecute -PathType Leaf)) {
    throw "Workspace Widget launch target not found at '$expectedExecute'."
  }

  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentAccount
  if ($DelaySeconds -gt 0) {
    $trigger.Delay = $expectedDelay
  }
  $actionParameters = @{
    Execute = $expectedExecute
    WorkingDirectory = $ProjectRoot
  }
  if (-not [string]::IsNullOrWhiteSpace($expectedArguments)) {
    $actionParameters.Argument = $expectedArguments
  }
  $actionObject = New-ScheduledTaskAction @actionParameters
  $principal = New-ScheduledTaskPrincipal `
    -UserId $currentSid `
    -LogonType Interactive `
    -RunLevel Limited
  $executionTimeLimit = if ($expectedRuntime -eq 'NativeHost') {
    [TimeSpan]::Zero
  } else {
    New-TimeSpan -Minutes 2
  }
  $settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit $executionTimeLimit `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

  Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath $TaskPath `
    -Action $actionObject `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description $description `
    -Force | Out-Null

  $securityApplied = Set-CurrentUserTaskSecurity
  if (-not $Enabled) {
    Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
  }
  return $securityApplied
}

function Set-ExistingTaskEnabled {
  param([bool]$Enabled)

  if ($Enabled) {
    Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
  } else {
    Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Out-Null
  }
}

$before = $null
$securityApplied = $null
$changed = $false
$resultPayload = $null
$exitCode = 0
$operationMutex = $null
$operationMutexAcquired = $false

try {
  $mutexCreated = $false
  $operationMutex = [System.Threading.Mutex]::new(
    $false,
    'Local\WorkspaceWidget-Autostart-v1',
    [ref]$mutexCreated
  )
  try {
    $operationMutexAcquired = $operationMutex.WaitOne(
      [TimeSpan]::FromSeconds(10)
    )
  } catch [System.Threading.AbandonedMutexException] {
    $operationMutexAcquired = $true
  }
  if (-not $operationMutexAcquired) {
    throw 'Another Workspace Widget autostart operation did not finish within 10 seconds.'
  }

  $before = Get-AutostartStatus
  if (
    $expectedRuntime -eq 'NativeHost' -and
    $Action -in @('Ensure', 'Repair', 'Enable') -and
    -not (Test-LaunchPathPrivate)
  ) {
    throw (
      "Autostart was refused because '$ProjectRoot' is writable by a broad " +
      'Windows user group. Install Workspace Widget in a private per-user directory.'
    )
  }
  switch ($Action) {
    'Get' {
      break
    }
    'Ensure' {
      if ($before.state -eq 'PermissionDenied') {
        throw "Cannot inspect the existing scheduled task. $($before.error)"
      }
      if ($before.state -eq 'Missing') {
        $securityApplied = Register-OwnedTask -Enabled $true
        $changed = $true
      } elseif ($before.configured) {
        $securityApplied = Set-CurrentUserTaskSecurity
      } elseif ($before.owned -or $before.legacyOwned) {
        $securityApplied = Register-OwnedTask -Enabled ([bool]$before.enabled)
        $changed = $true
      } else {
        throw "A different scheduled task already uses '$TaskPath$TaskName'. Repair was refused."
      }
    }
    'Repair' {
      if (
        $before.state -ne 'Missing' -and
        -not $before.owned -and
        -not $before.legacyOwned
      ) {
        throw "A different scheduled task already uses '$TaskPath$TaskName'. Repair was refused."
      }
      $desiredEnabled = if ($before.state -eq 'Missing') { $true } else { [bool]$before.enabled }
      $securityApplied = Register-OwnedTask -Enabled $desiredEnabled
      $changed = $true
    }
    'Enable' {
      if ($before.state -eq 'Missing') {
        $securityApplied = Register-OwnedTask -Enabled $true
        $changed = $true
      } elseif (-not $before.configured) {
        throw "The scheduled task is drifted. Run the installer to repair it before enabling autostart."
      } elseif (-not $before.enabled) {
        Set-ExistingTaskEnabled -Enabled $true
        $changed = $true
      }
    }
    'Disable' {
      if ($before.state -eq 'Missing') {
        break
      }
      if (-not $before.configured) {
        throw "The scheduled task is drifted. Run the installer to repair it before disabling autostart."
      }
      if ($before.enabled) {
        Set-ExistingTaskEnabled -Enabled $false
        $changed = $true
      }
    }
    'Unregister' {
      if ($before.state -eq 'Missing') {
        break
      }
      if (-not $before.owned -and -not $before.legacyOwned) {
        throw "A different scheduled task uses '$TaskPath$TaskName'. Removal was refused."
      }
      Unregister-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Confirm:$false
      $changed = $true
    }
  }

  $after = Get-AutostartStatus
  $resultPayload = [pscustomobject]@{
    success = $true
    action = $Action
    changed = $changed
    state = $after.state
    exists = $after.exists
    enabled = $after.enabled
    configured = $after.configured
    owned = $after.owned
    userCanControl = $after.userCanControl
    drift = @($after.drift)
    taskPath = $TaskPath
    taskName = $TaskName
    userSid = $currentSid
    delaySeconds = $DelaySeconds
    runtime = $expectedRuntime
    launchPathPrivate = Test-LaunchPathPrivate
    securityDescriptorApplied = $securityApplied
    execute = if ($after.PSObject.Properties.Name -contains 'execute') { $after.execute } else { $null }
    arguments = if ($after.PSObject.Properties.Name -contains 'arguments') { $after.arguments } else { $null }
    workingDirectory = if ($after.PSObject.Properties.Name -contains 'workingDirectory') {
      $after.workingDirectory
    } else {
      $null
    }
    lastTaskResult = if ($after.PSObject.Properties.Name -contains 'lastTaskResult') {
      $after.lastTaskResult
    } else {
      $null
    }
    error = $null
  }
} catch {
  $after = try {
    Get-AutostartStatus
  } catch {
    $null
  }
  $resultPayload = [pscustomobject]@{
    success = $false
    action = $Action
    changed = $changed
    state = if ($null -ne $after) { $after.state } else { 'PermissionDenied' }
    exists = if ($null -ne $after) { $after.exists } else { $null }
    enabled = if ($null -ne $after) { $after.enabled } else { $null }
    configured = if ($null -ne $after) { $after.configured } else { $false }
    owned = if ($null -ne $after) { $after.owned } else { $false }
    userCanControl = if ($null -ne $after) { $after.userCanControl } else { $false }
    drift = if ($null -ne $after) { @($after.drift) } else { @('unknown') }
    taskPath = $TaskPath
    taskName = $TaskName
    userSid = $currentSid
    delaySeconds = $DelaySeconds
    runtime = $expectedRuntime
    launchPathPrivate = Test-LaunchPathPrivate
    securityDescriptorApplied = $securityApplied
    error = $_.Exception.Message
  }
  $exitCode = 1
} finally {
  if ($operationMutexAcquired -and $null -ne $operationMutex) {
    try {
      $operationMutex.ReleaseMutex()
    } catch {
    }
  }
  if ($null -ne $operationMutex) {
    $operationMutex.Dispose()
  }
}

$resultPayload | ConvertTo-Json -Depth 6
if ($exitCode -ne 0) {
  exit $exitCode
}
