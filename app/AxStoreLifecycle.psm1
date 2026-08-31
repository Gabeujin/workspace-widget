Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LifecycleSchema = 'workspace-widget/ax-store-lifecycle/v1'
$script:RegistrationSchema = 'workspace-widget/ax-store-registration/v1'
$script:PipeAclPolicyVersion = 'workspace-widget/ax-store-pipe-acl/v1'
$script:ControlPort = 4520
$script:RuntimePort = 4521

function Get-AxStoreSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AxStoreTextSha256 {
  param([Parameter(Mandatory = $true)][string]$Value)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
  } finally { $algorithm.Dispose() }
}

function Get-AxStoreByteSha256 {
  param([Parameter(Mandatory = $true)][byte[]]$Value)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($algorithm.ComputeHash($Value))).Replace('-', '').ToLowerInvariant()
  } finally { $algorithm.Dispose() }
}

function ConvertTo-AxStoreCanonicalJson {
  param($Value)
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
  if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
  if ($Value -is [datetime]) { return (($Value.ToUniversalTime().ToString('o')) | ConvertTo-Json -Compress) }
  if ($Value -is [System.Collections.IDictionary]) {
    $parts = foreach ($key in @($Value.Keys | Sort-Object)) {
      (($key.ToString() | ConvertTo-Json -Compress) + ':' + (ConvertTo-AxStoreCanonicalJson $Value[$key]))
    }
    return '{' + ($parts -join ',') + '}'
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    return '[' + (@($Value | ForEach-Object { ConvertTo-AxStoreCanonicalJson $_ }) -join ',') + ']'
  }
  if ($Value -is [psobject] -and @($Value.PSObject.Properties).Count -gt 0) {
    $table = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) { $table[$property.Name] = $property.Value }
    return ConvertTo-AxStoreCanonicalJson $table
  }
  return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-AxStoreHmac {
  param([byte[]]$Secret, $Payload)
  $hmac = [Security.Cryptography.HMACSHA256]::new($Secret)
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-AxStoreCanonicalJson $Payload))
    return ([BitConverter]::ToString($hmac.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $hmac.Dispose() }
}

function Test-AxStoreFixedTimeEquals {
  param([string]$Left, [string]$Right)
  if ($Left -notmatch '^[0-9a-f]{64}$' -or $Right -notmatch '^[0-9a-f]{64}$') { return $false }
  $difference = 0
  for ($index = 0; $index -lt $Left.Length; $index++) {
    $difference = $difference -bor ([int][char]$Left[$index] -bxor [int][char]$Right[$index])
  }
  return $difference -eq 0
}

function Get-AxStoreAllowedSids {
  return @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    'S-1-5-18',
    'S-1-5-32-544'
  )
}

function Protect-AxStoreLifecycleDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $propagation = [Security.AccessControl.PropagationFlags]::None
  $allow = [Security.AccessControl.AccessControlType]::Allow
  foreach ($sidValue in Get-AxStoreAllowedSids) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [Security.AccessControl.FileSystemRights]::FullControl,
      $inherit,
      $propagation,
      $allow
    )
    $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
  Assert-AxStoreProtectedDirectory -Path $Path
}

function Assert-AxStoreProtectedDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Protected lifecycle directories cannot be reparse points: $Path"
  }
  $acl = Get-Acl -LiteralPath $Path
  $allowedSids = @(Get-AxStoreAllowedSids)
  $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne $allowedSids[0] -or $rules.Count -ne 3) {
    throw 'Lifecycle directory ACL is not the exact protected three-principal policy.'
  }
  foreach ($rule in $rules) {
    if (
      $rule.IsInherited -or
      $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
      $rule.IdentityReference.Value -notin $allowedSids -or
      $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl
    ) { throw 'Lifecycle directory ACL contains an unexpected principal, type, or permission.' }
  }
  if (@($allowedSids | Where-Object { $_ -notin @($rules.IdentityReference.Value) }).Count -gt 0) {
    throw 'Lifecycle directory ACL is missing a required principal.'
  }
}

function Protect-AxStoreLifecycleFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $security = [Security.AccessControl.FileSecurity]::new()
  $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
  $security.SetAccessRuleProtection($true, $false)
  foreach ($sidValue in Get-AxStoreAllowedSids) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sidValue),
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
      ))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
  Assert-AxStoreProtectedFile -Path $Path
}

function Assert-AxStoreProtectedFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Protected lifecycle files cannot be reparse points: $Path" }
  $acl = Get-Acl -LiteralPath $Path
  $allowedSids = @(Get-AxStoreAllowedSids)
  $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne $allowedSids[0] -or $rules.Count -ne 3) {
    throw 'Lifecycle file ACL is not the exact protected three-principal policy.'
  }
  foreach ($rule in $rules) {
    if (
      $rule.IsInherited -or
      $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
      $rule.IdentityReference.Value -notin $allowedSids -or
      $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl
    ) { throw 'Lifecycle file ACL contains an unexpected principal, type, or permission.' }
  }
}

