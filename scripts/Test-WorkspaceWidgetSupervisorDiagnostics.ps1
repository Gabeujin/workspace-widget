#requires -PSEdition Desktop
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$HostPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$assembly=[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($HostPath))
$client=$assembly.GetType('WorkspaceWidget.Native.ManagedServiceClient',$true)
$worker=$assembly.GetType('WorkspaceWidget.Native.ManagedServiceSupervisor',$true)
$flags=[Reflection.BindingFlags]'Static,NonPublic'
$build=$worker.GetMethod('BuildStartupDiagnostic',$flags)
$describe=$client.GetMethod('DescribeSupervisorExit',$flags)
$read=$client.GetMethod('ReadBoundedSupervisorDiagnostic',$flags)
if($null -eq $build -or $null -eq $describe -or $null -eq $read){throw 'Supervisor diagnostic methods are missing.'}
$checks=[ordered]@{}
$secret='private-path-or-command-must-never-appear'
$inner=[ComponentModel.Win32Exception]::new(5,$secret)
$wrapped=[InvalidOperationException]::new($secret,$inner)
$safe=[string]$build.Invoke($null,@('console',$wrapped))
$checks['fixedStageAndNativeCode']=$safe -ceq 'supervisor-stage=console;native-error=5'
$checks['noExceptionMessage']=$safe -notmatch [regex]::Escape($secret)
$invalid=[string]$build.Invoke($null,@($secret,$wrapped))
$checks['unknownStageSanitized']=$invalid -ceq 'supervisor-stage=unknown;native-error=5'

$stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(('x'*100000)))
try {
  $task=$read.Invoke($null,@($stream))
  $task.GetAwaiter().GetResult() | Out-Null
  $checks['captureBoundedTo4096']=$task.Result.Length -eq 4096
  $checks['remainderStillDrained']=$stream.Position -eq $stream.Length
} finally {$stream.Dispose()}

# Only this disposable process is started. No Widget, server, or user process
# is stopped; its fixed command exits immediately with the diagnostic test code.
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe'
$info.Arguments='/d /c exit 7'
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
$process=[Diagnostics.Process]::Start($info)
try {
  if(-not $process.WaitForExit(5000)){throw 'Disposable diagnostic process did not exit.'}
  $payload=[ordered]@{success=$false;state='Ambiguous';owned=$false;stoppable=$false;processId=$process.Id;error=$safe}
  $completion=[Threading.Tasks.TaskCompletionSource[string]]::new()
  $completion.SetResult(($payload|ConvertTo-Json -Compress))
  $message=[string]$describe.Invoke($null,@($process,$completion.Task))
  $checks['sanitizedExitSummary']=$message.Contains('stage=console; exitCode=7; nativeError=5')
  $checks['summaryDoesNotLeak']=$message -notmatch [regex]::Escape($secret)
  foreach($mode in @('foreignIdentity','successClaim','arbitraryOutput')) {
    $bad=[Threading.Tasks.TaskCompletionSource[string]]::new()
    if($mode -eq 'foreignIdentity'){$payload.processId=$process.Id+1}
    if($mode -eq 'successClaim'){$payload.processId=$process.Id;$payload.success=$true}
    $text=if($mode -eq 'arbitraryOutput'){$secret}else{$payload|ConvertTo-Json -Compress}
    $bad.SetResult($text)
    $message=[string]$describe.Invoke($null,@($process,$bad.Task))
    $checks[$mode+'Ignored']=$message.Contains('stage=unknown;') -and -not $message.Contains($secret)
  }
  $pending=[Threading.Tasks.TaskCompletionSource[string]]::new()
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $message=[string]$describe.Invoke($null,@($process,$pending.Task))
  $watch.Stop()
  $checks['IncompletePipeIsBounded']=$message.Contains('stage=unknown;') -and $watch.ElapsedMilliseconds -lt 2000
  $faulted=[Threading.Tasks.TaskCompletionSource[string]]::new()
  $faulted.SetException([IO.IOException]::new($secret))
  $message=[string]$describe.Invoke($null,@($process,$faulted.Task))
  $checks['FaultedPipeDoesNotLeak']=$message.Contains('stage=unknown;') -and -not $message.Contains($secret)
} finally {$process.Dispose()}
$failed=@($checks.Keys|Where-Object {-not $checks[$_]})
[pscustomobject]@{success=$failed.Count -eq 0;checkCount=$checks.Count;checks=$checks;failed=$failed}|ConvertTo-Json -Depth 4
if($failed.Count){exit 1}
