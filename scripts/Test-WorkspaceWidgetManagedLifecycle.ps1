#requires -PSEdition Desktop
# This harness loads the .NET Framework 4.8 native host. Run it only via:
# C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkspaceWidgetManagedLifecycle.ps1 ...
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$HostPath,
  [string]$NodePath = 'node.exe',
  [string]$ProjectRoot,
  [string]$LegacyHostPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$HostPath = [IO.Path]::GetFullPath($HostPath)
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$fixturePath = Join-Path $ProjectRoot 'tests\fixtures\managed-lifecycle\server.js'
$resolvedNodePath = [IO.Path]::GetFullPath((Get-Command $NodePath -ErrorAction Stop).Source)

foreach ($required in @($HostPath, $fixturePath, $resolvedNodePath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required managed lifecycle test input was not found: $required"
  }
}

# This test intentionally retains its per-run fixture root.  It never points at
# a real Widget/AX Store root and never removes state, receipts, or processes
# outside the native supervisor's own isolated contract.
# Keep the retained root short but portable: the supervisor appends hashed item,
# instance, and receipt segments which must remain under legacy Win32 limits.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('w-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

function Get-FreeTcpPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
  finally { $listener.Stop() }
}

function Convert-ManagedJson {
  param([Parameter(Mandatory = $true)]$Value)
  # Reflection can wrap a System.String in PSObject; inspect BaseObject and
  # cast before parsing so callers always receive one JSON result object.
  $raw = if ($Value -is [Management.Automation.PSObject]) { $Value.BaseObject } else { $Value }
  if ($raw -is [string]) { return (([string]$raw) | ConvertFrom-Json) }
  return $Value
}

function Invoke-ManagedStart {
  param($Client, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [int]$Port, [string]$Mode, [bool]$SpawnChild, [string]$Nonce, [bool]$WrapperExit = $false, [int]$ExitAfterMs = 0, [string]$SupervisorHostPath = $HostPath)
  $marker = Join-Path $RuntimeRoot "$ItemId.marker"
  $args = '"{0}" --port {1} --mode {2} --marker "{3}" --spawn-child {4} --nonce {5} --wrapper-exit {6} --exit-after-ms {7} --noisy-start true' -f $fixturePath, $Port, $Mode, $marker, $SpawnChild.ToString().ToLowerInvariant(), $Nonce, $WrapperExit.ToString().ToLowerInvariant(), $ExitAfterMs
  Convert-ManagedJson ($Client::Start($SupervisorHostPath, $RuntimeRoot, $ItemId, $Digest, $resolvedNodePath, $args, $fixtureRoot, "http://127.0.0.1:$Port/health", $fixtureRoot))
}

function Invoke-ManagedStartWithPublicationDelay {
  param($Client, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [int]$Port, [string]$Nonce, [int]$DelayMilliseconds)
  $marker = Join-Path $RuntimeRoot "$ItemId.marker"
  $argumentLine = '"{0}" --port {1} --mode graceful --marker "{2}" --spawn-child false --nonce {3} --noisy-start true' -f $fixturePath, $Port, $marker, $Nonce
  # The delay seam remains private to the native implementation.  Test-only
  # reflection avoids adding a callable production lifecycle command.
  $method = $Client.GetMethod('StartCore', [Reflection.BindingFlags]'NonPublic,Static')
  if ($null -eq $method) { throw 'ManagedServiceClient private start seam was unavailable.' }
  $parameters = [object[]]@([string]$HostPath, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [string]$resolvedNodePath, [string]$argumentLine, [string]$fixtureRoot, "http://127.0.0.1:$Port/health", [string]$fixtureRoot, [int]$DelayMilliseconds)
  Convert-ManagedJson ($method.Invoke($null, $parameters))
}

function Invoke-ManagedStatus {
  param($Client, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [int]$Port)
  Convert-ManagedJson ($Client::Status($RuntimeRoot, $ItemId, $Digest, "http://127.0.0.1:$Port/health"))
}

function Invoke-ManagedStop {
  param($Client, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [int]$Port, [bool]$Force, [int]$TimeoutMs)
  Convert-ManagedJson ($Client::Stop($RuntimeRoot, $ItemId, $Digest, "http://127.0.0.1:$Port/health", $Force, $TimeoutMs))
}

function Invoke-LegacyManagedClient {
  param([string]$LegacyPath, [ValidateSet('Status', 'Stop')][string]$Action, [string]$RuntimeRoot, [string]$ItemId, [string]$Digest, [int]$Port)
  $safeLegacy = [IO.Path]::GetFullPath($LegacyPath).Replace("'", "''")
  $safeRuntime = $RuntimeRoot.Replace("'", "''")
  $safeItem = $ItemId.Replace("'", "''")
  $safeDigest = $Digest.Replace("'", "''")
  $health = "http://127.0.0.1:$Port/health"
  $invoke = if ($Action -eq 'Status') {
    "`$t::Status('$safeRuntime','$safeItem','$safeDigest','$health')"
  } else {
    "`$t::Stop('$safeRuntime','$safeItem','$safeDigest','$health',`$false,5000)"
  }
  $code = "[Reflection.Assembly]::LoadFrom('$safeLegacy')|Out-Null;`$t=[AppDomain]::CurrentDomain.GetAssemblies()|% { `$_.GetType('WorkspaceWidget.Native.ManagedServiceClient',`$false) }|? { `$null -ne `$_ }|select -First 1;if(`$null -eq `$t){throw 'ManagedServiceClient was unavailable in the legacy host.'};$invoke"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
  $output = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -EncodedCommand $encoded
  if ($LASTEXITCODE -ne 0) { throw "Legacy $Action client invocation failed." }
  return Convert-ManagedJson ($output -join "`n")
}

