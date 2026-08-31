[CmdletBinding()]
param([string]$ProjectRoot,[string]$NodePath = 'node.exe')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$modulePath = Join-Path $ProjectRoot 'app\AxStoreLifecycle.psm1'
$brokerPath = Join-Path $ProjectRoot 'app\ax-store-lifecycle-broker.js'
$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$testPath = Join-Path $ProjectRoot 'tests\ax-store-lifecycle.test.js'

$parsers = foreach ($path in @($modulePath,$appPath)) {
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
$module = Get-Module AxStoreLifecycle -ErrorAction SilentlyContinue
if ($null -eq $module) { Import-Module $modulePath -Force; $module = Get-Module AxStoreLifecycle }
$aclProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WorkspaceWidgetAxAcl-' + [guid]::NewGuid().ToString('N'))
& $module { param($path) Protect-AxStoreLifecycleDirectory -Path $path } $aclProbeRoot
$aclProbe = Get-Acl -LiteralPath $aclProbeRoot
$contractProbeItem = [pscustomobject]@{id='ax-store';target='http://127.0.0.1:4520/';health='http://127.0.0.1:4520/health';startupTarget='C:\trusted\apps\ax-store\scripts\workspace-widget-launcher.js'}
$contractProbe = Test-AxStoreLifecycleItem -Item $contractProbeItem
$crossRuntimeSecret = [Text.Encoding]::UTF8.GetBytes('01234567890123456789012345678901')
$crossRuntimePayload = [ordered]@{z=2;a='x';nested=[ordered]@{b=$true;a=@(1,'q')}}
$powerShellHmac = & $module { param($secret,$payload) Get-AxStoreHmac -Secret $secret -Payload $payload } $crossRuntimeSecret $crossRuntimePayload
$checks = [ordered]@{
  parsers = @($parsers|Where-Object{-not $_.valid}).Count -eq 0
  nodeNegativeTests = $nodeExit -eq 0
  liveControlOwnerPreserved = [string]::Join(',',@($before['4520']|Sort-Object)) -ceq [string]::Join(',',@($after['4520']|Sort-Object))
  liveRuntimeOwnerPreserved = [string]::Join(',',@($before['4521']|Sort-Object)) -ceq [string]::Join(',',@($after['4521']|Sort-Object))
  genericForceStopDenied = $appContent -match 'Generic force-stop denied for AX Store'
  strictEvidence = $moduleContent -match 'processCreationTimeUtc' -and $moduleContent -match 'commandLineSha256' -and $moduleContent -match 'launcherSha256' -and $moduleContent -match 'contractSha256' -and $moduleContent -match 'The PID was reused'
  signedPipe = $brokerContent -match 'timingSafeEqual' -and $brokerContent -match 'acknowledgedImpact' -and $brokerContent -match 'STOP_REQUESTED'
  crossRuntimeCanonicalHmac = $powerShellHmac -eq '8e7dda40872c3af060e811aaafd8d84fdfa85ccfbdef0c610600670b80fa76e3'
  windowsPowerShellAclRuntime = $aclProbe.AreAccessRulesProtected -and @($aclProbe.Access).Count -ge 3
  fixedAxStoreContract = $contractProbe
  noForceKillInBroker = $brokerContent -notmatch 'taskkill|Stop-Process|\.kill\('
  accessibleConfirmation = $appContent -match 'Reason for stopping AX Store' -and $appContent -match 'Acknowledge AX Store stop impact'
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
[pscustomobject]@{success=$failed.Count -eq 0;failedChecks=@($failed|ForEach-Object Key);checks=$checks;nodeOutput=$nodeOutput;before=$before;after=$after}|ConvertTo-Json -Depth 7
if($failed.Count -gt 0){exit 1}
