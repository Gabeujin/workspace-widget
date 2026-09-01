[CmdletBinding()]
param([string]$ProjectRoot,[string]$NodePath = 'node.exe')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$modulePath = Join-Path $ProjectRoot 'app\AxStoreLifecycle.psm1'
$brokerPath = Join-Path $ProjectRoot 'app\ax-store-lifecycle-broker.js'
$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$testPath = Join-Path $ProjectRoot 'tests\ax-store-lifecycle.test.js'
$pipeFixturePath = Join-Path $ProjectRoot 'tests\named-pipe-acl-fixture.js'
$legacyFixturePath = Join-Path $ProjectRoot 'tests\legacy-ax-store-fixture.js'
$installerPath = Join-Path $ProjectRoot 'scripts\Install-WorkspaceWidget.ps1'
$resolvedNodePath = [IO.Path]::GetFullPath((Get-Command $NodePath -ErrorAction Stop).Source)

$parsers = foreach ($path in @($modulePath,$appPath,$installerPath)) {
  $tokens=$null; $errors=$null
  [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
  [pscustomobject]@{path=$path;valid=$errors.Count -eq 0;errors=@($errors|ForEach-Object Message)}
}
$before = @{}
foreach ($port in @(4520,4521)) {
  $before[[string]$port] = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}
$nodeSyntax = @(& $resolvedNodePath --check $legacyFixturePath 2>&1)
$nodeSyntaxExit = $LASTEXITCODE
$nodeOutput = @(& $resolvedNodePath --test $testPath 2>&1)
$nodeExit = $LASTEXITCODE
$after = @{}
foreach ($port in @(4520,4521)) {
  $after[[string]$port] = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}
$appContent = Get-Content -LiteralPath $appPath -Raw
$moduleContent = Get-Content -LiteralPath $modulePath -Raw
$brokerContent = Get-Content -LiteralPath $brokerPath -Raw
$installerContent = Get-Content -LiteralPath $installerPath -Raw
$module = Get-Module AxStoreLifecycle -ErrorAction SilentlyContinue
if ($null -eq $module) { Import-Module $modulePath -Force; $module = Get-Module AxStoreLifecycle }
$aclProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceWidgetAxAcl-' + [guid]::NewGuid().ToString('N'))
& $module { param($path) Protect-AxStoreLifecycleDirectory -Path $path } $aclProbeRoot
$aclProbe = Get-Acl -LiteralPath $aclProbeRoot
$allowedSids = @(
  [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
  'S-1-5-18',
  'S-1-5-32-544'
)
$aclRules = @($aclProbe.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
$aclExact = $aclProbe.AreAccessRulesProtected -and $aclRules.Count -eq 3 -and @($aclRules | Where-Object {
    $_.IsInherited -or $_.AccessControlType -ne 'Allow' -or $_.IdentityReference.Value -notin $allowedSids -or $_.FileSystemRights -ne 'FullControl'
  }).Count -eq 0

$pipeName = '\\.\pipe\WorkspaceWidget.AxStore.AclProbe.' + [guid]::NewGuid().ToString('N')
$pipeProcessInfo = [Diagnostics.ProcessStartInfo]::new()
$pipeProcessInfo.FileName = $resolvedNodePath
$pipeProcessInfo.Arguments = '"{0}" "{1}"' -f $pipeFixturePath,$pipeName
$pipeProcessInfo.UseShellExecute = $false
$pipeProcessInfo.RedirectStandardOutput = $true
$pipeProcessInfo.RedirectStandardError = $true
$pipeProcessInfo.CreateNoWindow = $true
$pipeProcess = [Diagnostics.Process]::Start($pipeProcessInfo)
$pipeAclSet = $null
$pipeAclReadback = $null
try {
  $ready = $pipeProcess.StandardOutput.ReadLine()
  if ($ready -ne 'READY') { throw "Named pipe ACL fixture did not become ready. $($pipeProcess.StandardError.ReadToEnd())" }
  $pipeAclSet = & $module { param($name,$pid) Set-AxStorePipeAcl -PipeName $name -ExpectedServerPid $pid } $pipeName $pipeProcess.Id
  $pipeAclReadback = & $module { param($name,$pid) Get-AxStorePipeAclAttestation -PipeName $name -ExpectedServerPid $pid } $pipeName $pipeProcess.Id
} finally {
  if ($null -ne $pipeProcess -and -not $pipeProcess.HasExited) { $pipeProcess.Kill(); $pipeProcess.WaitForExit() }
  if ($null -ne $pipeProcess) { $pipeProcess.Dispose() }
}

$registrationRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceWidgetAxRegistration-' + [guid]::NewGuid().ToString('N'))
$registrationProjectRoot = Join-Path $registrationRuntimeRoot 'project\apps\ax-store'
$registrationScripts = Join-Path $registrationProjectRoot 'scripts'
$registrationPublic = Join-Path $registrationProjectRoot 'src\public'
$registrationSrc = Split-Path -Parent $registrationPublic
New-Item -ItemType Directory -Path $registrationScripts,$registrationPublic -Force | Out-Null
$registrationLauncher = Join-Path $registrationScripts 'workspace-widget-launcher.js'
$registrationContract = Join-Path $registrationPublic 'runtime-contract.json'
$registrationServer = Join-Path $registrationSrc 'server.js'
[IO.File]::WriteAllText($registrationLauncher,"module.exports = {};`n",[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $legacyFixturePath -Destination $registrationServer
$registrationContractObject = [ordered]@{
  schemaVersion='ax.store/runtime-contract/v1'
  control=[ordered]@{apiVersion='test-control';healthPathBase='/api/health/contracts'}
  runtime=[ordered]@{apiVersion='test-runtime';healthPath='/health'}
  database=[ordered]@{schemaVersion=1}
  launcher=[ordered]@{leaseHost='127.0.0.1';leasePort=4519}
}
[IO.File]::WriteAllText($registrationContract,($registrationContractObject|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$registrationDescriptor = & $module { param($path,$node) Get-AxStoreContractDescriptor -LauncherPath $path -BundledNodePath $node -LegacyNodePath $node } $registrationLauncher $resolvedNodePath
$registrationItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health=[string]$registrationDescriptor.controlHealthUrl;startupTarget=$registrationLauncher;startupArgs=''}
$registration = Register-AxStoreLifecycle -Item $registrationItem -RuntimeRoot $registrationRuntimeRoot -LauncherPath $registrationLauncher -BundledNodePath $resolvedNodePath -LegacyNodePath $resolvedNodePath -ReleaseId '0.1.2-test' -ReleaseFingerprint ('f' * 64)
$registrationReadback = & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $registrationItem $registrationRuntimeRoot
$tamperedItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health='http://127.0.0.1:4520/health';startupTarget=$registrationLauncher;startupArgs=''}
$registrationTamperDenied = $false
try {
  & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $tamperedItem $registrationRuntimeRoot | Out-Null
} catch { $registrationTamperDenied = $true }
$alternateProjectRoot = Join-Path $registrationRuntimeRoot 'alternate\apps\ax-store'
$alternateScripts = Join-Path $alternateProjectRoot 'scripts'
$alternatePublic = Join-Path $alternateProjectRoot 'src\public'
$alternateSrc = Split-Path -Parent $alternatePublic
New-Item -ItemType Directory -Path $alternateScripts,$alternatePublic -Force | Out-Null
$alternateLauncher = Join-Path $alternateScripts 'workspace-widget-launcher.js'
$alternateContract = Join-Path $alternatePublic 'runtime-contract.json'
$alternateServer = Join-Path $alternateSrc 'server.js'
Copy-Item -LiteralPath $registrationLauncher -Destination $alternateLauncher
Copy-Item -LiteralPath $registrationContract -Destination $alternateContract
Copy-Item -LiteralPath $registrationServer -Destination $alternateServer
$alternateItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health=[string]$registrationDescriptor.controlHealthUrl;startupTarget=$alternateLauncher;startupArgs=''}
$registrationAliasDenied = $false
try {
  & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $alternateItem $registrationRuntimeRoot | Out-Null
} catch { $registrationAliasDenied = $true }
$contractOriginalBytes = [IO.File]::ReadAllBytes($registrationContract)
$registrationArtifactDriftDenied = $false
try {
  [IO.File]::WriteAllText($registrationContract,((Get-Content -LiteralPath $registrationContract -Raw) + "`n"),[Text.UTF8Encoding]::new($false))
  try {
    & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $registrationItem $registrationRuntimeRoot | Out-Null
  } catch { $registrationArtifactDriftDenied = $true }
} finally {
  [IO.File]::WriteAllBytes($registrationContract,$contractOriginalBytes)
}

function Get-FreeTcpPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

$legacyControlPort = Get-FreeTcpPort
do { $legacyRuntimePort = Get-FreeTcpPort } while ($legacyRuntimePort -eq $legacyControlPort)
$legacyRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceWidgetAxLegacy-' + [guid]::NewGuid().ToString('N'))
$legacyProjectRoot = Join-Path $legacyRuntimeRoot 'project\apps\ax-store'
$legacyScripts = Join-Path $legacyProjectRoot 'scripts'
$legacyPublic = Join-Path $legacyProjectRoot 'src\public'
$legacySrc = Split-Path -Parent $legacyPublic
New-Item -ItemType Directory -Path $legacyScripts,$legacyPublic -Force | Out-Null
$legacyLauncher = Join-Path $legacyScripts 'workspace-widget-launcher.js'
$legacyServer = Join-Path $legacySrc 'server.js'
$legacyContract = Join-Path $legacyPublic 'runtime-contract.json'
[IO.File]::WriteAllText($legacyLauncher,"module.exports = {};`n",[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $legacyFixturePath -Destination $legacyServer
$legacyContractObject = [ordered]@{
  schemaVersion='ax.store/runtime-contract/v1'
  control=[ordered]@{apiVersion='legacy-control';healthPathBase='/api/health/contracts'}
  runtime=[ordered]@{apiVersion='legacy-runtime';healthPath='/health'}
  database=[ordered]@{schemaVersion=10}
  launcher=[ordered]@{leaseHost='127.0.0.1';leasePort=4519}
  testControlPort=$legacyControlPort
  testRuntimePort=$legacyRuntimePort
}
[IO.File]::WriteAllText($legacyContract,($legacyContractObject|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$legacyProcess = $null
$legacyCandidate = $null
$legacyEligible = $null
$legacyStop = $null
$legacyUserSidDenied = $false
$legacyArgumentDenied = $false
$legacyArtifactDriftDenied = $false
$legacyPortTheftDenied = $false
$legacyPidReuseDenied = $false
$legacyRegistrationTamperDenied = $false
$legacyReplayDenied = $false
$legacyConcurrentStopDenied = $false
$legacyDurableReplayDenied = $false
$legacyReplayProcess = $null
try {
  & $module { param($control,$runtime) $script:ControlPort=$control; $script:RuntimePort=$runtime } $legacyControlPort $legacyRuntimePort
  $legacyDescriptor = & $module { param($launcher,$node) Get-AxStoreContractDescriptor -LauncherPath $launcher -BundledNodePath $node -LegacyNodePath $node } $legacyLauncher $resolvedNodePath
  $legacyItem = [pscustomobject]@{id='ax-store';target="http://127.0.0.1:$legacyControlPort/";health=[string]$legacyDescriptor.controlHealthUrl;startupTarget=$legacyLauncher;startupArgs=''}
  $legacyRegistration = Register-AxStoreLifecycle -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -LauncherPath $legacyLauncher -BundledNodePath $resolvedNodePath -LegacyNodePath $resolvedNodePath -ReleaseId '0.1.2-legacy-test' -ReleaseFingerprint ('e' * 64)
  $legacyInfo = [Diagnostics.ProcessStartInfo]::new()
  $legacyInfo.FileName = $resolvedNodePath
  $legacyInfo.Arguments = '"{0}"' -f $legacyServer
  $legacyInfo.WorkingDirectory = $legacySrc
  $legacyInfo.UseShellExecute = $false
  $legacyInfo.RedirectStandardOutput = $true
  $legacyInfo.RedirectStandardError = $true
  $legacyInfo.CreateNoWindow = $true
  $legacyProcess = [Diagnostics.Process]::Start($legacyInfo)
  $legacyReady = $legacyProcess.StandardOutput.ReadLine()
  if ($legacyReady -ne 'READY') { throw "Legacy fixture did not become ready. $($legacyProcess.StandardError.ReadToEnd())" }
  $legacyCandidate = Get-AxStoreLifecycleStatus -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -SkipHealth
  $legacyEligible = Get-AxStoreLifecycleStatus -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot
  $legacyOwners = & $module { Get-AxStorePortOwners }
  $legacyIdentity = & $module { param($processId) Get-AxStoreProcessIdentity -ProcessId $processId } $legacyProcess.Id
  $legacyReadback = & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $legacyItem $legacyRuntimeRoot
  $badUserIdentity = $legacyIdentity.PSObject.Copy()
  $badUserIdentity.userSid = 'S-1-5-21-1-2-3-1001'
  try { & $module { param($registration,$owners,$identity) Test-AxStoreLegacyIdentitySnapshot -Registration $registration -Owners $owners -ProcessIdentity $identity } $legacyReadback $legacyOwners $badUserIdentity | Out-Null } catch { $legacyUserSidDenied = $true }
  $badArgumentIdentity = $legacyIdentity.PSObject.Copy()
  $badArgumentIdentity.commandLine = ([string]$legacyIdentity.commandLine) + ' --unexpected'
  $badArgumentIdentity.commandLineSha256 = & $module { param($value) Get-AxStoreTextSha256 $value } $badArgumentIdentity.commandLine
  try { & $module { param($registration,$owners,$identity) Test-AxStoreLegacyIdentitySnapshot -Registration $registration -Owners $owners -ProcessIdentity $identity } $legacyReadback $legacyOwners $badArgumentIdentity | Out-Null } catch { $legacyArgumentDenied = $true }
  $splitOwners = @{}
  $splitOwners[$legacyControlPort] = @($legacyProcess.Id)
  $splitOwners[$legacyRuntimePort] = @($legacyProcess.Id + 1)
  try { & $module { param($registration,$owners,$identity) Test-AxStoreLegacyIdentitySnapshot -Registration $registration -Owners $owners -ProcessIdentity $identity } $legacyReadback $splitOwners $legacyIdentity | Out-Null } catch { $legacyPortTheftDenied = $true }
  $reuseProcess = $legacyIdentity.PSObject.Copy()
  $reuseProcess.creationTimeFileTimeUtc = [int64]$legacyIdentity.creationTimeFileTimeUtc + 1
  try { & $module { param($baseline,$fresh,$identity) Assert-AxStoreLegacyIdentityContinuity -BaselineEvidence $baseline -FreshProcess $fresh -FreshIdentity $identity } $legacyEligible.legacy $reuseProcess $legacyEligible.legacy.identity } catch { $legacyPidReuseDenied = $true }
  $registrationBytes = [IO.File]::ReadAllBytes($legacyReadback.paths.documentPath)
  try {
    $tamperedRegistration = Get-Content -LiteralPath $legacyReadback.paths.documentPath -Raw | ConvertFrom-Json
    $tamperedRegistration.signature = ('0' * 64)
    [IO.File]::WriteAllText($legacyReadback.paths.documentPath,($tamperedRegistration|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $tamperedRegistrationStatus = Get-AxStoreLifecycleStatus -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -SkipHealth
    $legacyRegistrationTamperDenied = $tamperedRegistrationStatus.state -eq 'RegistrationInvalid' -and -not $tamperedRegistrationStatus.legacyTransitionAvailable -and -not $legacyProcess.HasExited
  } finally { [IO.File]::WriteAllBytes($legacyReadback.paths.documentPath,$registrationBytes) }
  $transitionPaths = & $module { param($root,$registration) Get-AxStoreLegacyTransitionPaths -RuntimeRoot $root -Registration $registration } $legacyRuntimeRoot $legacyReadback
  & $module { param($path) Protect-AxStoreLifecycleDirectory -Path $path } $transitionPaths.root
  $replayPath = Join-Path $transitionPaths.root 'replay-probe.json'
  $replayPayload = [ordered]@{schema='workspace-widget/ax-store-legacy-transition/v1';requestId='replay-probe';requestedAt=(Get-Date).ToUniversalTime().ToString('o')}
  & $module { param($path,$secret,$payload) Write-AxStoreSignedDocumentExclusive -Path $path -Secret $secret -Payload $payload } $replayPath $legacyReadback.secret $replayPayload | Out-Null
  try { & $module { param($path,$secret,$payload) Write-AxStoreSignedDocumentExclusive -Path $path -Secret $secret -Payload $payload } $replayPath $legacyReadback.secret $replayPayload | Out-Null } catch { $legacyReplayDenied = $true }
  $serverBytes = [IO.File]::ReadAllBytes($legacyServer)
  try {
    [IO.File]::WriteAllText($legacyServer,((Get-Content -LiteralPath $legacyServer -Raw)+"`n"),[Text.UTF8Encoding]::new($false))
    $driftStatus = Get-AxStoreLifecycleStatus -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -SkipHealth
    $legacyArtifactDriftDenied = $driftStatus.state -in @('RegistrationInvalid','RunningUnowned') -and -not $driftStatus.legacyTransitionAvailable
  } finally { [IO.File]::WriteAllBytes($legacyServer,$serverBytes) }
  $mutexHolderInfo = [Diagnostics.ProcessStartInfo]::new()
  $mutexHolderInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $mutexHolderInfo.Arguments = '-NoProfile -NonInteractive -Command "$m=[Threading.Mutex]::new($false,''Local\WorkspaceWidget.AxStore.LegacyTransition.v1'');$null=$m.WaitOne();[Console]::Out.WriteLine(''READY'');Start-Sleep -Seconds 2;$m.ReleaseMutex();$m.Dispose()"'
  $mutexHolderInfo.UseShellExecute = $false
  $mutexHolderInfo.RedirectStandardOutput = $true
  $mutexHolderInfo.RedirectStandardError = $true
  $mutexHolderInfo.CreateNoWindow = $true
  $mutexHolder = [Diagnostics.Process]::Start($mutexHolderInfo)
  try {
    if ($mutexHolder.StandardOutput.ReadLine() -ne 'READY') { throw "Mutex holder did not become ready. $($mutexHolder.StandardError.ReadToEnd())" }
    $concurrentResult = Stop-AxStoreVerifiedLegacyInstance -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -Reason 'concurrent transition test' -AcknowledgedImpact -AcknowledgedLegacyTermination
    $legacyConcurrentStopDenied = $concurrentResult.state -eq 'STOP_ALREADY_IN_PROGRESS' -and -not $legacyProcess.HasExited
  } finally {
    $mutexHolder.WaitForExit(5000) | Out-Null
    if (-not $mutexHolder.HasExited) { $mutexHolder.Kill(); $mutexHolder.WaitForExit() }
    $mutexHolder.Dispose()
  }
  $legacyStop = Stop-AxStoreVerifiedLegacyInstance -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -Reason 'isolated legacy transition test' -AcknowledgedImpact -AcknowledgedLegacyTermination
  if (-not $legacyStop.success) { throw "Legacy transition fixture stop failed: $($legacyStop | ConvertTo-Json -Compress)" }
  $legacyReplayInfo = [Diagnostics.ProcessStartInfo]::new()
  $legacyReplayInfo.FileName = $resolvedNodePath
  $legacyReplayInfo.Arguments = '"{0}"' -f $legacyServer
  $legacyReplayInfo.WorkingDirectory = $legacySrc
  $legacyReplayInfo.UseShellExecute = $false
  $legacyReplayInfo.RedirectStandardOutput = $true
  $legacyReplayInfo.RedirectStandardError = $true
  $legacyReplayInfo.CreateNoWindow = $true
  $legacyReplayProcess = [Diagnostics.Process]::Start($legacyReplayInfo)
  if ($legacyReplayProcess.StandardOutput.ReadLine() -ne 'READY') { throw "Legacy replay fixture did not become ready. $($legacyReplayProcess.StandardError.ReadToEnd())" }
  $legacyConsumed = Get-AxStoreLifecycleStatus -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -SkipHealth
  $legacyReplayStop = Stop-AxStoreVerifiedLegacyInstance -Item $legacyItem -RuntimeRoot $legacyRuntimeRoot -Reason 'durable replay denial test' -AcknowledgedImpact -AcknowledgedLegacyTermination
  $legacyDurableReplayDenied = $legacyConsumed.state -eq 'LegacyTransitionConsumed' -and $legacyReplayStop.state -eq 'STOP_ALREADY_CLAIMED' -and -not $legacyReplayProcess.HasExited
} finally {
  if ($null -ne $legacyReplayProcess -and -not $legacyReplayProcess.HasExited) { $legacyReplayProcess.Kill(); $legacyReplayProcess.WaitForExit() }
  if ($null -ne $legacyReplayProcess) { $legacyReplayProcess.Dispose() }
  if ($null -ne $legacyProcess -and -not $legacyProcess.HasExited) { $legacyProcess.Kill(); $legacyProcess.WaitForExit() }
  if ($null -ne $legacyProcess) { $legacyProcess.Dispose() }
  & $module { $script:ControlPort=4520; $script:RuntimePort=4521 }
}
$contractProbe = Test-AxStoreLifecycleItem -Item $registrationItem
$crossRuntimeSecret = [Text.Encoding]::UTF8.GetBytes('01234567890123456789012345678901')
$crossRuntimePayload = [ordered]@{z=2;a='x';nested=[ordered]@{b=$true;a=@(1,'q')}}
$powerShellHmac = & $module { param($secret,$payload) Get-AxStoreHmac -Secret $secret -Payload $payload } $crossRuntimeSecret $crossRuntimePayload
$checks = [ordered]@{
  parsers = @($parsers|Where-Object{-not $_.valid}).Count -eq 0
  nodeNegativeTests = $nodeExit -eq 0 -and $nodeSyntaxExit -eq 0
  liveControlOwnerPreserved = [string]::Join(',',@($before['4520']|Sort-Object)) -ceq [string]::Join(',',@($after['4520']|Sort-Object))
  liveRuntimeOwnerPreserved = [string]::Join(',',@($before['4521']|Sort-Object)) -ceq [string]::Join(',',@($after['4521']|Sort-Object))
  genericForceStopDenied = $appContent -match 'Generic force-stop denied for AX Store'
  strictEvidence = $moduleContent -match 'processCreationTimeFileTimeUtc' -and $moduleContent -match 'commandLineSha256' -and $moduleContent -match 'registrationDigest' -and $moduleContent -match 'healthContractDigest' -and $moduleContent -match 'exact creation time'
  signedPipe = $brokerContent -match 'timingSafeEqual' -and $brokerContent -match 'waitForPipeAclAttestation' -and $brokerContent -match 'pipeAclDigest' -and $brokerContent -match 'STOP_REQUESTED'
  crossRuntimeCanonicalHmac = $powerShellHmac -eq '8e7dda40872c3af060e811aaafd8d84fdfa85ccfbdef0c610600670b80fa76e3'
  windowsPowerShellAclRuntime = $aclExact
  namedPipeAclExactReadback = $null -ne $pipeAclSet -and $pipeAclSet.digest -eq $pipeAclReadback.digest -and $pipeAclReadback.allowedSids.Count -eq 3
  signedRegistrationExactReadback = $registration.success -and $registration.registrationDigest -eq $registrationReadback.digest -and $registrationTamperDenied -and $registrationAliasDenied -and $registrationArtifactDriftDenied
  signedLegacyTransition = $legacyCandidate.state -eq 'LegacyTransitionCandidate' -and $legacyEligible.state -eq 'LegacyStopEligible' -and $legacyStop.success -and $legacyStop.state -eq 'STOPPED_FOR_MIGRATION' -and $legacyStop.controlPortClosed -and $legacyStop.runtimePortClosed
  legacyIdentityNegativeTests = $legacyUserSidDenied -and $legacyArgumentDenied -and $legacyArtifactDriftDenied -and $legacyPortTheftDenied -and $legacyPidReuseDenied -and $legacyRegistrationTamperDenied
  legacyReplayAndConcurrencyDenied = $legacyReplayDenied -and $legacyConcurrentStopDenied -and $legacyDurableReplayDenied
  installerRequiresExplicitRegistration = $installerContent -match 'AxStoreLauncherPath' -and $installerContent -match 'AxStoreLegacyNodePath' -and $installerContent -match 'Register-AxStoreLifecycle'
  fixedAxStoreContract = $contractProbe
  noForceKillInBroker = $brokerContent -notmatch 'taskkill|Stop-Process|\.kill\('
  noGenericForceStop = $appContent -match 'Generic force-stop denied for AX Store' -and $moduleContent -notmatch 'taskkill|Stop-Process'
  verifiedNativeLegacyTermination = $moduleContent -match 'Assert-AxStoreVerifiedProcessHandle' -and $moduleContent -match 'TerminateAndWait' -and $moduleContent -notmatch 'CloseMainWindow'
  durableLegacyTransitionClaim = $moduleContent -match 'legacyTransitionKey' -and $moduleContent -match 'transition-claim-' -and $moduleContent -match 'FileMode\]::CreateNew' -and $legacyDurableReplayDenied
  accessibleConfirmation = $appContent -match 'Reason for stopping AX Store' -and $appContent -match 'Acknowledge AX Store stop impact' -and $appContent -match 'Acknowledge guarded legacy AX Store termination' -and $appContent -match 'Outdated AX Store transition already used'
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
[pscustomobject]@{success=$failed.Count -eq 0;failedChecks=@($failed|ForEach-Object Key);checks=$checks;nodeOutput=$nodeOutput;before=$before;after=$after}|ConvertTo-Json -Depth 7
if($failed.Count -gt 0){exit 1}