function Assert-AxStoreCanonicalFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
  if ($expanded -notmatch '^[A-Za-z]:\\') { throw "AX Store lifecycle paths must be local absolute paths: $expanded" }
  $full = [IO.Path]::GetFullPath($expanded)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required AX Store lifecycle artifact is missing: $full" }
  $cursor = Get-Item -LiteralPath $full -Force
  while ($null -ne $cursor) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "AX Store lifecycle paths cannot contain reparse points: $($cursor.FullName)"
    }
    $parent = Split-Path -Parent $cursor.FullName
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor.FullName) { break }
    $cursor = Get-Item -LiteralPath $parent -Force
  }
  return $full
}

function Test-AxStoreLifecycleItem {
  param($Item)
  if ($null -eq $Item) { return $false }
  if ([string]$Item.id -eq 'ax-store') { return $true }
  foreach ($property in @('target', 'health')) {
    try {
      $uri = [uri][string]$Item.$property
      if ($uri.IsLoopback -and $uri.Port -eq $script:ControlPort) { return $true }
    } catch { }
  }
  try {
    $launcher = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Item.startupTarget))
    return $launcher -match '(?i)\\apps\\ax-store\\scripts\\workspace-widget-launcher\.js$'
  } catch { return $false }
}

function Get-AxStoreLifecycleRoot {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
  return Join-Path $RuntimeRoot 'ax-store-lifecycle\instances'
}

function Get-AxStoreRegistrationPaths {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
  $root = Join-Path $RuntimeRoot 'ax-store-lifecycle\registration'
  return [pscustomobject]@{
    root = $root
    secretPath = Join-Path $root 'registration.key'
    documentPath = Join-Path $root 'registration.json'
  }
}

function Get-AxStoreContractDescriptor {
  param([Parameter(Mandatory = $true)][string]$LauncherPath)
  $launcher = Assert-AxStoreCanonicalFile -Path $LauncherPath
  if ($launcher -notmatch '(?i)\\apps\\ax-store\\scripts\\workspace-widget-launcher\.js$') {
    throw 'The AX Store launcher must use the canonical apps\ax-store\scripts path.'
  }
  $contractPath = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'src\public\runtime-contract.json'))
  $contractPath = Assert-AxStoreCanonicalFile -Path $contractPath
  $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
  if (
    [string]$contract.schemaVersion -ne 'ax.store/runtime-contract/v1' -or
    [string]$contract.launcher.leaseHost -ne '127.0.0.1' -or
    [int]$contract.launcher.leasePort -ne 4519 -or
    [string]::IsNullOrWhiteSpace([string]$contract.control.apiVersion) -or
    [string]::IsNullOrWhiteSpace([string]$contract.runtime.apiVersion) -or
    [string]$contract.control.healthPathBase -notmatch '^/[A-Za-z0-9/_-]+$' -or
    [string]$contract.runtime.healthPath -notmatch '^/[A-Za-z0-9/_-]+$' -or
    [int]$contract.database.schemaVersion -lt 1
  ) { throw 'The AX Store runtime contract does not match the pinned lifecycle schema.' }
  $contractSha256 = Get-AxStoreSha256 $contractPath
  $controlHealthUrl = 'http://127.0.0.1:4520{0}/{1}/{2}' -f (
    [string]$contract.control.healthPathBase,
    [string]$contract.control.apiVersion,
    $contractSha256
  )
  $runtimeHealthUrl = 'http://127.0.0.1:4521{0}' -f [string]$contract.runtime.healthPath
  $healthContract = [ordered]@{
    schemaVersion = [string]$contract.schemaVersion
    databaseSchemaVersion = [int]$contract.database.schemaVersion
    controlApiVersion = [string]$contract.control.apiVersion
    runtimeApiVersion = [string]$contract.runtime.apiVersion
    controlHealthUrl = $controlHealthUrl
    runtimeHealthUrl = $runtimeHealthUrl
  }
  return [pscustomobject]@{
    launcherPath = $launcher
    launcherSha256 = Get-AxStoreSha256 $launcher
    contractPath = $contractPath
    contractSha256 = $contractSha256
    controlHealthUrl = $controlHealthUrl
    runtimeHealthUrl = $runtimeHealthUrl
    healthContractDigest = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $healthContract)
  }
}

