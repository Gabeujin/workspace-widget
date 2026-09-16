#requires -PSEdition Desktop
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$HostPath,
  [string]$NodePath = 'node.exe',
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)][string]$PackageHostPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$HostPath = [IO.Path]::GetFullPath($HostPath)
$PackageHostPath = [IO.Path]::GetFullPath($PackageHostPath)
$managedStopPath = Join-Path $ProjectRoot 'app\managed-stop.mjs'
$node = [IO.Path]::GetFullPath((Get-Command $NodePath -ErrorAction Stop).Source)
$packageNodeDirectory = Join-Path (Split-Path -Parent $PackageHostPath) 'runtime\node'
$packageNode = Join-Path $packageNodeDirectory 'node.exe'
$packageNpm = Join-Path $packageNodeDirectory 'npm.cmd'
foreach ($required in @($HostPath, $PackageHostPath, $managedStopPath, $node, $packageNode, $packageNpm)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required v2 lifecycle input was not found: $required"
  }
}

function Get-FreeTcpPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
  finally { $listener.Stop() }
}

function Convert-LifecycleJson {
  param([Parameter(Mandatory = $true)]$Value)
  $raw = if ($Value -is [Management.Automation.PSObject]) { $Value.BaseObject } else { $Value }
  if ($raw -is [string]) { return ([string]$raw | ConvertFrom-Json) }
  return $raw
}

