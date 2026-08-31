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
$installerPath = Join-Path $ProjectRoot 'scripts\Install-WorkspaceWidget.ps1'

$parsers = foreach ($path in @($modulePath,$appPath,$installerPath)) {
  $tokens=$null; $errors=$null
  [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
  [pscustomobject]@{path=$path;valid=$errors.Count -eq 0;errors=@($errors|ForEach-Object Message)}
}
$before = @{}
foreach ($port in @(4520,4521)) {
  $before[[string]$port] = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}
$nodeOutput = @(& $NodePath --test $testPath 2>&1)
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
$pipeProcessInfo.FileName = $NodePath
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
New-Item -ItemType Directory -Path $registrationScripts,$registrationPublic -Force | Out-Null
$registrationLauncher = Join-Path $registrationScripts 'workspace-widget-launcher.js'
$registrationContract = Join-Path $registrationPublic 'runtime-contract.json'
[IO.File]::WriteAllText($registrationLauncher,"module.exports = {};`n",[Text.UTF8Encoding]::new($false))
$registrationContractObject = [ordered]@{
  schemaVersion='ax.store/runtime-contract/v1'
  control=[ordered]@{apiVersion='test-control';healthPathBase='/api/health/contracts'}
  runtime=[ordered]@{apiVersion='test-runtime';healthPath='/health'}
  database=[ordered]@{schemaVersion=1}
  launcher=[ordered]@{leaseHost='127.0.0.1';leasePort=4519}
}
[IO.File]::WriteAllText($registrationContract,($registrationContractObject|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$registrationDescriptor = & $module { param($path) Get-AxStoreContractDescriptor -LauncherPath $path } $registrationLauncher
$registrationItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health=[string]$registrationDescriptor.controlHealthUrl;startupTarget=$registrationLauncher;startupArgs=''}
$registration = Register-AxStoreLifecycle -Item $registrationItem -RuntimeRoot $registrationRuntimeRoot -LauncherPath $registrationLauncher -ReleaseId '0.1.1-test' -ReleaseFingerprint ('f' * 64)
$registrationReadback = & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $registrationItem $registrationRuntimeRoot
$tamperedItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health='http://127.0.0.1:4520/health';startupTarget=$registrationLauncher;startupArgs=''}
$registrationTamperDenied = $false
try {
  & $module { param($item,$root) Read-AxStoreLifecycleRegistration -Item $item -RuntimeRoot $root } $tamperedItem $registrationRuntimeRoot | Out-Null
} catch { $registrationTamperDenied = $true }
$alternateProjectRoot = Join-Path $registrationRuntimeRoot 'alternate\apps\ax-store'
$alternateScripts = Join-Path $alternateProjectRoot 'scripts'
$alternatePublic = Join-Path $alternateProjectRoot 'src\public'
New-Item -ItemType Directory -Path $alternateScripts,$alternatePublic -Force | Out-Null
$alternateLauncher = Join-Path $alternateScripts 'workspace-widget-launcher.js'
$alternateContract = Join-Path $alternatePublic 'runtime-contract.json'
Copy-Item -LiteralPath $registrationLauncher -Destination $alternateLauncher
Copy-Item -LiteralPath $registrationContract -Destination $alternateContract
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
$contractProbe = Test-AxStoreLifecycleItem -Item $registrationItem
$crossRuntimeSecret = [Text.Encoding]::UTF8.GetBytes('01234567890123456789012345678901')
$crossRuntimePayload = [ordered]@{z=2;a='x';nested=[ordered]@{b=$true;a=@(1,'q')}}
$powerShellHmac = & $module { param($secret,$payload) Get-AxStoreHmac -Secret $secret -Payload $payload } $crossRuntimeSecret $crossRuntimePayload
$checks = [ordered]@{
  parsers = @($parsers|Where-Object{-not $_.valid}).Count -eq 0
  nodeNegativeTests = $nodeExit -eq 0
  liveControlOwnerPreserved = [string]::Join(',',@($before['4520']|Sort-Object)) -ceq [string]::Join(',',@($after['4520']|Sort-Object))
  liveRuntimeOwnerPreserved = [string]::Join(',',@($before['4521']|Sort-Object)) -ceq [string]::Join(',',@($after['4521']|Sort-Object))
  genericForceStopDenied = $appContent -match 'Generic force-stop denied for AX Store'
  strictEvidence = $moduleContent -match 'processCreationTimeFileTimeUtc' -and $moduleContent -match 'commandLineSha256' -and $moduleContent -match 'registrationDigest' -and $moduleContent -match 'healthContractDigest' -and $moduleContent -match 'exact creation time'
  signedPipe = $brokerContent -match 'timingSafeEqual' -and $brokerContent -match 'waitForPipeAclAttestation' -and $brokerContent -match 'pipeAclDigest' -and $brokerContent -match 'STOP_REQUESTED'
  crossRuntimeCanonicalHmac = $powerShellHmac -eq '8e7dda40872c3af060e811aaafd8d84fdfa85ccfbdef0c610600670b80fa76e3'
  windowsPowerShellAclRuntime = $aclExact
  namedPipeAclExactReadback = $null -ne $pipeAclSet -and $pipeAclSet.digest -eq $pipeAclReadback.digest -and $pipeAclReadback.allowedSids.Count -eq 3
  signedRegistrationExactReadback = $registration.success -and $registration.registrationDigest -eq $registrationReadback.digest -and $registrationTamperDenied -and $registrationAliasDenied -and $registrationArtifactDriftDenied
  installerRequiresExplicitRegistration = $installerContent -match 'AxStoreLauncherPath' -and $installerContent -match 'Register-AxStoreLifecycle'
  fixedAxStoreContract = $contractProbe
  noForceKillInBroker = $brokerContent -notmatch 'taskkill|Stop-Process|\.kill\('
  accessibleConfirmation = $appContent -match 'Reason for stopping AX Store' -and $appContent -match 'Acknowledge AX Store stop impact'
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
[pscustomobject]@{success=$failed.Count -eq 0;failedChecks=@($failed|ForEach-Object Key);checks=$checks;nodeOutput=$nodeOutput;before=$before;after=$after}|ConvertTo-Json -Depth 7
if($failed.Count -gt 0){exit 1}