function Register-AxStoreLifecycle {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ReleaseFingerprint
  )
  if ([string]$Item.id -ne 'ax-store') { throw 'Only the fixed ax-store item can receive lifecycle registration.' }
  $descriptor = Get-AxStoreContractDescriptor -LauncherPath $LauncherPath
  if (
    [string]$Item.target -cne 'http://127.0.0.1:4520/' -or
    [string]$Item.health -cne [string]$descriptor.controlHealthUrl -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$Item.startupTarget), [string]$descriptor.launcherPath, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::IsNullOrWhiteSpace([string]$Item.startupArgs)
  ) { throw 'The ax-store state item does not exactly match the installer-selected launcher and health contract.' }
  $paths = Get-AxStoreRegistrationPaths -RuntimeRoot $RuntimeRoot
  Protect-AxStoreLifecycleDirectory -Path $paths.root
  $secret = [byte[]]::new(32)
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($secret) } finally { $random.Dispose() }
  [IO.File]::WriteAllText($paths.secretPath, [Convert]::ToBase64String($secret), [Text.UTF8Encoding]::new($false))
  Protect-AxStoreLifecycleFile -Path $paths.secretPath
  $payload = [ordered]@{
    schema = $script:RegistrationSchema
    id = 'ax-store'
    targetUrl = 'http://127.0.0.1:4520/'
    launcherPath = [string]$descriptor.launcherPath
    launcherSha256 = [string]$descriptor.launcherSha256
    contractPath = [string]$descriptor.contractPath
    contractSha256 = [string]$descriptor.contractSha256
    controlHealthUrl = [string]$descriptor.controlHealthUrl
    runtimeHealthUrl = [string]$descriptor.runtimeHealthUrl
    healthContractDigest = [string]$descriptor.healthContractDigest
    controlPort = $script:ControlPort
    runtimePort = $script:RuntimePort
    releaseId = $ReleaseId
    releaseFingerprint = $ReleaseFingerprint.ToLowerInvariant()
    issuedAt = (Get-Date).ToUniversalTime().ToString('o')
  }
  $document = [ordered]@{payload=$payload;signature=Get-AxStoreHmac -Secret $secret -Payload $payload}
  [IO.File]::WriteAllText($paths.documentPath, ($document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Protect-AxStoreLifecycleFile -Path $paths.documentPath
  Assert-AxStoreProtectedDirectory -Path $paths.root
  return [pscustomobject]@{
    success = $true
    registrationPath = $paths.documentPath
    registrationDigest = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $document)
    payload = [pscustomobject]$payload
  }
}

function Read-AxStoreLifecycleRegistration {
  param([Parameter(Mandatory = $true)]$Item,[Parameter(Mandatory = $true)][string]$RuntimeRoot)
  $paths = Get-AxStoreRegistrationPaths -RuntimeRoot $RuntimeRoot
  Assert-AxStoreProtectedDirectory -Path $paths.root
  foreach ($path in @($paths.secretPath, $paths.documentPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "AX Store lifecycle registration is missing: $path" }
    $file = Get-Item -LiteralPath $path -Force
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'AX Store lifecycle registration cannot use reparse points.' }
    if ($file.Length -gt 64KB) { throw 'AX Store lifecycle registration exceeds its size limit.' }
    Assert-AxStoreProtectedFile -Path $path
  }
  $secret = [Convert]::FromBase64String((Get-Content -LiteralPath $paths.secretPath -Raw).Trim())
  if ($secret.Length -ne 32) { throw 'AX Store lifecycle registration key length is invalid.' }
  $document = Read-AxStoreSignedDocument -Path $paths.documentPath -Secret $secret
  $payload = $document.payload
  if (
    [string]$payload.schema -ne $script:RegistrationSchema -or
    [string]$payload.id -ne 'ax-store' -or
    [int]$payload.controlPort -ne $script:ControlPort -or
    [int]$payload.runtimePort -ne $script:RuntimePort -or
    [string]$payload.releaseFingerprint -notmatch '^[0-9a-f]{64}$'
  ) { throw 'AX Store lifecycle registration identity is invalid.' }
  $descriptor = Get-AxStoreContractDescriptor -LauncherPath ([string]$payload.launcherPath)
  foreach ($property in @('launcherPath','launcherSha256','contractPath','contractSha256','controlHealthUrl','runtimeHealthUrl','healthContractDigest')) {
    if (-not [string]::Equals([string]$payload.$property, [string]$descriptor.$property, [StringComparison]::OrdinalIgnoreCase)) {
      throw "AX Store lifecycle registration no longer matches $property."
    }
  }
  if (
    [string]$Item.id -ne 'ax-store' -or
    [string]$Item.target -cne [string]$payload.targetUrl -or
    [string]$Item.health -cne [string]$payload.controlHealthUrl -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$Item.startupTarget), [string]$payload.launcherPath, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::IsNullOrWhiteSpace([string]$Item.startupArgs)
  ) { throw 'The ax-store state item does not exactly match signed lifecycle registration.' }
  return [pscustomobject]@{
    paths = $paths
    secret = $secret
    document = $document
    payload = $payload
    digest = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $document)
  }
}