function Test-HttpReady {
  param([Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 10000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    try {
      if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1).StatusCode -eq 200) {
        return $true
      }
    } catch { }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Assert-That {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

# Every fixture is rooted in a new temporary directory and intentionally retained
# for diagnostics.  It neither reads nor controls a real Widget/AX Store runtime.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('widget-v2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$servicePath = Join-Path $fixtureRoot 'two-health-fixture.mjs'
$serviceSource = @'
import http from 'node:http';
import fs from 'node:fs';

const [firstPort, secondPort, mode = 'graceful'] = process.argv.slice(2);
const ports = [firstPort, secondPort].map((value) => Number.parseInt(value, 10));
if (ports.length !== 2 || ports.some((port) => !Number.isInteger(port) || port < 1 || port > 65535)) {
  throw new Error('fixture needs exactly two valid ports');
}
if (!['graceful', 'ignore-break', 'one-health'].includes(mode)) throw new Error('fixture mode is invalid');
const ackPath = process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_PATH || '';
const ackToken = process.env.WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN || '';
let stopping = false;
const activePorts = mode === 'one-health' ? ports.slice(0, 1) : ports;
const servers = activePorts.map((port) => {
  const server = http.createServer((request, response) => {
    if (request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ ok: true, pid: process.pid, port }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  server.listen(port, '127.0.0.1');
  return server;
});
function stop() {
  if (stopping) return;
  stopping = true;
  let remaining = servers.length;
  for (const server of servers) {
    server.close(() => {
      remaining -= 1;
      if (remaining === 0) {
        if (ackPath && ackToken) fs.writeFileSync(ackPath, ackToken, { encoding: 'utf8' });
        process.exit(0);
      }
    });
  }
  setTimeout(() => process.exit(0), 1500).unref();
}
if (mode !== 'ignore-break') {
  process.on('SIGBREAK', stop);
  process.on('SIGTERM', stop);
} else {
  process.on('SIGBREAK', () => {});
  process.on('SIGTERM', () => {});
}
'@
[IO.File]::WriteAllText($servicePath, $serviceSource, [Text.UTF8Encoding]::new($false))

[Reflection.Assembly]::LoadFrom($HostPath) | Out-Null
$client = [AppDomain]::CurrentDomain.GetAssemblies() |
  ForEach-Object { $_.GetType('WorkspaceWidget.Native.ManagedServiceClient', $false) } |
  Where-Object { $null -ne $_ } | Select-Object -First 1
if ($null -eq $client) { throw 'ManagedServiceClient was unavailable in the supplied host.' }

$portA = Get-FreeTcpPort
$portB = Get-FreeTcpPort
$foreignPort = Get-FreeTcpPort
$runtimeRoot = Join-Path $fixtureRoot 'runtime'
$urls = @("http://127.0.0.1:$portA/health", "http://127.0.0.1:$portB/health") | ConvertTo-Json -Compress
$foreignUrls = @("http://127.0.0.1:$portA/health", "http://127.0.0.1:$foreignPort/health") | ConvertTo-Json -Compress
$digest = ('e' * 64)
$args = '"{0}" {1} {2}' -f $servicePath, $portA, $portB

$foreignListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $foreignPort)
try {
  $foreignListener.Start()
  $preflight = Convert-LifecycleJson ($client::StartV2(
    $HostPath, (Join-Path $fixtureRoot 'preflight-runtime'), 'preflight', ('f' * 64), $node,
    $args, $fixtureRoot, $foreignUrls, $managedStopPath, '', $fixtureRoot))
  Assert-That (-not $preflight.success -and $preflight.state -eq 'RunningUnowned') `
    'StartV2 did not reject an occupied secondary health port before launch.'
} finally {
  $foreignListener.Stop()
}

$startTask = $client::StartV2Async($HostPath, $runtimeRoot, 'two-health', $digest, $node,
  $args, $fixtureRoot, $urls, $managedStopPath, '', $fixtureRoot)
$started = Convert-LifecycleJson $startTask.GetAwaiter().GetResult()
Assert-That ($started.success -and $started.state -eq 'Owned' -and $started.allHealthOnline) `
  'StartV2Async did not prove both configured health endpoints online.'
$idempotent = Convert-LifecycleJson ($client::StartV2($HostPath, $runtimeRoot, 'two-health', $digest,
  $node, $args, $fixtureRoot, $urls, $managedStopPath, '', $fixtureRoot))
Assert-That ($idempotent.success -and $idempotent.state -eq 'Owned' -and $idempotent.allHealthOnline) `
  'A repeated v2 start did not return the authenticated owned instance.'
Assert-That ((Test-HttpReady $portA) -and (Test-HttpReady $portB)) `
  'The isolated two-health fixture did not expose both endpoints.'

$statusTask = $client::StatusV2Async($runtimeRoot, 'two-health', $digest, $urls)
$status = Convert-LifecycleJson $statusTask.GetAwaiter().GetResult()
Assert-That ($status.success -and $status.state -eq 'Owned' -and $status.allHealthOnline) `
  'StatusV2Async did not require every configured health endpoint.'

$wrongTarget = Join-Path $fixtureRoot 'other-stop.mjs'
$wrongStopSource = @'
process.stdout.write('{"action":"signal"}\n');
'@
[IO.File]::WriteAllText($wrongTarget, $wrongStopSource, [Text.UTF8Encoding]::new($false))
$mismatch = Convert-LifecycleJson ($client::StopV2($runtimeRoot, 'two-health', $digest, $urls,
  $wrongTarget, '', $false, 5000))
Assert-That (-not $mismatch.success -and $mismatch.state -eq 'Ambiguous' -and (Test-HttpReady $portA 1000)) `
  'StopV2 accepted a stop target that was not bound at startup.'

$stopTask = $client::StopV2Async($runtimeRoot, 'two-health', $digest, $urls,
  $managedStopPath, '', $false, 5000)
$stopped = Convert-LifecycleJson $stopTask.GetAwaiter().GetResult()
Assert-That ($stopped.success -and ($stopped.state -eq 'Graceful' -or $stopped.state -eq 'Stopped') -and
  $stopped.allHealthOffline) 'StopV2Async did not stop the owned job and both health ports.'
Assert-That ((-not (Test-HttpReady $portA 1000)) -and (-not (Test-HttpReady $portB 1000))) `
  'A two-health endpoint remained available after the owned v2 stop.'
$secondStop = Convert-LifecycleJson ($client::StopV2($runtimeRoot, 'two-health', $digest, $urls,
  $managedStopPath, '', $false, 5000))
Assert-That ($secondStop.success -and $secondStop.state -eq 'Stopped') `
  'A repeated v2 stop was not safely idempotent.'

$psStopPath = Join-Path $fixtureRoot 'managed-stop.ps1'
$psStopSource = @'
param([string]$Reason)
if ($Reason -cne 'bound') { exit 4 }
Write-Output '{"action":"signal"}'
'@
[IO.File]::WriteAllText($psStopPath, $psStopSource, [Text.UTF8Encoding]::new($false))
$psPortA = Get-FreeTcpPort
$psPortB = Get-FreeTcpPort
$psUrls = @("http://127.0.0.1:$psPortA/health", "http://127.0.0.1:$psPortB/health") | ConvertTo-Json -Compress
$psArgs = '-Reason bound'
$psDigest = ('d' * 64)
$psServiceArgs = '"{0}" {1} {2}' -f $servicePath, $psPortA, $psPortB
$psStarted = Convert-LifecycleJson ($client::StartV2($HostPath, (Join-Path $fixtureRoot 'powershell-runtime'),
  'two-health-powershell', $psDigest, $node, $psServiceArgs, $fixtureRoot, $psUrls,
  $psStopPath, $psArgs, $fixtureRoot))
Assert-That ($psStarted.success -and $psStarted.allHealthOnline) `
  'StartV2 did not bind the PowerShell stop script and its literal arguments.'
$psMismatch = Convert-LifecycleJson ($client::StopV2((Join-Path $fixtureRoot 'powershell-runtime'),
  'two-health-powershell', $psDigest, $psUrls, $psStopPath, '-Reason changed', $false, 5000))
Assert-That (-not $psMismatch.success -and $psMismatch.state -eq 'Ambiguous' -and (Test-HttpReady $psPortA 1000)) `
  'StopV2 accepted PowerShell arguments that did not match the startup binding.'
$psStopped = Convert-LifecycleJson ($client::StopV2((Join-Path $fixtureRoot 'powershell-runtime'),
  'two-health-powershell', $psDigest, $psUrls, $psStopPath, $psArgs, $false, 5000))
Assert-That ($psStopped.success -and $psStopped.allHealthOffline -and
  ((-not (Test-HttpReady $psPortA 1000)) -and (-not (Test-HttpReady $psPortB 1000)))) `
  'The fixed PowerShell helper did not stop only the owned two-health job.'

# A packaged `npm run start` has cmd.exe as the owned root.  The default JS
# helper must use the verified bundled Node interpreter, never assume root is Node.
$packageProject = Join-Path $fixtureRoot 'package-root-project'
New-Item -ItemType Directory -Path $packageProject -Force | Out-Null
$packagePortA = Get-FreeTcpPort
$packagePortB = Get-FreeTcpPort
$packageUrls = @("http://127.0.0.1:$packagePortA/health", "http://127.0.0.1:$packagePortB/health") | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $packageProject 'server.mjs'), $serviceSource, [Text.UTF8Encoding]::new($false))
$packageJson = '{"scripts":{"start":"node server.mjs ' + $packagePortA + ' ' + $packagePortB + '"}}'
[IO.File]::WriteAllText((Join-Path $packageProject 'package.json'), $packageJson, [Text.UTF8Encoding]::new($false))
$systemCmd = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'cmd.exe'
$packageCommand = '/d /s /c ""{0}" run "start""' -f $packageNpm
$packageRuntime = Join-Path $fixtureRoot 'package-root-runtime'
$packageDigest = ('9' * 64)
$packageStarted = Convert-LifecycleJson ($client::StartV2($PackageHostPath, $packageRuntime,
  'package-root', $packageDigest, $systemCmd, $packageCommand, $packageProject, $packageUrls,
  $managedStopPath, '', ($packageNodeDirectory + ';' + $env:Path)))
Assert-That ($packageStarted.success -and $packageStarted.allHealthOnline) `
  'StartV2 did not accept the fixed cmd/npm package launch contract.'
$packageSidecar = Get-ChildItem -LiteralPath $packageRuntime -Recurse -Filter 'v2-contract.json' |
  Select-Object -First 1
$packageConfiguration = Get-Content -LiteralPath $packageSidecar.FullName -Raw | ConvertFrom-Json
Assert-That ([IO.Path]::GetFullPath($packageConfiguration.nodeRuntime) -eq $packageNode -and
  $packageConfiguration.nodeRuntimeSha256 -eq (Get-FileHash -LiteralPath $packageNode -Algorithm SHA256).Hash.ToLowerInvariant()) `
  'The package-root v2 sidecar did not bind the exact bundled Node interpreter and hash.'
$packageStopped = Convert-LifecycleJson ($client::StopV2($packageRuntime, 'package-root', $packageDigest,
  $packageUrls, $managedStopPath, '', $false, 5000))
Assert-That ($packageStopped.success -and $packageStopped.allHealthOffline -and
  ((-not (Test-HttpReady $packagePortA 1000)) -and (-not (Test-HttpReady $packagePortB 1000)))) `
  'Default managed-stop.mjs did not stop the cmd/npm-owned package job through its bundled Node binding.'

# The same default JS helper must not rely on a Node root when a PowerShell launch
# owns the service process tree.  The packaged interpreter remains sidecar-bound.
$psRootPort = Get-FreeTcpPort
$psRootUrl = "http://127.0.0.1:$psRootPort/health"
$psRootUrls = '[' + ($psRootUrl | ConvertTo-Json -Compress) + ']'
$psRootService = Join-Path $fixtureRoot 'powershell-root-service.ps1'
$psRootServiceSource = @'
param([Parameter(Mandatory = $true)][int]$Port)
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 1024
      [void]$stream.Read($buffer, 0, $buffer.Length)
      $body = '{"ok":true}'
      $response = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($body))`r`nConnection: close`r`n`r`n$body"
      $bytes = [Text.Encoding]::UTF8.GetBytes($response)
      $stream.Write($bytes, 0, $bytes.Length)
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Close()
}
'@
[IO.File]::WriteAllText($psRootService, $psRootServiceSource, [Text.UTF8Encoding]::new($false))
$systemPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
$psRootArgs = '-NoProfile -NonInteractive -File "{0}" -Port {1}' -f $psRootService, $psRootPort
$psRootRuntime = Join-Path $fixtureRoot 'powershell-root-runtime'
$psRootDigest = ('8' * 64)
$psRootStarted = Convert-LifecycleJson ($client::StartV2($PackageHostPath, $psRootRuntime,
  'powershell-root', $psRootDigest, $systemPowerShell, $psRootArgs, $fixtureRoot, $psRootUrls,
  $managedStopPath, '', ($packageNodeDirectory + ';' + $env:Path)))
Assert-That ($psRootStarted.success -and $psRootStarted.allHealthOnline) `
  'StartV2 did not start the isolated PowerShell-root fixture.'
$psRootSidecar = Get-ChildItem -LiteralPath $psRootRuntime -Recurse -Filter 'v2-contract.json' |
  Select-Object -First 1
$psRootConfiguration = Get-Content -LiteralPath $psRootSidecar.FullName -Raw | ConvertFrom-Json
Assert-That ([IO.Path]::GetFullPath($psRootConfiguration.nodeRuntime) -eq $packageNode -and
  $psRootConfiguration.nodeRuntimeSha256 -eq (Get-FileHash -LiteralPath $packageNode -Algorithm SHA256).Hash.ToLowerInvariant()) `
  'The PowerShell-root v2 sidecar did not bind the exact bundled Node interpreter and hash.'
$psRootNeedsForce = Convert-LifecycleJson ($client::StopV2($psRootRuntime, 'powershell-root', $psRootDigest,
  $psRootUrls, $managedStopPath, '', $false, 1500))
Assert-That (-not $psRootNeedsForce.success -and $psRootNeedsForce.state -eq 'NeedsForce' -and
  (Test-HttpReady $psRootPort 1000)) `
  'Default managed-stop.mjs did not reach the owned PowerShell-root lifecycle before force was requested.'
$psRootStopped = Convert-LifecycleJson ($client::StopV2($psRootRuntime, 'powershell-root', $psRootDigest,
  $psRootUrls, $managedStopPath, '', $true, 5000))
Assert-That ($psRootStopped.success -and $psRootStopped.allHealthOffline -and
  -not (Test-HttpReady $psRootPort 1000)) `
  'Owned force-stop did not stop the PowerShell-root job after its bound default JS helper signalled it.'

$forcePortA = Get-FreeTcpPort
$forcePortB = Get-FreeTcpPort
$forceUrls = @("http://127.0.0.1:$forcePortA/health", "http://127.0.0.1:$forcePortB/health") | ConvertTo-Json -Compress
$forceRuntime = Join-Path $fixtureRoot 'force-runtime'
$forceDigest = ('c' * 64)
$forceServiceArgs = '"{0}" {1} {2} ignore-break' -f $servicePath, $forcePortA, $forcePortB
$forceStarted = Convert-LifecycleJson ($client::StartV2($HostPath, $forceRuntime, 'two-health-force',
  $forceDigest, $node, $forceServiceArgs, $fixtureRoot, $forceUrls, $managedStopPath, '', $fixtureRoot))
Assert-That ($forceStarted.success -and $forceStarted.allHealthOnline) `
  'Force fixture did not start with a complete v2 health binding.'
$needsForce = Convert-LifecycleJson ($client::StopV2($forceRuntime, 'two-health-force', $forceDigest,
  $forceUrls, $managedStopPath, '', $false, 1000))
Assert-That (-not $needsForce.success -and $needsForce.state -eq 'NeedsForce') `
  'Force fixture did not preserve the explicit graceful-before-force requirement.'
$forced = Convert-LifecycleJson ($client::StopV2($forceRuntime, 'two-health-force', $forceDigest,
  $forceUrls, $managedStopPath, '', $true, 5000))
Assert-That ($forced.success -and $forced.allHealthOffline -and
  ((-not (Test-HttpReady $forcePortA 1000)) -and (-not (Test-HttpReady $forcePortB 1000)))) `
  'The v2 sidecar binding was not preserved through the graceful timeout and owned force stop.'

$degradedPortA = Get-FreeTcpPort
$degradedPortB = Get-FreeTcpPort
$degradedUrls = @("http://127.0.0.1:$degradedPortA/health", "http://127.0.0.1:$degradedPortB/health") | ConvertTo-Json -Compress
$degradedRuntime = Join-Path $fixtureRoot 'degraded-runtime'
$degradedDigest = ('b' * 64)
$degradedArgs = '"{0}" {1} {2} one-health' -f $servicePath, $degradedPortA, $degradedPortB
$degradedStart = Convert-LifecycleJson ($client::StartV2($HostPath, $degradedRuntime, 'two-health-degraded',
  $degradedDigest, $node, $degradedArgs, $fixtureRoot, $degradedUrls, $managedStopPath, '', $fixtureRoot))
Assert-That (-not $degradedStart.success -and $degradedStart.state -eq 'OwnedDegraded' -and
  -not $degradedStart.allHealthOnline) 'StartV2 did not report a missing secondary health endpoint as owned-degraded.'
$degradedRepeat = Convert-LifecycleJson ($client::StartV2($HostPath, $degradedRuntime, 'two-health-degraded',
  $degradedDigest, $node, $degradedArgs, $fixtureRoot, $degradedUrls, $managedStopPath, '', $fixtureRoot))
Assert-That (-not $degradedRepeat.success -and $degradedRepeat.state -eq 'OwnedDegraded') `
  'A repeated start misclassified the owned-degraded instance as unowned.'
$degradedStopped = Convert-LifecycleJson ($client::StopV2($degradedRuntime, 'two-health-degraded',
  $degradedDigest, $degradedUrls, $managedStopPath, '', $false, 5000))
Assert-That ($degradedStopped.success -and $degradedStopped.allHealthOffline) `
  'StopV2 did not stop the owned-degraded instance through its bound helper.'

$missingStop = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
  $missingPort = Get-FreeTcpPort
  $missingUrl = "http://127.0.0.1:$missingPort/health"
  # PowerShell serializes a single piped item as a JSON string rather than an
  # array; the v2 API deliberately requires the latter even for one endpoint.
  $missingUrls = '[' + ($missingUrl | ConvertTo-Json -Compress) + ']'
  $missingStop = Convert-LifecycleJson ($client::StopV2((Join-Path $fixtureRoot "missing-runtime-$attempt"),
    'missing-instance', ('a' * 64), $missingUrls, $managedStopPath, '', $false, 5000))
  if ($missingStop.success -and $missingStop.state -eq 'Stopped') { break }
}
Assert-That ($missingStop.success -and $missingStop.state -eq 'Stopped') `
  "StopV2 did not report a missing, offline lifecycle as safely stopped: $($missingStop | ConvertTo-Json -Compress)"

[pscustomobject]@{
  success = $true
  fixtureRoot = $fixtureRoot
  startState = $started.state
  stopState = $stopped.state
  preflightState = $preflight.state
  healthCount = 2
  powerShellHelper = $true
  packageRootDefaultJsStop = $true
  powerShellRootDefaultJsStop = $true
  forceRetry = $true
  idempotentStartStop = $true
  ownedDegraded = $true
} | ConvertTo-Json -Compress