function Test-HttpReady {
  param([int]$Port, [int]$TimeoutMs = 10000)
  $until = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
      if ($response.StatusCode -eq 200) { return $true }
    } catch { }
    Start-Sleep -Milliseconds 150
  } while ([DateTime]::UtcNow -lt $until)
  return $false
}

function Test-HealthNonce {
  param([int]$Port, [string]$Nonce)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
    return [string](($response.Content | ConvertFrom-Json).nonce) -ceq $Nonce
  } catch { return $false }
}

function Wait-HealthOffline {
  param([int]$Port, [int]$TimeoutMs = 10000)
  $until = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    if (-not (Test-HttpReady $Port 250)) { return $true }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $until)
  return $false
}

function Stop-IsolatedSupervisorForCrashTest {
  param([Parameter(Mandatory = $true)]$StartResult, [Parameter(Mandatory = $true)][string]$ExpectedHostPath)
  $supervisor = Get-Process -Id ([int]$StartResult.processId) -ErrorAction Stop
  $actualHost = [IO.Path]::GetFullPath([string]$supervisor.MainModule.FileName)
  if (-not [string]::Equals($actualHost, [IO.Path]::GetFullPath($ExpectedHostPath), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Crash fixture refused: supervisor executable did not match the supplied isolated host."
  }
  # Explicitly authorized only for this owned, per-run supervisor PID.  Its job
  # object must terminate its isolated child without any broad process action.
  Stop-Process -Id $supervisor.Id -Force -ErrorAction Stop
}

function Set-TamperedByte {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $copy = [byte[]]$Bytes.Clone()
  if ($copy.Length -eq 0) { throw 'Cannot tamper an empty isolated lifecycle file.' }
  $copy[$copy.Length - 1] = $copy[$copy.Length - 1] -bxor 0x01
  return $copy
}

function Test-ExactBytes {
  param([byte[]]$Expected, [byte[]]$Actual)
  if ($Expected.Length -ne $Actual.Length) { return $false }
  for ($index = 0; $index -lt $Expected.Length; $index++) {
    if ($Expected[$index] -ne $Actual[$index]) { return $false }
  }
  return $true
}

function Get-ManagedItemHash {
  param([Parameter(Mandatory = $true)][string]$ItemId)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($ItemId))) -replace '-', '').ToLowerInvariant()
  } finally { $hasher.Dispose() }
}

function Read-ProcessLineBounded {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process, [int]$TimeoutMs = 5000)
  $task = $Process.StandardOutput.ReadLineAsync()
  if (-not $task.Wait($TimeoutMs)) { throw "Fixture stdout did not produce a ready line within $TimeoutMs ms." }
  return $task.Result
}

function Read-ProcessErrorBounded {
  param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process, [int]$TimeoutMs = 500)
  $task = $Process.StandardError.ReadToEndAsync()
  if (-not $task.Wait($TimeoutMs)) { return 'stderr was not available within the bounded timeout.' }
  return $task.Result
}

function Start-ForeignFixture {
  param([int]$Port)
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $resolvedNodePath
  $info.Arguments = '"{0}" --port {1} --mode graceful --exit-after-ms 15000' -f $fixturePath, $Port
  $info.WorkingDirectory = $fixtureRoot
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $process = [Diagnostics.Process]::Start($info)
  $ready = Read-ProcessLineBounded $process
  if ([string]::IsNullOrWhiteSpace($ready) -or -not (($ready | ConvertFrom-Json).ready)) {
    throw "Foreign-port fixture did not become ready: $(Read-ProcessErrorBounded $process)"
  }
  return $process
}