function Get-AxStorePortOwners {
  $owners = @{}
  foreach ($port in @($script:ControlPort, $script:RuntimePort)) {
    $pids = @()
    try {
      $pids = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique)
    } catch {
      $lines = @(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp 2>$null)
      $pids = @($lines | Where-Object { $_ -match "^\s*TCP\s+[^\s]*:$port\s+[^\s]+\s+LISTENING\s+(\d+)\s*$" } | ForEach-Object { [int]$matches[1] } | Select-Object -Unique)
    }
    $owners[$port] = @($pids)
  }
  return $owners
}

function Read-AxStoreSignedDocument {
  param([string]$Path, [byte[]]$Secret)
  $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $expected = Get-AxStoreHmac -Secret $Secret -Payload $document.payload
  if (-not (Test-AxStoreFixedTimeEquals -Left ([string]$document.signature).ToLowerInvariant() -Right $expected)) {
    throw "Lifecycle signature verification failed: $Path"
  }
  return $document
}

function Initialize-AxStorePipeNative {
  if ('WorkspaceWidgetPipeNative' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class WorkspaceWidgetPipeNative {
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

  public static uint ReadServerProcessId(SafePipeHandle pipe) {
    uint processId;
    if (!GetNamedPipeServerProcessId(pipe, out processId)) {
      throw new Win32Exception(Marshal.GetLastWin32Error(), "GetNamedPipeServerProcessId failed.");
    }
    return processId;
  }
}
'@
}

function Get-AxStorePipeShortName {
  param([Parameter(Mandatory = $true)][string]$PipeName)
  if ($PipeName -notmatch '^\\\\\.\\pipe\\([A-Za-z0-9._-]{1,220})$') { throw 'AX Store pipe name is invalid.' }
  return $matches[1]
}

function Get-AxStorePipeAclDescriptor {
  param([Parameter(Mandatory = $true)][IO.Pipes.PipeSecurity]$Security)
  $allowedSids = @(Get-AxStoreAllowedSids)
  $owner = $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $rules = @($Security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if (-not $Security.AreAccessRulesProtected -or $owner -ne $allowedSids[0] -or $rules.Count -ne 3) {
    throw 'Named pipe DACL is not the exact protected three-principal policy.'
  }
  $tuples = @()
  foreach ($rule in $rules) {
    if (
      $rule.IsInherited -or
      $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
      $rule.IdentityReference.Value -notin $allowedSids -or
      $rule.PipeAccessRights -ne [IO.Pipes.PipeAccessRights]::FullControl
    ) { throw 'Named pipe DACL contains an unexpected principal, type, or permission.' }
    $tuples += '{0}|Allow|{1}|Explicit' -f $rule.IdentityReference.Value, [int64]$rule.PipeAccessRights
  }
  if (@($allowedSids | Where-Object { $_ -notin @($rules.IdentityReference.Value) }).Count -gt 0) {
    throw 'Named pipe DACL is missing a required principal.'
  }
  $canonical = "owner=$owner`n" + (@($tuples | Sort-Object) -join "`n")
  return [pscustomobject]@{
    policyVersion = $script:PipeAclPolicyVersion
    ownerSid = $owner
    allowedSids = $allowedSids
    digest = Get-AxStoreTextSha256 $canonical
  }
}

function Open-AxStorePipeForAcl {
  param([string]$PipeName,[IO.Pipes.PipeAccessRights]$Rights,[int]$TimeoutMilliseconds = 3000)
  Initialize-AxStorePipeNative
  $shortName = Get-AxStorePipeShortName -PipeName $PipeName
  $client = [IO.Pipes.NamedPipeClientStream]::new(
    '.',
    $shortName,
    $Rights,
    [IO.Pipes.PipeOptions]::None,
    [Security.Principal.TokenImpersonationLevel]::Identification,
    [IO.HandleInheritability]::None
  )
  try {
    $client.Connect($TimeoutMilliseconds)
    return $client
  } catch {
    $client.Dispose()
    throw
  }
}

function Get-AxStorePipeAclAttestation {
  param([Parameter(Mandatory = $true)][string]$PipeName,[Parameter(Mandatory = $true)][int]$ExpectedServerPid)
  $rights = [IO.Pipes.PipeAccessRights]::ReadPermissions -bor [IO.Pipes.PipeAccessRights]::ReadWrite
  $client = Open-AxStorePipeForAcl -PipeName $PipeName -Rights $rights
  try {
    $serverPid = [WorkspaceWidgetPipeNative]::ReadServerProcessId($client.SafePipeHandle)
    if ([int]$serverPid -ne $ExpectedServerPid) { throw 'Named pipe server PID does not match the AX Store lifecycle broker.' }
    $descriptor = Get-AxStorePipeAclDescriptor -Security $client.GetAccessControl()
    return [pscustomobject]@{
      serverPid = [int]$serverPid
      policyVersion = $descriptor.policyVersion
      ownerSid = $descriptor.ownerSid
      allowedSids = $descriptor.allowedSids
      digest = $descriptor.digest
    }
  } finally { $client.Dispose() }
}

function Set-AxStorePipeAcl {
  param([Parameter(Mandatory = $true)][string]$PipeName,[Parameter(Mandatory = $true)][int]$ExpectedServerPid)
  $client = Open-AxStorePipeForAcl -PipeName $PipeName -Rights ([IO.Pipes.PipeAccessRights]::FullControl)
  try {
    $serverPid = [WorkspaceWidgetPipeNative]::ReadServerProcessId($client.SafePipeHandle)
    if ([int]$serverPid -ne $ExpectedServerPid) { throw 'Named pipe server PID changed before DACL hardening.' }
    $security = [IO.Pipes.PipeSecurity]::new()
    $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in Get-AxStoreAllowedSids) {
      $security.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
          [Security.Principal.SecurityIdentifier]::new($sidValue),
          [IO.Pipes.PipeAccessRights]::FullControl,
          [Security.AccessControl.AccessControlType]::Allow
        ))
    }
    $client.SetAccessControl($security)
    $first = Get-AxStorePipeAclDescriptor -Security $client.GetAccessControl()
  } finally { $client.Dispose() }
  $second = Get-AxStorePipeAclAttestation -PipeName $PipeName -ExpectedServerPid $ExpectedServerPid
  if ($first.digest -ne $second.digest) { throw 'Named pipe DACL changed between independent readbacks.' }
  return $second
}

