#requires -PSEdition Desktop
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$HostPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$HostPath = [IO.Path]::GetFullPath($HostPath)
[Reflection.Assembly]::LoadFrom($HostPath) | Out-Null
$client = 'WorkspaceWidget.Native.ManagedServiceClient' -as [type]
$stage = Split-Path -Parent $HostPath
$runner = Join-Path $stage 'runtime\node\npm.cmd'
$systemCmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$root = Join-Path ([IO.Path]::GetTempPath()) ('WWB-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$checks = [ordered]@{}
$cases = [Collections.Generic.List[object]]::new()
$cases.Add([pscustomobject]@{name='directBatchRefused'; exe=$runner; args='run start'})
$cases.Add([pscustomobject]@{name='arbitraryCmdRefused'; exe=$systemCmd; args='/d /s /c echo forbidden'})
foreach ($character in @('&','|','<','>','^','!','(',')','%')) {
  $cases.Add([pscustomobject]@{
    name=('runnerMetacharacter-' + [int][char]$character)
    exe=$systemCmd; args=('/d /s /c ""' + $runner + $character + '" run "start""')
  })
}
$cases.Add([pscustomobject]@{
  name='scriptInjectionRefused'; exe=$systemCmd
  args=('/d /s /c ""' + $runner + '" run "start & echo forbidden""')
})
foreach ($case in $cases) {
  $result = $client::Start($HostPath, $root, $case.name, ('b' * 64), $case.exe,
    $case.args, $root, "http://127.0.0.1:$port/health", '') | ConvertFrom-Json
  $checks[$case.name] = -not [bool]$result.success -and -not [bool]$result.owned -and [int]$result.processId -eq 0
}
$tooLongRoot = Join-Path $root ('long-' + ('x' * 65))
$tooLong = $client::Start($HostPath, $tooLongRoot, 'long-path', ('c' * 64),
  (Join-Path $stage 'runtime\node\node.exe'), '--version', $root,
  "http://127.0.0.1:$port/health", '') | ConvertFrom-Json
$checks['longStatePathRefusedBeforeSpawn'] = -not [bool]$tooLong.success -and
  [int]$tooLong.processId -eq 0 -and $tooLong.error -match 'state directory is too long'
$ipv6 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Loopback, 0)
try {
  $ipv6.Server.DualMode = $false
  $ipv6.Start()
  $ipv6Port = ([Net.IPEndPoint]$ipv6.LocalEndpoint).Port
  $ipv6Result = $client::Start($HostPath, $root, 'ipv6-listener', ('d' * 64),
    (Join-Path $stage 'runtime\node\node.exe'), '--version', $root,
    "http://[::1]:$ipv6Port/health", '') | ConvertFrom-Json
  $checks['foreignIpv6ListenerNotAdopted'] = -not [bool]$ipv6Result.owned -and
    $ipv6Result.state -eq 'RunningUnowned' -and $ipv6.Server.IsBound
} finally { $ipv6.Stop() }
$nativeMethods = $client.Assembly.GetType('WorkspaceWidget.Native.NativeMethods', $true)
$binding = [Reflection.BindingFlags]'Static, NonPublic'
$sizeProbe = $nativeMethods.GetMethod('IsTcpTableSizeProbeValid', $binding)
$payloadProbe = $nativeMethods.GetMethod('IsTcpTablePayloadValid', $binding)
if ($null -eq $sizeProbe -or $null -eq $payloadProbe) { throw 'TCP observation validators were not found.' }
$checks['tcpValidSizingAccepted'] = [bool]$sizeProbe.Invoke($null, @([uint32]122, [int]4))
$checks['tcpSizingApiFailureRefused'] = -not [bool]$sizeProbe.Invoke($null, @([uint32]5, [int]128))
$checks['tcpZeroSizeRefused'] = -not [bool]$sizeProbe.Invoke($null, @([uint32]122, [int]0))
$checks['tcpOversizeRefused'] = -not [bool]$sizeProbe.Invoke($null, @([uint32]122, [int](17MB)))
$checks['tcpEmptyPayloadAccepted'] = [bool]$payloadProbe.Invoke($null, @([uint32]0, [int]4, [int]0, [int]56))
$checks['tcpPayloadApiFailureRefused'] = -not [bool]$payloadProbe.Invoke($null, @([uint32]5, [int]60, [int]1, [int]56))
$checks['tcpNegativeCountRefused'] = -not [bool]$payloadProbe.Invoke($null, @([uint32]0, [int]60, [int]-1, [int]56))
$checks['tcpOutOfBufferCountRefused'] = -not [bool]$payloadProbe.Invoke($null, @([uint32]0, [int]60, [int]2, [int]56))
$jsonType = $client.Assembly.GetType('WorkspaceWidget.Native.LifecycleJson', $true)
$downgradeProbe = $jsonType.GetMethod('IsUnsupportedProtocolDowngradeResponse', $binding)
if ($null -eq $downgradeProbe) { throw 'Protocol negotiation validator was not found.' }
$protocolInstance = 'protocol-fixture-instance'
$protocolPid = 12345
$exactRefusal = [ordered]@{
  success=$false; owned=$true; stoppable=$false; state='Ambiguous'
  instanceId=$protocolInstance; processId=$protocolPid
  error='The lifecycle protocol version is unsupported.'
}
$checks['protocolExactRefusalPermitsOneFallback'] = [bool]$downgradeProbe.Invoke(
  $null, @([string]($exactRefusal | ConvertTo-Json -Compress), [string]$protocolInstance, [int]$protocolPid))
$mutations = [ordered]@{
  success=$true; owned=$false; stoppable=$true; state='Graceful'
  instanceId='another-instance'; processId=12346
  error='The lifecycle response ended unexpectedly.'
}
foreach ($field in $mutations.Keys) {
  $altered = [ordered]@{}
  foreach ($key in $exactRefusal.Keys) { $altered[$key] = $exactRefusal[$key] }
  $altered[$field] = $mutations[$field]
  $checks['protocolAltered-' + $field + '-Refused'] = -not [bool]$downgradeProbe.Invoke(
    $null, @([string]($altered | ConvertTo-Json -Compress), [string]$protocolInstance, [int]$protocolPid))
}
foreach ($invalidResponse in @('', '{', '{}', '{"success":"false"}',
  '{"unsupportedProtocol":true}', '{"error":"timeout"}', '{"error":"capability invalid"}')) {
  $checks['protocolInvalidResponse-' + $checks.Count + '-Refused'] = -not [bool]$downgradeProbe.Invoke(
    $null, @($invalidResponse, $protocolInstance, $protocolPid))
}
$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
[ordered]@{success=$failed.Count -eq 0;checks=$checks;failedChecks=$failed;retainedEvidenceRoot=$root} | ConvertTo-Json -Depth 4
if ($failed.Count -ne 0) { exit 1 }