try {
  [Reflection.Assembly]::LoadFrom($HostPath) | Out-Null
  $client = [type]::GetType('WorkspaceWidget.Native.ManagedServiceClient, WorkspaceWidget', $false)
  if ($null -eq $client) {
    $client = [AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object { $_.GetType('WorkspaceWidget.Native.ManagedServiceClient', $false) } | Where-Object { $null -ne $_ } | Select-Object -First 1
  }
  if ($null -eq $client) {
    throw 'The supplied host has no WorkspaceWidget.Native.ManagedServiceClient. Build the native managed-service host before executing this test.'
  }

  $portGraceful = Get-FreeTcpPort
  $portForce = Get-FreeTcpPort
  $portForeign = Get-FreeTcpPort
  $runtimeGraceful = Join-Path $fixtureRoot 'graceful-runtime'
  $runtimeForce = Join-Path $fixtureRoot 'force-runtime'
  $runtimeForeign = Join-Path $fixtureRoot 'foreign-runtime'
  $runtimeWrapper = Join-Path $fixtureRoot 'wrapper-runtime'
  $digestGraceful = ('a' * 64)
  $digestForce = ('b' * 64)
  $digestForeign = ('c' * 64)
  $digestWrapper = ('d' * 64)
  $gracefulNonce = [guid]::NewGuid().ToString('N')
  $forceNonce = [guid]::NewGuid().ToString('N')
  $wrapperNonce = [guid]::NewGuid().ToString('N')

  $gracefulStart = Invoke-ManagedStart $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful 'graceful' $false $gracefulNonce
  if (-not $gracefulStart.success -or -not (Test-HttpReady $portGraceful)) { throw 'Owned graceful fixture did not start.' }
  $duplicateStart = Invoke-ManagedStart $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful 'graceful' $false $gracefulNonce
  $gracefulStatus = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful
  $itemHash = Get-ManagedItemHash 'graceful'
  $activePath = Join-Path (Join-Path (Join-Path $runtimeGraceful 'managed-services') $itemHash) 'active.json'
  $activePointer = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
  $instanceRoot = [IO.Path]::GetFullPath([string]$activePointer.instanceDirectory)
  $ownershipPath = Join-Path $instanceRoot 'ownership.json'
  $credentialPath = Join-Path $instanceRoot 'credential.dpapi'
  $ownershipOriginal = [IO.File]::ReadAllBytes($ownershipPath)
  $credentialOriginal = [IO.File]::ReadAllBytes($credentialPath)
  $ownershipTamper = $null
  $credentialTamper = $null
  $ownershipRestoredExact = $false
  $credentialRestoredExact = $false
  try {
    [IO.File]::WriteAllBytes($ownershipPath, (Set-TamperedByte $ownershipOriginal))
    $ownershipTamper = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful
  } finally {
    [IO.File]::WriteAllBytes($ownershipPath, $ownershipOriginal)
    $ownershipRestoredExact = Test-ExactBytes $ownershipOriginal ([IO.File]::ReadAllBytes($ownershipPath))
  }
  try {
    [IO.File]::WriteAllBytes($credentialPath, (Set-TamperedByte $credentialOriginal))
    $credentialTamper = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful
  } finally {
    [IO.File]::WriteAllBytes($credentialPath, $credentialOriginal)
    $credentialRestoredExact = Test-ExactBytes $credentialOriginal ([IO.File]::ReadAllBytes($credentialPath))
  }
  $statusAfterTamperRestore = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful
  $tamperHealthPreserved = (Test-HttpReady $portGraceful 1500) -and (Test-HealthNonce $portGraceful $gracefulNonce)
  $freshCode = "[Reflection.Assembly]::LoadFrom('$($HostPath.Replace("'", "''"))')|Out-Null;`$t=[AppDomain]::CurrentDomain.GetAssemblies()|% { `$_.GetType('WorkspaceWidget.Native.ManagedServiceClient',`$false) }|? { `$null -ne `$_ }|select -First 1;`$t::Status('$($runtimeGraceful.Replace("'", "''"))','graceful','$digestGraceful','http://127.0.0.1:$portGraceful/health')"
  $freshEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($freshCode))
  $freshStatusRaw = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -EncodedCommand $freshEncoded
  if ($LASTEXITCODE -ne 0) { throw 'Fresh PowerShell Status recovery invocation failed.' }
  $freshStatus = Convert-ManagedJson ($freshStatusRaw -join "`n")
  $wrongDigest = ('e' * 64)
  $mismatchStatus = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $wrongDigest $portGraceful
  $mismatchStop = Invoke-ManagedStop $client $runtimeGraceful 'graceful' $wrongDigest $portGraceful $false 500
  $mismatchHealthPreserved = (Test-HttpReady $portGraceful 1500) -and (Test-HealthNonce $portGraceful $gracefulNonce)
  $gracefulStop = Invoke-ManagedStop $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful $false 5000
  $postStopForeign = Start-ForeignFixture $portGraceful
  try {
    if (-not (Test-HttpReady $portGraceful)) { throw 'Post-stop foreign fixture did not become healthy.' }
    $postStopForeignStatus = Invoke-ManagedStatus $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful
    $postStopForeignStop = Invoke-ManagedStop $client $runtimeGraceful 'graceful' $digestGraceful $portGraceful $false 500
    $postStopForeignAlive = -not $postStopForeign.HasExited
  } finally {
    $postStopForeign.WaitForExit(16000) | Out-Null
  }

  $forceStart = Invoke-ManagedStart $client $runtimeForce 'force' $digestForce $portForce 'ignore-break' $true $forceNonce
  if (-not $forceStart.success -or -not (Test-HttpReady $portForce)) { throw 'Owned force fixture did not start.' }
  $directForceRefused = Invoke-ManagedStop $client $runtimeForce 'force' $digestForce $portForce $true 500
  $directForceHealthPreserved = (Test-HttpReady $portForce 1500) -and (Test-HealthNonce $portForce $forceNonce)
  $needsForce = Invoke-ManagedStop $client $runtimeForce 'force' $digestForce $portForce $false 500
  $forcedStop = Invoke-ManagedStop $client $runtimeForce 'force' $digestForce $portForce $true 500

  $portWrapper = Get-FreeTcpPort
  $wrapperStart = Invoke-ManagedStart $client $runtimeWrapper 'wrapper' $digestWrapper $portWrapper 'graceful' $false $wrapperNonce $true
  if (-not $wrapperStart.success -or -not (Test-HttpReady $portWrapper)) { throw 'Wrapper-child fixture did not become healthy.' }
  Start-Sleep -Milliseconds 350
  $wrapperExited = -not (Get-Process -Id ([int]$wrapperStart.rootProcessId) -ErrorAction SilentlyContinue)
  $wrapperStatus = Invoke-ManagedStatus $client $runtimeWrapper 'wrapper' $digestWrapper $portWrapper
  $wrapperHealthBeforeStop = (Test-HttpReady $portWrapper 1500) -and (Test-HealthNonce $portWrapper $wrapperNonce)
  $wrapperNeedsForce = Invoke-ManagedStop $client $runtimeWrapper 'wrapper' $digestWrapper $portWrapper $false 500
  $wrapperStop = Invoke-ManagedStop $client $runtimeWrapper 'wrapper' $digestWrapper $portWrapper $true 500

  $portNatural = Get-FreeTcpPort
  $runtimeNatural = Join-Path $fixtureRoot 'natural-runtime'
  $digestNatural = ('f' * 64)
  $naturalStart = Invoke-ManagedStart $client $runtimeNatural 'natural' $digestNatural $portNatural 'graceful' $false ([guid]::NewGuid().ToString('N')) $false 900
  if (-not $naturalStart.success -or -not (Test-HttpReady $portNatural)) { throw 'Natural-exit fixture did not become healthy.' }
  $naturalOffline = Wait-HealthOffline $portNatural 8000
  $naturalDirectStop = Invoke-ManagedStop $client $runtimeNatural 'natural' $digestNatural $portNatural $false 500

  # Cross the original 15-second UI deadline after the root is safely assigned
  # to its job, then require the client to return only authenticated ownership.
  $portDelayed = Get-FreeTcpPort
  $runtimeDelayed = Join-Path $fixtureRoot 'delayed-runtime'
  $digestDelayed = ('9' * 64)
  $delayedNonce = [guid]::NewGuid().ToString('N')
  $delayedWatch = [Diagnostics.Stopwatch]::StartNew()
  $delayedStart = Invoke-ManagedStartWithPublicationDelay $client $runtimeDelayed 'delayed' $digestDelayed $portDelayed $delayedNonce 16000
  $delayedWatch.Stop()
  if (-not $delayedStart.success -or -not (Test-HttpReady $portDelayed)) { throw 'Delayed authenticated fixture did not start.' }
  $delayedStop = Invoke-ManagedStop $client $runtimeDelayed 'delayed' $digestDelayed $portDelayed $false 5000

  # A publication that exceeds the bounded recovery window must kill only the
  # exact supervisor this test started, including its suspended job child.
  $portTimeout = Get-FreeTcpPort
  $runtimeTimeout = Join-Path $fixtureRoot 'timeout-runtime'
  $digestTimeout = ('8' * 64)
  $timeoutStart = Invoke-ManagedStartWithPublicationDelay $client $runtimeTimeout 'timeout' $digestTimeout $portTimeout ([guid]::NewGuid().ToString('N')) 60000
  $timeoutOffline = Wait-HealthOffline $portTimeout 3000
  $timeoutStatus = Invoke-ManagedStatus $client $runtimeTimeout 'timeout' $digestTimeout $portTimeout

  # The active pointer exists here, but the supervisor has not created its
  # pipe or resumed the root. A final pipe timeout must still drain that exact
  # published job before Start returns its refusal.
  $portPipeTimeout = Get-FreeTcpPort
  $runtimePipeTimeout = Join-Path $fixtureRoot 'pipe-timeout-runtime'
  $digestPipeTimeout = ('7' * 64)
  $pipeTimeoutStart = Invoke-ManagedStartWithPublicationDelay $client $runtimePipeTimeout 'pipe-timeout' $digestPipeTimeout $portPipeTimeout ([guid]::NewGuid().ToString('N')) -48000
  $pipeTimeoutOffline = Wait-HealthOffline $portPipeTimeout 3000
  $pipeTimeoutStatus = Invoke-ManagedStatus $client $runtimePipeTimeout 'pipe-timeout' $digestPipeTimeout $portPipeTimeout

  $portCrash = Get-FreeTcpPort
  $runtimeCrash = Join-Path $fixtureRoot 'crash-runtime'
  $digestCrash = ('1' * 64)
  $crashStart = Invoke-ManagedStart $client $runtimeCrash 'crash' $digestCrash $portCrash 'graceful' $false ([guid]::NewGuid().ToString('N'))
  if (-not $crashStart.success -or -not (Test-HttpReady $portCrash)) { throw 'Crash fixture did not become healthy.' }
  Stop-IsolatedSupervisorForCrashTest $crashStart $HostPath
  $crashOffline = Wait-HealthOffline $portCrash 8000
  $crashForeign = Start-ForeignFixture $portCrash
  try {
    if (-not (Test-HttpReady $portCrash)) { throw 'Crash stale-foreign fixture did not become healthy.' }
    $crashForeignStatus = Invoke-ManagedStatus $client $runtimeCrash 'crash' $digestCrash $portCrash
    $crashForeignStop = Invoke-ManagedStop $client $runtimeCrash 'crash' $digestCrash $portCrash $false 500
    $crashForeignAlive = -not $crashForeign.HasExited
  } finally {
    $crashForeign.WaitForExit(16000) | Out-Null
  }
  $crashRecoveryTasks = @(1..4 | ForEach-Object { $client::StatusAsync($runtimeCrash, 'crash', $digestCrash, "http://127.0.0.1:$portCrash/health") })
  if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$crashRecoveryTasks, 10000)) { throw 'Concurrent stale-recovery StatusAsync calls did not complete in 10 seconds.' }
  $crashRecoveryStatuses = @($crashRecoveryTasks | ForEach-Object { Convert-ManagedJson $_.Result })
  $crashOldInstanceDirectory = Join-Path (Join-Path (Join-Path $runtimeCrash 'managed-services') (Get-ManagedItemHash 'crash')) ([string]$crashStart.instanceId)
  $crashRecoveryReceipts = @(Get-ChildItem -LiteralPath (Join-Path $crashOldInstanceDirectory 'receipts') -Filter '*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { [string]$_.operation -eq 'recovery' })
  $crashStoppedStatus = $crashRecoveryStatuses | Select-Object -First 1
  $crashRecoveredStart = Invoke-ManagedStart $client $runtimeCrash 'crash' $digestCrash $portCrash 'graceful' $false ([guid]::NewGuid().ToString('N'))
  if (-not $crashRecoveredStart.success -or -not (Test-HttpReady $portCrash)) { throw 'Crash recovery fixture did not become healthy.' }
  $crashRecoveredStop = Invoke-ManagedStop $client $runtimeCrash 'crash' $digestCrash $portCrash $false 5000

  # A shortcut contract may change while the previous owned instance is already
  # gone (for example, after a PC shutdown followed by a Widget upgrade). The
  # authenticated stale record must be terminalized only after its exact
  # process identities, pipe, and recorded health port are all absent.
  $portContractTransition = Get-FreeTcpPort
  $runtimeContractTransition = Join-Path $fixtureRoot 'contract-transition-runtime'
  $digestContractBefore = ('5' * 64)
  $digestContractAfter = ('6' * 64)
  $contractTransitionStart = Invoke-ManagedStart $client $runtimeContractTransition 'contract-transition' $digestContractBefore $portContractTransition 'graceful' $false ([guid]::NewGuid().ToString('N'))
  if (-not $contractTransitionStart.success -or -not (Test-HttpReady $portContractTransition)) { throw 'Contract-transition fixture did not become healthy.' }
  Stop-IsolatedSupervisorForCrashTest $contractTransitionStart $HostPath
  $contractTransitionOffline = Wait-HealthOffline $portContractTransition 8000
  $contractTransitionStatus = Invoke-ManagedStatus $client $runtimeContractTransition 'contract-transition' $digestContractAfter $portContractTransition
  $contractTransitionOldDirectory = Join-Path (Join-Path (Join-Path $runtimeContractTransition 'managed-services') (Get-ManagedItemHash 'contract-transition')) ([string]$contractTransitionStart.instanceId)
  $contractTransitionRecoveryReceipts = @(Get-ChildItem -LiteralPath (Join-Path $contractTransitionOldDirectory 'receipts') -Filter '*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { [string]$_.operation -eq 'recovery' })
  $contractTransitionRestart = Invoke-ManagedStart $client $runtimeContractTransition 'contract-transition' $digestContractAfter $portContractTransition 'graceful' $false ([guid]::NewGuid().ToString('N'))
  if (-not $contractTransitionRestart.success -or -not (Test-HttpReady $portContractTransition)) { throw 'Recovered contract-transition fixture did not become healthy.' }
  $contractTransitionStop = Invoke-ManagedStop $client $runtimeContractTransition 'contract-transition' $digestContractAfter $portContractTransition $false 5000

  $portCrossRoot = Get-FreeTcpPort
  $runtimeCrossSource = Join-Path $fixtureRoot 'cross-source-runtime'
  $runtimeCrossTarget = Join-Path $fixtureRoot 'cross-target-runtime'
  $digestCrossRoot = ('2' * 64)
  $crossStart = Invoke-ManagedStart $client $runtimeCrossSource 'cross-root' $digestCrossRoot $portCrossRoot 'graceful' $false ([guid]::NewGuid().ToString('N'))
  if (-not $crossStart.success -or -not (Test-HttpReady $portCrossRoot)) { throw 'Cross-root source fixture did not become healthy.' }
  $crossHash = Get-ManagedItemHash 'cross-root'
  $crossSourceActive = Join-Path (Join-Path (Join-Path $runtimeCrossSource 'managed-services') $crossHash) 'active.json'
  $crossTargetDirectory = Join-Path (Join-Path $runtimeCrossTarget 'managed-services') $crossHash
  New-Item -ItemType Directory -Path $crossTargetDirectory -Force | Out-Null
  Copy-Item -LiteralPath $crossSourceActive -Destination (Join-Path $crossTargetDirectory 'active.json')
  $crossTargetStatus = Invoke-ManagedStatus $client $runtimeCrossTarget 'cross-root' $digestCrossRoot $portCrossRoot
  $crossTargetStop = Invoke-ManagedStop $client $runtimeCrossTarget 'cross-root' $digestCrossRoot $portCrossRoot $false 500
  $crossSourceHealthPreserved = (Test-HttpReady $portCrossRoot 1500)
  $crossSourceStop = Invoke-ManagedStop $client $runtimeCrossSource 'cross-root' $digestCrossRoot $portCrossRoot $false 5000

  $legacyCompatibilityRequested = -not [string]::IsNullOrWhiteSpace($LegacyHostPath)
  $legacyStatus = $null
  $legacyStop = $null
  $legacyReverseStatus = $null
  $legacyReverseStop = $null
  if ($legacyCompatibilityRequested) {
    if (-not (Test-Path -LiteralPath $LegacyHostPath -PathType Leaf)) { throw "LegacyHostPath was not found: $LegacyHostPath" }
    $portLegacy = Get-FreeTcpPort
    $runtimeLegacy = Join-Path $fixtureRoot 'legacy-runtime'
    $digestLegacy = ('3' * 64)
    # Keep this process bound to the new client assembly while it starts the
    # retained server binary.  Loading both assemblies would unify the public
    # type name and invalidate the old-server/new-client compatibility proof.
    $legacyStart = Invoke-ManagedStart $client $runtimeLegacy 'legacy' $digestLegacy $portLegacy 'graceful' $false ([guid]::NewGuid().ToString('N')) $false 0 $LegacyHostPath
    if (-not $legacyStart.success -or -not (Test-HttpReady $portLegacy)) { throw 'Legacy compatibility fixture did not become healthy.' }
    $legacyStatus = Invoke-ManagedStatus $client $runtimeLegacy 'legacy' $digestLegacy $portLegacy
    $legacyStop = Invoke-ManagedStop $client $runtimeLegacy 'legacy' $digestLegacy $portLegacy $false 5000

    # Reverse proof: isolate the retained C client in a fresh Desktop process
    # while it talks to this final host's supervisor. The fixture remains
    # bounded and writes its normal graceful marker; no client-side ACK exists.
    $portLegacyReverse = Get-FreeTcpPort
    $runtimeLegacyReverse = Join-Path $fixtureRoot 'legacy-reverse-runtime'
    $digestLegacyReverse = ('4' * 64)
    $legacyReverseStart = Invoke-ManagedStart $client $runtimeLegacyReverse 'legacy-reverse' $digestLegacyReverse $portLegacyReverse 'graceful' $false ([guid]::NewGuid().ToString('N'))
    if (-not $legacyReverseStart.success -or -not (Test-HttpReady $portLegacyReverse)) { throw 'Reverse legacy compatibility fixture did not become healthy.' }
    $legacyReverseStatus = Invoke-LegacyManagedClient $LegacyHostPath 'Status' $runtimeLegacyReverse 'legacy-reverse' $digestLegacyReverse $portLegacyReverse
    $legacyReverseStop = Invoke-LegacyManagedClient $LegacyHostPath 'Stop' $runtimeLegacyReverse 'legacy-reverse' $digestLegacyReverse $portLegacyReverse
  }

  $foreign = Start-ForeignFixture $portForeign
  try {
    if (-not (Test-HttpReady $portForeign)) { throw 'Foreign-port fixture did not become healthy.' }
    $foreignResult = Invoke-ManagedStart $client $runtimeForeign 'foreign' $digestForeign $portForeign 'graceful' $false
    $foreignAliveAfterRefusal = -not $foreign.HasExited
  } finally {
    $foreign.WaitForExit(6000) | Out-Null
  }

  $appSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1') -Raw
  $checks = [ordered]@{
    gracefulStartOwned = [bool]$gracefulStart.success -and [bool]$gracefulStart.owned -and [string]$gracefulStart.state -eq 'Owned'
    duplicateStartReturnsSameOwnership = [bool]$duplicateStart.success -and [bool]$duplicateStart.owned -and [string]$duplicateStart.instanceId -eq [string]$gracefulStart.instanceId -and [int]$duplicateStart.processId -eq [int]$gracefulStart.processId -and [int]$duplicateStart.rootProcessId -eq [int]$gracefulStart.rootProcessId
    gracefulStatusOwned = [bool]$gracefulStatus.owned -and [bool]$gracefulStatus.stoppable
    startupOutputCannotForgeOwnership = [int]$gracefulStart.processId -ne 1 -and [int]$gracefulStart.processId -eq [int]$gracefulStatus.processId -and [int]$gracefulStart.rootProcessId -eq [int]$gracefulStatus.rootProcessId -and [string]$gracefulStart.instanceId -ceq [string]$activePointer.instanceId
    ownershipRecordTamperRefused = -not [bool]$ownershipTamper.success -and [string]$ownershipTamper.state -eq 'Ambiguous' -and -not [bool]$ownershipTamper.stoppable
    dpapiCapabilityTamperRefused = -not [bool]$credentialTamper.success -and [string]$credentialTamper.state -eq 'Ambiguous' -and -not [bool]$credentialTamper.stoppable
    tamperBytesRestoredExactly = $ownershipRestoredExact -and $credentialRestoredExact -and [bool]$statusAfterTamperRestore.owned -and $tamperHealthPreserved
    freshPowerShellRecovery = [bool]$freshStatus.owned -and [int]$freshStatus.rootProcessId -eq [int]$gracefulStart.rootProcessId
    mismatchedContractStatusRefused = -not [bool]$mismatchStatus.success -and -not [bool]$mismatchStatus.stoppable
    mismatchedContractStopRefused = -not [bool]$mismatchStop.success -and $mismatchHealthPreserved
    gracefulStopReceipt = [bool]$gracefulStop.success -and [string]$gracefulStop.state -eq 'Graceful' -and [bool]$gracefulStop.jobEmpty -and [bool]$gracefulStop.healthOffline -and (Test-Path -LiteralPath ([string]$gracefulStop.receiptPath))
    terminalStoppedForeignPortRefused = [string]$postStopForeignStatus.state -eq 'RunningUnowned' -and -not [bool]$postStopForeignStatus.stoppable -and -not [bool]$postStopForeignStop.success -and $postStopForeignAlive
    directForceBeforeTimeoutRefused = -not [bool]$directForceRefused.success -and $directForceHealthPreserved
    forceRefusal = -not [bool]$needsForce.success -and [string]$needsForce.state -eq 'NeedsForce'
    forcedStopReceipt = [bool]$forcedStop.success -and [string]$forcedStop.state -eq 'Forced' -and [bool]$forcedStop.jobEmpty -and [bool]$forcedStop.healthOffline -and (Test-Path -LiteralPath ([string]$forcedStop.receiptPath))
    wrapperExitRetainsOwnedChild = $wrapperExited -and [bool]$wrapperStatus.owned -and $wrapperHealthBeforeStop
    wrapperJobTreeStopsChild = -not [bool]$wrapperNeedsForce.success -and [string]$wrapperNeedsForce.state -eq 'NeedsForce' -and [bool]$wrapperStop.success -and [string]$wrapperStop.state -eq 'Forced' -and [bool]$wrapperStop.jobEmpty -and [bool]$wrapperStop.healthOffline
    naturalExitDirectStop = $naturalOffline -and [bool]$naturalDirectStop.success -and [string]$naturalDirectStop.state -eq 'Stopped' -and [bool]$naturalDirectStop.jobEmpty
    delayedPublicationRecoversAfterOriginalDeadline = [bool]$delayedStart.success -and [bool]$delayedStart.owned -and [string]$delayedStart.state -eq 'Owned' -and $delayedWatch.ElapsedMilliseconds -ge 15000 -and [bool]$delayedStop.success -and [string]$delayedStop.state -eq 'Graceful'
    timedOutPublicationLeavesNoAmbiguousOrphan = -not [bool]$timeoutStart.success -and $timeoutOffline -and [string]$timeoutStatus.state -eq 'Stopped' -and [bool]$timeoutStatus.healthOffline -and -not [bool]$timeoutStatus.owned
    timedOutPublishedPipeLeavesNoAmbiguousOrphan = -not [bool]$pipeTimeoutStart.success -and $pipeTimeoutOffline -and [string]$pipeTimeoutStatus.state -eq 'Stopped' -and [bool]$pipeTimeoutStatus.healthOffline -and -not [bool]$pipeTimeoutStatus.owned
    isolatedSupervisorCrashRecovery = $crashOffline -and [string]$crashForeignStatus.state -eq 'Ambiguous' -and -not [bool]$crashForeignStatus.stoppable -and -not [bool]$crashForeignStop.success -and $crashForeignAlive -and @($crashRecoveryStatuses | Where-Object { [string]$_.state -ne 'Stopped' -or -not [bool]$_.jobEmpty -or -not [bool]$_.healthOffline }).Count -eq 0 -and $crashRecoveryReceipts.Count -eq 1 -and [bool]$crashRecoveredStart.success -and [bool]$crashRecoveredStop.success -and [string]$crashRecoveredStop.state -eq 'Graceful'
    staleContractTransitionRecoversOnce = $contractTransitionOffline -and [bool]$contractTransitionStatus.success -and [string]$contractTransitionStatus.state -eq 'Stopped' -and [bool]$contractTransitionStatus.jobEmpty -and [bool]$contractTransitionStatus.healthOffline -and [bool]$contractTransitionStatus.recoveryInference -and $contractTransitionRecoveryReceipts.Count -eq 1 -and [bool]$contractTransitionRestart.success -and [string]$contractTransitionRestart.state -eq 'Owned' -and [string]$contractTransitionRestart.instanceId -ne [string]$contractTransitionStart.instanceId -and [bool]$contractTransitionStop.success -and [string]$contractTransitionStop.state -eq 'Graceful'
    crossRootActivePointerRefused = -not [bool]$crossTargetStatus.success -and [string]$crossTargetStatus.state -eq 'Ambiguous' -and -not [bool]$crossTargetStop.success -and $crossSourceHealthPreserved -and [bool]$crossSourceStop.success
    legacyClientProtocolCompatibility = -not $legacyCompatibilityRequested -or ([bool]$legacyStatus.success -and [string]$legacyStatus.state -eq 'Owned' -and [bool]$legacyStop.success -and [string]$legacyStop.state -eq 'Graceful' -and [bool]$legacyReverseStatus.success -and [string]$legacyReverseStatus.state -eq 'Owned' -and [bool]$legacyReverseStop.success -and [string]$legacyReverseStop.state -eq 'Graceful')
    foreignPortNotAdoptedOrKilled = -not [bool]$foreignResult.owned -and $foreignAliveAfterRefusal
    trayExitHasNoManagedStopCall = $appSource -match 'function Exit-WorkspaceWidget' -and $appSource -notmatch '(?s)function Exit-WorkspaceWidget.*?ManagedServiceClient.*?Stop'
  }
  $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
  [pscustomobject]@{ success = $failed.Count -eq 0; failedChecks = $failed; checks = $checks; fixtureRoot = $fixtureRoot; graceful = @{ start = $gracefulStart; duplicateStart = $duplicateStart; status = $gracefulStatus; ownershipTamper = $ownershipTamper; credentialTamper = $credentialTamper; statusAfterTamperRestore = $statusAfterTamperRestore; freshStatus = $freshStatus; mismatchStatus = $mismatchStatus; mismatchStop = $mismatchStop; postStopForeignStatus = $postStopForeignStatus; postStopForeignStop = $postStopForeignStop }; force = @{ start = $forceStart; directForce = $directForceRefused; needsForce = $needsForce; stop = $forcedStop }; wrapper = @{ start = $wrapperStart; status = $wrapperStatus; healthBeforeStop = $wrapperHealthBeforeStop; needsForce = $wrapperNeedsForce; stop = $wrapperStop }; natural = @{ start = $naturalStart; stop = $naturalDirectStop }; delayed = @{ elapsedMilliseconds = $delayedWatch.ElapsedMilliseconds; start = $delayedStart; stop = $delayedStop }; timeout = @{ start = $timeoutStart; status = $timeoutStatus; healthOffline = $timeoutOffline }; pipeTimeout = @{ start = $pipeTimeoutStart; status = $pipeTimeoutStatus; healthOffline = $pipeTimeoutOffline }; crash = @{ start = $crashStart; foreignStatus = $crashForeignStatus; foreignStop = $crashForeignStop; recoveryStatuses = $crashRecoveryStatuses; recoveryReceiptCount = $crashRecoveryReceipts.Count; recoveredStart = $crashRecoveredStart; recoveredStop = $crashRecoveredStop }; contractTransition = @{ start = $contractTransitionStart; offline = $contractTransitionOffline; status = $contractTransitionStatus; recoveryReceiptCount = $contractTransitionRecoveryReceipts.Count; restart = $contractTransitionRestart; stop = $contractTransitionStop }; crossRoot = @{ sourceStart = $crossStart; targetStatus = $crossTargetStatus; targetStop = $crossTargetStop; sourceStop = $crossSourceStop }; legacy = @{ requested = $legacyCompatibilityRequested; oldServerNewClient = @{ status = $legacyStatus; stop = $legacyStop }; oldClientNewServer = @{ status = $legacyReverseStatus; stop = $legacyReverseStop } }; foreign = $foreignResult } | ConvertTo-Json -Depth 8
  if ($failed.Count -gt 0) { exit 1 }
} catch {
  [pscustomobject]@{
    success = $false
    fixtureRoot = $fixtureRoot
    error = $_.Exception.Message
    exceptionType = $_.Exception.GetType().FullName
    scriptStackTrace = $_.ScriptStackTrace
    position = $_.InvocationInfo.PositionMessage
    command = [string]$_.InvocationInfo.MyCommand
  } | ConvertTo-Json -Depth 5
  exit 1
}