function Get-AxStoreLifecycleStatus {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [switch]$SkipHealth
  )
  $owners = Get-AxStorePortOwners
  $occupied = @($owners[$script:ControlPort]).Count -gt 0 -or @($owners[$script:RuntimePort]).Count -gt 0
  $result = [ordered]@{ state='Offline'; owned=$false; stoppable=$false; reason='AX Store is not listening.'; instance=$null; ports=$owners }
  if (-not (Test-AxStoreLifecycleItem -Item $Item)) {
    $result.state = 'NotApplicable'; $result.reason = 'This shortcut is not reserved for AX Store lifecycle.'
    return [pscustomobject]$result
  }
  try {
    $registration = Read-AxStoreLifecycleRegistration -Item $Item -RuntimeRoot $RuntimeRoot
  } catch {
    $result.state = 'RegistrationInvalid'
    $result.reason = 'AX Store lifecycle registration is missing, stale, or does not match this shortcut.'
    return [pscustomobject]$result
  }
  $instancesRoot = Get-AxStoreLifecycleRoot -RuntimeRoot $RuntimeRoot
  $candidates = if (Test-Path -LiteralPath $instancesRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $instancesRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 32)
  } else { @() }
  foreach ($directory in $candidates) {
    try {
      $secretPath = Join-Path $directory.FullName 'capability.key'
      $ownershipPath = Join-Path $directory.FullName 'ownership.json'
      if (-not (Test-Path $secretPath -PathType Leaf) -or -not (Test-Path $ownershipPath -PathType Leaf)) { continue }
      Assert-AxStoreProtectedDirectory -Path $directory.FullName
      if ((Get-Item -LiteralPath $secretPath -Force).Length -gt 256 -or (Get-Item -LiteralPath $ownershipPath -Force).Length -gt 64KB) { throw 'Lifecycle evidence exceeds its size limit.' }
      if ((Get-Item -LiteralPath $secretPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-Item -LiteralPath $ownershipPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lifecycle evidence cannot be a reparse point.' }
      $secret = [Convert]::FromBase64String((Get-Content -LiteralPath $secretPath -Raw).Trim())
      $document = Read-AxStoreSignedDocument -Path $ownershipPath -Secret $secret
      $payload = $document.payload
      if ($payload.schema -ne $script:LifecycleSchema -or [string]$payload.instanceId -ne $directory.Name) { throw 'Ownership identity is inconsistent.' }
      if ((Get-AxStoreByteSha256 $secret) -ne [string]$payload.capabilitySha256) { throw 'The lifecycle capability no longer matches its receipt.' }
      if ([string]$payload.registrationDigest -ne [string]$registration.digest) { throw 'The ownership receipt does not match signed lifecycle registration.' }
      foreach ($property in @('launcherPath','launcherSha256','contractPath','contractSha256','controlHealthUrl','runtimeHealthUrl','healthContractDigest')) {
        if (-not [string]::Equals([string]$payload.$property, [string]$registration.payload.$property, [StringComparison]::OrdinalIgnoreCase)) {
          throw "Ownership no longer matches registered $property."
        }
      }
      foreach ($artifact in @(@($payload.brokerPath,$payload.brokerSha256),@($payload.launcherPath,$payload.launcherSha256),@($payload.contractPath,$payload.contractSha256),@($payload.executablePath,$payload.executableSha256))) {
        $trustedArtifact = Assert-AxStoreCanonicalFile -Path ([string]$artifact[0])
        if ((Get-AxStoreSha256 $trustedArtifact) -ne [string]$artifact[1]) { throw 'A lifecycle artifact changed after ownership was established.' }
      }
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$payload.pid)" -ErrorAction Stop
      $creation = ([datetime]$process.CreationDate).ToUniversalTime()
      if ([int64]$payload.processCreationTimeFileTimeUtc -ne $creation.ToFileTimeUtc()) { throw 'The PID was reused or its exact creation time changed.' }
      if (-not [string]::Equals([string]$process.ExecutablePath,[string]$payload.executablePath,[StringComparison]::OrdinalIgnoreCase)) { throw 'The broker executable path changed.' }
      $commandHash = Get-AxStoreTextSha256 ([string]$process.CommandLine)
      if ($commandHash -ne [string]$payload.commandLineSha256) { throw 'The broker command line changed.' }
      if (
        @($owners[$script:ControlPort]).Count -ne 1 -or
        @($owners[$script:RuntimePort]).Count -ne 1 -or
        [int]$owners[$script:ControlPort][0] -ne [int]$payload.pid -or
        [int]$owners[$script:RuntimePort][0] -ne [int]$payload.pid
      ) { throw 'The AX Store listeners are not owned exclusively by the recorded broker PID.' }
      $pipeAcl = Get-AxStorePipeAclAttestation -PipeName ([string]$payload.pipeName) -ExpectedServerPid ([int]$payload.pid)
      if ([string]$payload.pipeAclPolicyVersion -ne $script:PipeAclPolicyVersion -or [string]$payload.pipeAclDigest -ne [string]$pipeAcl.digest) {
        throw 'The live named pipe DACL no longer matches ownership evidence.'
      }
      if (-not $SkipHealth) {
        foreach ($url in @([string]$payload.controlHealthUrl,[string]$payload.runtimeHealthUrl)) {
          $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
          if ([int]$response.StatusCode -ne 200) { throw "Health contract failed: $url" }
        }
      }
      $result.state='OwnedOnline'; $result.owned=$true; $result.stoppable=$true; $result.reason='Workspace Widget owns the registered AX Store instance and its protected control pipe.'
      $result.instance=[pscustomobject]@{root=$directory.FullName;secret=$secret;ownership=$document;payload=$payload;registration=$registration}
      return [pscustomobject]$result
    } catch { continue }
  }
  if ($occupied) {
    $result.state='RunningUnowned'; $result.reason='AX Store is running, but registration, ownership, or the live pipe DACL could not be verified.'
  }
  return [pscustomobject]$result
}

