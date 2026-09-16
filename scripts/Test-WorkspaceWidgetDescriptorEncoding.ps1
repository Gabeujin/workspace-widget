#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$ProjectRoot, [string]$HostPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if ([string]::IsNullOrWhiteSpace($HostPath)) { $HostPath = Join-Path $ProjectRoot 'artifacts\build\WorkspaceWidget.exe' }
$HostPath = [IO.Path]::GetFullPath($HostPath)
if (-not (Test-Path -LiteralPath $HostPath -PathType Leaf)) { throw "A current compiled host is required: $HostPath" }

$assertions = 0
function Assert-That { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:assertions++ }

$assembly = [Reflection.Assembly]::LoadFrom($HostPath)
$nonPublicStatic = [Reflection.BindingFlags]'NonPublic,Static'
$escapeWriter = $assembly.GetType('WorkspaceWidget.Native.ManagedServiceClient', $true).GetMethod('EscapeDescriptorForAsciiWire', $nonPublicStatic)
$readDescriptor = $assembly.GetType('WorkspaceWidget.Native.ManagedServiceSupervisor', $true).GetMethod('ReadBoundedUtf8Descriptor', $nonPublicStatic)
$parseJson = $assembly.GetType('WorkspaceWidget.Native.LifecycleJson', $true).GetMethod('Parse', [Reflection.BindingFlags]'Public,Static')
Assert-That ($null -ne $escapeWriter) 'The compiled host is missing its descriptor ASCII wire writer.'
Assert-That ($null -ne $readDescriptor) 'The compiled host is missing its bounded strict UTF-8 descriptor reader.'
Assert-That ($null -ne $parseJson) 'The compiled host is missing LifecycleJson.Parse.'

function Invoke-DescriptorReader {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $stream = [IO.MemoryStream]::new()
  try {
    $stream.Write($Bytes, 0, $Bytes.Length); $stream.Position = 0
    try { return [pscustomobject]@{ success=$true; value=[string]$readDescriptor.Invoke($null, @($stream, [int]65536)) } }
    catch { return [pscustomobject]@{ success=$false; value=$null } }
  } finally { $stream.Dispose() }
}
function Assert-RejectedWire {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes, [string]$Name)
  Assert-That (-not (Invoke-DescriptorReader $Bytes).success) "$Name descriptor was accepted."
}

$koreanDirectory = [string]::Concat([char]0xD55C, [char]0xAE00, '-', [char]0xACBD, [char]0xB85C)
$koreanArgument = [string]::Concat([char]0xD55C, [char]0xAE00, '-', [char]0xC778, [char]0xC218)
$expectedPath = 'C:/' + $koreanDirectory
$rawJson = '{"pathValue":"' + $expectedPath + '","arguments":"--label ' + $koreanArgument + '"}'
$wireJson = [string]$escapeWriter.Invoke($null, @($rawJson))
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$wireBytes = $strictUtf8.GetBytes($wireJson + "`r`n")
Assert-That (@($wireBytes | Where-Object { $_ -gt 0x7F }).Count -eq 0) 'The compiled descriptor writer emitted non-ASCII wire bytes.'
Assert-That ($wireJson -match '\\uD55C\\uAE00-\\uACBD\\uB85C') 'The compiled descriptor writer did not escape the Korean path.'

function Assert-ValidWire {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes, [string]$Name)
  $read = Invoke-DescriptorReader $Bytes
  Assert-That $read.success "$Name descriptor did not decode."
  $parsed = $parseJson.Invoke($null, @($read.value))
  Assert-That ([string]$parsed['pathValue'] -ceq $expectedPath) "$Name descriptor did not round-trip the Korean path."
  Assert-That ([string]$parsed['arguments'] -ceq ('--label ' + $koreanArgument)) "$Name descriptor did not round-trip the Korean argument."
}

Assert-ValidWire -Bytes $wireBytes -Name 'UTF-8 without BOM'
$utf8Bom = [Text.UTF8Encoding]::new($true, $true)
Assert-ValidWire -Bytes ([byte[]]($utf8Bom.GetPreamble() + $wireBytes)) -Name 'UTF-8 with BOM'
$cp949 = [Text.Encoding]::GetEncoding(949)
Assert-ValidWire -Bytes ($cp949.GetBytes($wireJson + "`r`n")) -Name 'CP949 parent carrying ASCII wire'

$utf16 = [Text.UnicodeEncoding]::new($false, $true, $true)
Assert-RejectedWire -Bytes ([byte[]]($utf16.GetPreamble() + $utf16.GetBytes($wireJson + "`n"))) -Name 'UTF-16'
$utf32 = [Text.UTF32Encoding]::new($false, $true, $true)
Assert-RejectedWire -Bytes ([byte[]]($utf32.GetPreamble() + $utf32.GetBytes($wireJson + "`n"))) -Name 'UTF-32'
Assert-RejectedWire -Bytes ([byte[]](0xC3, 0x28, 0x0A)) -Name 'malformed UTF-8'

$crFlood = [byte[]]::new(65542)
for ($index = 0; $index -lt ($crFlood.Length - 1); $index++) { $crFlood[$index] = 0x0D }
$crFlood[$crFlood.Length - 1] = 0x0A
Assert-RejectedWire -Bytes $crFlood -Name 'CR flood'

$atLimit = [byte[]]::new(65537)
for ($index = 0; $index -lt 65536; $index++) { $atLimit[$index] = 0x61 }; $atLimit[65536] = 0x0A
$limitRead = Invoke-DescriptorReader $atLimit
Assert-That ($limitRead.success -and $limitRead.value.Length -eq 65536) 'The 64 KiB descriptor boundary was not accepted exactly.'
$overLimit = [byte[]]::new(65538)
for ($index = 0; $index -lt 65537; $index++) { $overLimit[$index] = 0x61 }; $overLimit[65537] = 0x0A
Assert-RejectedWire -Bytes $overLimit -Name 'over-64-KiB descriptor'

[ordered]@{ success=$true; assertions=$assertions; scope='compiled private descriptor writer/reader and JSON parser; memory streams only'; hostPath=$HostPath } | ConvertTo-Json -Compress