function Start-AxStoreOwnedInstance {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$BundledNodePath,
    [Parameter(Mandatory = $true)][string]$BrokerPath
  )
  if (-not (Test-AxStoreLifecycleItem $Item)) { throw 'AX Store startup is limited to the reserved ax-store shortcut.' }
  $registration = Read-AxStoreLifecycleRegistration -Item $Item -RuntimeRoot $RuntimeRoot
  $status = Get-AxStoreLifecycleStatus -Item $Item -RuntimeRoot $RuntimeRoot -SkipHealth
  if ($status.state -eq 'OwnedOnline') { return [pscustomobject]@{success=$true;state='AlreadyOwned';pid=[int]$status.instance.payload.pid} }
  if ($status.state -ne 'Offline') { return [pscustomobject]@{success=$false;state=[string]$status.state;error=$status.reason} }
  $launcherPath = [string]$registration.payload.launcherPath
  $contractPath = [string]$registration.payload.contractPath
  $bundledNode = Assert-AxStoreCanonicalFile -Path $BundledNodePath
  $broker = Assert-AxStoreCanonicalFile -Path $BrokerPath
  $instanceId = [guid]::NewGuid().ToString('N')
  $instanceRoot = Join-Path (Get-AxStoreLifecycleRoot $RuntimeRoot) $instanceId
  Protect-AxStoreLifecycleDirectory -Path $instanceRoot
  $secret = [byte[]]::new(32)
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($secret) } finally { $random.Dispose() }
  $secretPath = Join-Path $instanceRoot 'capability.key'
  [IO.File]::WriteAllText($secretPath,[Convert]::ToBase64String($secret),[Text.UTF8Encoding]::new($false))
  $pipeName = "\\.\pipe\WorkspaceWidget.AxStore.$instanceId"
  $bootstrap = [ordered]@{
    schema=$script:LifecycleSchema
    instanceId=$instanceId
    instanceRoot=$instanceRoot
    secretPath=$secretPath
    activationPath=(Join-Path $instanceRoot 'activation.json')
    ownershipPath=(Join-Path $instanceRoot 'ownership.json')
    eventsPath=(Join-Path $instanceRoot 'events.jsonl')
    pipeBoundPath=(Join-Path $instanceRoot 'pipe-bound.json')
    pipeAclPath=(Join-Path $instanceRoot 'pipe-acl.json')
    pipeName=$pipeName
    pipeAclPolicyVersion=$script:PipeAclPolicyVersion
    pipeAclAllowedSids=@(Get-AxStoreAllowedSids)
    registrationDigest=[string]$registration.digest
    launcherPath=$launcherPath
    contractPath=$contractPath
    controlHealthUrl=[string]$registration.payload.controlHealthUrl
    runtimeHealthUrl=[string]$registration.payload.runtimeHealthUrl
    healthContractDigest=[string]$registration.payload.healthContractDigest
  }
  $bootstrapPath = Join-Path $instanceRoot 'bootstrap.json'
  [IO.File]::WriteAllText($bootstrapPath,($bootstrap|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
  $arguments = '"{0}" --bootstrap "{1}"' -f $broker,$bootstrapPath
  $process = Start-Process -FilePath $bundledNode -ArgumentList $arguments -WorkingDirectory (Split-Path $broker -Parent) -WindowStyle Hidden -PassThru
  $cim = $null
  for($attempt=0;$attempt -lt 40 -and $null -eq $cim;$attempt++){ Start-Sleep -Milliseconds 50; $cim=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue }
  if ($null -eq $cim) { throw 'Could not capture the AX Store broker process identity.' }
  $creation = ([datetime]$cim.CreationDate).ToUniversalTime()
  $activation = [ordered]@{
    schema=$script:LifecycleSchema
    instanceId=$instanceId
    pid=$process.Id
    processCreationTimeUtc=$creation.ToString('o')
    processCreationTimeFileTimeUtc=$creation.ToFileTimeUtc()
    executablePath=[string]$cim.ExecutablePath
    executableSha256=Get-AxStoreSha256 ([string]$cim.ExecutablePath)
    commandLineSha256=Get-AxStoreTextSha256 ([string]$cim.CommandLine)
    brokerSha256=Get-AxStoreSha256 $broker
    launcherSha256=Get-AxStoreSha256 $launcherPath
    contractSha256=Get-AxStoreSha256 $contractPath
    registrationDigest=[string]$registration.digest
    pipeAclPolicyVersion=$script:PipeAclPolicyVersion
    pipeAclAllowedSids=@(Get-AxStoreAllowedSids)
    activatedAt=(Get-Date).ToUniversalTime().ToString('o')
  }
  $activationDocument=[ordered]@{payload=$activation;signature=Get-AxStoreHmac -Secret $secret -Payload $activation}
  [IO.File]::WriteAllText($bootstrap.activationPath,($activationDocument|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $pipeDeadline=(Get-Date).AddSeconds(10)
  while((Get-Date)-lt $pipeDeadline -and -not (Test-Path -LiteralPath $bootstrap.pipeBoundPath -PathType Leaf)){
    if($process.HasExited){return [pscustomobject]@{success=$false;state='NotOwnerOrFailed';error='AX Store broker exited before pipe hardening.'}}
    Start-Sleep -Milliseconds 50
  }
  if(-not (Test-Path -LiteralPath $bootstrap.pipeBoundPath -PathType Leaf)){
    return [pscustomobject]@{success=$false;state='PipeAclFailed';error='AX Store broker did not publish a signed pipe-bound challenge.'}
  }
  try {
    $bound = Read-AxStoreSignedDocument -Path $bootstrap.pipeBoundPath -Secret $secret
    if (
      [string]$bound.payload.schema -ne $script:LifecycleSchema -or
      [string]$bound.payload.instanceId -ne $instanceId -or
      [string]$bound.payload.pipeName -ne $pipeName -or
      [int]$bound.payload.brokerPid -ne $process.Id -or
      [string]$bound.payload.pipeAclPolicyVersion -ne $script:PipeAclPolicyVersion -or
      [string]$bound.payload.challengeNonce -notmatch '^[0-9a-f]{64}$'
    ) { throw 'Signed pipe-bound challenge identity is invalid.' }
    $pipeAcl = Set-AxStorePipeAcl -PipeName $pipeName -ExpectedServerPid $process.Id
    $attestationPayload = [ordered]@{
      schema=$script:LifecycleSchema
      instanceId=$instanceId
      pipeName=$pipeName
      brokerPid=$process.Id
      challengeNonce=[string]$bound.payload.challengeNonce
      pipeAclPolicyVersion=$script:PipeAclPolicyVersion
      pipeAclAllowedSids=@($pipeAcl.allowedSids)
      pipeAclDigest=[string]$pipeAcl.digest
      verifiedAt=(Get-Date).ToUniversalTime().ToString('o')
    }
    $attestation=[ordered]@{payload=$attestationPayload;signature=Get-AxStoreHmac -Secret $secret -Payload $attestationPayload}
    [IO.File]::WriteAllText($bootstrap.pipeAclPath,($attestation|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  } catch {
    return [pscustomobject]@{success=$false;state='PipeAclFailed';error='AX Store control pipe could not be hardened and independently verified; AX Store was not launched.'}
  }
  $deadline=(Get-Date).AddSeconds(20)
  while((Get-Date)-lt $deadline){
    if(Test-Path $bootstrap.ownershipPath -PathType Leaf){
      $verified=Get-AxStoreLifecycleStatus -Item $Item -RuntimeRoot $RuntimeRoot -SkipHealth
      if($verified.state -eq 'OwnedOnline' -and [string]$verified.instance.payload.instanceId -eq $instanceId){
        return [pscustomobject]@{success=$true;state='StartedOwned';pid=$process.Id;instanceId=$instanceId}
      }
      return [pscustomobject]@{success=$false;state='OwnershipVerificationFailed';error='AX Store ownership or its live pipe DACL failed post-start verification.'}
    }
    if($process.HasExited){return [pscustomobject]@{success=$false;state='NotOwnerOrFailed';error='AX Store was already running, stale, or startup failed. Review runtime.log and lifecycle receipts.'}}
    Start-Sleep -Milliseconds 200
  }
  return [pscustomobject]@{success=$false;state='StartupUnknown';error='AX Store broker startup did not establish ownership within 20 seconds.'}
}

function Stop-AxStoreOwnedInstance {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)]$Item,[Parameter(Mandatory = $true)][string]$RuntimeRoot,[Parameter(Mandatory = $true)][string]$Reason,[switch]$AcknowledgedImpact)
  if (-not $AcknowledgedImpact -or $Reason.Trim().Length -lt 3) { throw 'A reason and explicit impact acknowledgement are required.' }
  $status=Get-AxStoreLifecycleStatus -Item $Item -RuntimeRoot $RuntimeRoot
  if(-not $status.stoppable){return [pscustomobject]@{success=$false;state='STOP_DENIED_NOT_OWNER';error=$status.reason}}
  $instance=$status.instance; $requestId=[guid]::NewGuid().ToString('N')
  $ownershipDigest=Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $instance.ownership)
  $request=[ordered]@{schema=$script:LifecycleSchema;action='STOP';instanceId=[string]$instance.payload.instanceId;requestId=$requestId;ownershipDigest=$ownershipDigest;registrationDigest=[string]$instance.registration.digest;reason=$Reason.Trim();acknowledgedImpact=$true;requestedAt=(Get-Date).ToUniversalTime().ToString('o')}
  $document=[ordered]@{payload=$request;signature=Get-AxStoreHmac -Secret $instance.secret -Payload $request}
  $pipeName=([string]$instance.payload.pipeName) -replace '^\\\\\.\\pipe\\',''
  $client=[IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
  try {
    $client.Connect(5000)
    $writer=[IO.StreamWriter]::new($client,[Text.UTF8Encoding]::new($false),1024,$true); $writer.WriteLine(($document|ConvertTo-Json -Depth 7 -Compress)); $writer.Flush(); $client.WaitForPipeDrain(); $client.Dispose()
  } finally { if($null -ne $client){$client.Dispose()} }
  $receiptPath=Join-Path $instance.root "stop-completed-$requestId.json"
  $deadline=(Get-Date).AddSeconds(18)
  while((Get-Date)-lt $deadline -and -not (Test-Path $receiptPath -PathType Leaf)){Start-Sleep -Milliseconds 200}
  if(-not (Test-Path $receiptPath -PathType Leaf)){return [pscustomobject]@{success=$false;state='STOP_UNKNOWN';error='No signed completion receipt arrived; no force-stop was attempted.'}}
  $receipt=Read-AxStoreSignedDocument -Path $receiptPath -Secret $instance.secret
  if (
    [string]$receipt.payload.schema -ne $script:LifecycleSchema -or
    [string]$receipt.payload.instanceId -ne [string]$instance.payload.instanceId -or
    [string]$receipt.payload.requestId -ne $requestId
  ) { throw 'The AX Store completion receipt identity is inconsistent.' }
  $ports=Get-AxStorePortOwners
  $closed=@($ports[$script:ControlPort]).Count -eq 0 -and @($ports[$script:RuntimePort]).Count -eq 0
  return [pscustomobject]@{success=([string]$receipt.payload.status -eq 'STOPPED' -and $closed);state=[string]$receipt.payload.status;controlPortClosed=@($ports[$script:ControlPort]).Count -eq 0;runtimePortClosed=@($ports[$script:RuntimePort]).Count -eq 0;receiptPath=$receiptPath}
}

Export-ModuleMember -Function Get-AxStoreLifecycleStatus,Register-AxStoreLifecycle,Start-AxStoreOwnedInstance,Stop-AxStoreOwnedInstance,Test-AxStoreLifecycleItem
