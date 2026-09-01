Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LifecycleSchema = 'workspace-widget/ax-store-lifecycle/v1'
$script:RegistrationSchema = 'workspace-widget/ax-store-registration/v2'
$script:PipeAclPolicyVersion = 'workspace-widget/ax-store-pipe-acl/v1'
$script:LegacyTransitionSchema = 'workspace-widget/ax-store-legacy-transition/v1'
$script:LegacyTransitionMutex = 'Local\WorkspaceWidget.AxStore.LegacyTransition.v1'
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
  param(
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$BundledNodePath,
    [string]$LegacyNodePath
  )
  $launcher = Assert-AxStoreCanonicalFile -Path $LauncherPath
  if ($launcher -notmatch '(?i)\\apps\\ax-store\\scripts\\workspace-widget-launcher\.js$') {
    throw 'The AX Store launcher must use the canonical apps\ax-store\scripts path.'
  }
  $contractPath = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'src\public\runtime-contract.json'))
  $contractPath = Assert-AxStoreCanonicalFile -Path $contractPath
  $serverPath = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'src\server.js'))
  $serverPath = Assert-AxStoreCanonicalFile -Path $serverPath
  $bundledNode = Assert-AxStoreCanonicalFile -Path $BundledNodePath
  if ([IO.Path]::GetExtension($bundledNode) -ine '.exe' -or [IO.Path]::GetFileName($bundledNode) -ine 'node.exe') {
    throw 'The AX Store bundled runtime must be an exact node.exe file.'
  }
  $legacyNode = $null
  if (-not [string]::IsNullOrWhiteSpace($LegacyNodePath)) {
    $legacyNode = Assert-AxStoreCanonicalFile -Path $LegacyNodePath
    if ([IO.Path]::GetFileName($legacyNode) -ine 'node.exe') {
      throw 'The AX Store legacy transition runtime must be an exact node.exe file.'
    }
  }
  $launcherSha256 = Get-AxStoreSha256 $launcher
  $serverSha256 = Get-AxStoreSha256 $serverPath
  $bundledNodeSha256 = Get-AxStoreSha256 $bundledNode
  $legacyNodeSha256 = $(if ($null -eq $legacyNode) { '' } else { Get-AxStoreSha256 $legacyNode })
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
  $legacyTransitionKey = ''
  if ($null -ne $legacyNode) {
    $legacyTransitionKey = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson ([ordered]@{
      schema = $script:LegacyTransitionSchema
      legacyNodePath = $legacyNode
      legacyNodeSha256 = $legacyNodeSha256
      serverPath = $serverPath
      serverSha256 = $serverSha256
      contractPath = $contractPath
      contractSha256 = $contractSha256
      userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      controlPort = $script:ControlPort
      runtimePort = $script:RuntimePort
    }))
  }
  return [pscustomobject]@{
    launcherPath = $launcher
    launcherSha256 = $launcherSha256
    serverPath = $serverPath
    serverSha256 = $serverSha256
    contractPath = $contractPath
    contractSha256 = $contractSha256
    bundledNodePath = $bundledNode
    bundledNodeSha256 = $bundledNodeSha256
    legacyNodePath = $(if ($null -eq $legacyNode) { '' } else { $legacyNode })
    legacyNodeSha256 = $legacyNodeSha256
    legacyTransitionKey = $legacyTransitionKey
    userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    controlHealthUrl = $controlHealthUrl
    runtimeHealthUrl = $runtimeHealthUrl
    legacyControlHealthUrl = "http://127.0.0.1:$($script:ControlPort)/health"
    legacyRuntimeHealthUrl = "http://127.0.0.1:$($script:RuntimePort)/health"
    runtimeContractUrl = "http://127.0.0.1:$($script:ControlPort)/runtime-contract.json"
    healthContractDigest = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $healthContract)
  }
}

function Register-AxStoreLifecycle {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$BundledNodePath,
    [string]$LegacyNodePath,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ReleaseFingerprint
  )
  if ([string]$Item.id -ne 'ax-store') { throw 'Only the fixed ax-store item can receive lifecycle registration.' }
  $descriptor = Get-AxStoreContractDescriptor -LauncherPath $LauncherPath -BundledNodePath $BundledNodePath -LegacyNodePath $LegacyNodePath
  if (
    [string]$Item.target -cne "http://127.0.0.1:$($script:ControlPort)/" -or
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
    targetUrl = "http://127.0.0.1:$($script:ControlPort)/"
    launcherPath = [string]$descriptor.launcherPath
    launcherSha256 = [string]$descriptor.launcherSha256
    serverPath = [string]$descriptor.serverPath
    serverSha256 = [string]$descriptor.serverSha256
    contractPath = [string]$descriptor.contractPath
    contractSha256 = [string]$descriptor.contractSha256
    bundledNodePath = [string]$descriptor.bundledNodePath
    bundledNodeSha256 = [string]$descriptor.bundledNodeSha256
    legacyNodePath = [string]$descriptor.legacyNodePath
    legacyNodeSha256 = [string]$descriptor.legacyNodeSha256
    legacyTransitionKey = [string]$descriptor.legacyTransitionKey
    userSid = [string]$descriptor.userSid
    controlHealthUrl = [string]$descriptor.controlHealthUrl
    runtimeHealthUrl = [string]$descriptor.runtimeHealthUrl
    legacyControlHealthUrl = [string]$descriptor.legacyControlHealthUrl
    legacyRuntimeHealthUrl = [string]$descriptor.legacyRuntimeHealthUrl
    runtimeContractUrl = [string]$descriptor.runtimeContractUrl
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
  $descriptor = Get-AxStoreContractDescriptor -LauncherPath ([string]$payload.launcherPath) -BundledNodePath ([string]$payload.bundledNodePath) -LegacyNodePath ([string]$payload.legacyNodePath)
  foreach ($property in @('launcherPath','launcherSha256','serverPath','serverSha256','contractPath','contractSha256','bundledNodePath','bundledNodeSha256','legacyNodePath','legacyNodeSha256','legacyTransitionKey','userSid','controlHealthUrl','runtimeHealthUrl','legacyControlHealthUrl','legacyRuntimeHealthUrl','runtimeContractUrl','healthContractDigest')) {
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

function Initialize-AxStoreCommandLineNative {
  if ($null -ne ('WorkspaceWidget.AxStoreCommandLine.Native' -as [type])) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WorkspaceWidget.AxStoreCommandLine {
  public static class Native {
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(
      [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
      out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Parse(string commandLine) {
      int count;
      IntPtr arguments = CommandLineToArgvW(commandLine, out count);
      if (arguments == IntPtr.Zero) {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      }
      try {
        var values = new List<string>(count);
        for (int index = 0; index < count; index++) {
          IntPtr value = Marshal.ReadIntPtr(arguments, index * IntPtr.Size);
          values.Add(Marshal.PtrToStringUni(value));
        }
        return values.ToArray();
      } finally {
        LocalFree(arguments);
      }
    }
  }
}
'@
}

function Get-AxStoreCommandLineArguments {
  param([Parameter(Mandatory = $true)][string]$CommandLine)
  Initialize-AxStoreCommandLineNative
  return @([WorkspaceWidget.AxStoreCommandLine.Native]::Parse($CommandLine))
}

function Initialize-AxStoreVerifiedProcessNative {
  if ($null -ne ('WorkspaceWidget.AxStoreProcess.VerifiedProcess' -as [type])) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace WorkspaceWidget.AxStoreProcess {
  public sealed class VerifiedProcess : IDisposable {
    private const uint ProcessTerminate = 0x0001;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint Synchronize = 0x00100000;
    private const uint TokenQuery = 0x0008;
    private const int TokenUser = 1;
    private const uint WaitObject0 = 0;
    private const uint WaitTimeout = 258;
    private IntPtr handle;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime { public uint Low; public uint High; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr value);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr value, uint milliseconds);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr information, int length, out int returnLength);

    public int ProcessId { get; private set; }
    public long CreationTimeFileTimeUtc { get; private set; }
    public string ImagePath { get; private set; }
    public string UserSid { get; private set; }

    public static VerifiedProcess Open(int processId) { return new VerifiedProcess(processId, true); }
    public static VerifiedProcess OpenQuery(int processId) { return new VerifiedProcess(processId, false); }

    private VerifiedProcess(int processId, bool allowTerminate) {
      uint access = ProcessQueryLimitedInformation | Synchronize;
      if (allowTerminate) access |= ProcessTerminate;
      handle = OpenProcess(access, false, processId);
      if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        ProcessId = checked((int)GetProcessId(handle));
        if (ProcessId == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        FileTime creation, exit, kernel, user;
        if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
        CreationTimeFileTimeUtc = unchecked((long)(((ulong)creation.High << 32) | creation.Low));
        var image = new StringBuilder(32768);
        uint imageLength = checked((uint)image.Capacity);
        if (!QueryFullProcessImageName(handle, 0, image, ref imageLength)) throw new Win32Exception(Marshal.GetLastWin32Error());
        ImagePath = image.ToString();
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(handle, TokenQuery, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
          int needed;
          GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out needed);
          if (needed <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
          IntPtr buffer = Marshal.AllocHGlobal(needed);
          try {
            if (!GetTokenInformation(token, TokenUser, buffer, needed, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr sid = Marshal.ReadIntPtr(buffer);
            UserSid = new SecurityIdentifier(sid).Value;
          } finally { Marshal.FreeHGlobal(buffer); }
        } finally { CloseHandle(token); }
      } catch {
        Dispose();
        throw;
      }
    }

    public bool HasExited() {
      EnsureOpen();
      uint result = WaitForSingleObject(handle, 0);
      if (result == WaitObject0) return true;
      if (result == WaitTimeout) return false;
      throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public bool TerminateAndWait(uint milliseconds) {
      EnsureOpen();
      if (!HasExited() && !TerminateProcess(handle, 0x57574D47)) throw new Win32Exception(Marshal.GetLastWin32Error());
      uint result = WaitForSingleObject(handle, milliseconds);
      if (result == WaitObject0) return true;
      if (result == WaitTimeout) return false;
      throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private void EnsureOpen() {
      if (handle == IntPtr.Zero) throw new ObjectDisposedException("VerifiedProcess");
    }

    public void Dispose() {
      if (handle != IntPtr.Zero) {
        CloseHandle(handle);
        handle = IntPtr.Zero;
      }
      GC.SuppressFinalize(this);
    }

    ~VerifiedProcess() { Dispose(); }
  }
}
'@
}

function Open-AxStoreVerifiedProcessHandle {
  param([Parameter(Mandatory = $true)][int]$ProcessId)
  Initialize-AxStoreVerifiedProcessNative
  return [WorkspaceWidget.AxStoreProcess.VerifiedProcess]::Open($ProcessId)
}

function Assert-AxStoreVerifiedProcessHandle {
  param(
    [Parameter(Mandatory = $true)]$Handle,
    [Parameter(Mandatory = $true)]$BaselineEvidence,
    [Parameter(Mandatory = $true)]$Registration
  )
  if ([int]$Handle.ProcessId -ne [int]$BaselineEvidence.process.processId) {
    throw 'The native AX Store process handle PID does not match the signed baseline identity.'
  }
  if ([int64]$Handle.CreationTimeFileTimeUtc -ne [int64]$BaselineEvidence.process.creationTimeFileTimeUtc) {
    throw 'The native AX Store process handle creation FILETIME does not match the signed baseline identity.'
  }
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Handle.ImagePath),[string]$Registration.payload.legacyNodePath,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The native AX Store process handle image path does not match signed registration.'
  }
  if ([string]$Handle.UserSid -cne [string]$Registration.payload.userSid) {
    throw 'The native AX Store process token SID does not match signed registration.'
  }
  if ((Get-AxStoreSha256 ([string]$Handle.ImagePath)) -ne [string]$Registration.payload.legacyNodeSha256) {
    throw 'The native AX Store process handle image hash does not match signed registration.'
  }
}

function Get-AxStoreProcessIdentity {
  param([Parameter(Mandatory = $true)][int]$ProcessId)
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
  Initialize-AxStoreVerifiedProcessNative
  $queryHandle = [WorkspaceWidget.AxStoreProcess.VerifiedProcess]::OpenQuery($ProcessId)
  try {
    $creationFileTimeUtc = [int64]$queryHandle.CreationTimeFileTimeUtc
    $executablePath = [string]$queryHandle.ImagePath
    $userSid = [string]$queryHandle.UserSid
  } finally {
    $queryHandle.Dispose()
  }
  return [pscustomobject]@{
    processId = [int]$process.ProcessId
    creationTimeUtc = [datetime]::FromFileTimeUtc($creationFileTimeUtc).ToString('o')
    creationTimeFileTimeUtc = $creationFileTimeUtc
    executablePath = $executablePath
    commandLine = [string]$process.CommandLine
    commandLineSha256 = Get-AxStoreTextSha256 ([string]$process.CommandLine)
    userSid = $userSid
  }
}

function Test-AxStoreLegacyIdentitySnapshot {
  param(
    [Parameter(Mandatory = $true)]$Registration,
    [Parameter(Mandatory = $true)]$Owners,
    [Parameter(Mandatory = $true)]$ProcessIdentity
  )
  $payload = $Registration.payload
  if ([string]::IsNullOrWhiteSpace([string]$payload.legacyNodePath)) {
    throw 'Signed registration does not authorize a one-time legacy runtime transition.'
  }
  $controlOwners = @($Owners[$script:ControlPort])
  $runtimeOwners = @($Owners[$script:RuntimePort])
  if (
    $controlOwners.Count -ne 1 -or
    $runtimeOwners.Count -ne 1 -or
    [int]$controlOwners[0] -ne [int]$runtimeOwners[0] -or
    [int]$controlOwners[0] -ne [int]$ProcessIdentity.processId
  ) { throw 'Both AX Store listeners must be owned exclusively by the same verified process.' }
  $legacyNode = Assert-AxStoreCanonicalFile -Path ([string]$payload.legacyNodePath)
  $serverPath = Assert-AxStoreCanonicalFile -Path ([string]$payload.serverPath)
  foreach ($artifact in @(
      @($legacyNode,[string]$payload.legacyNodeSha256),
      @($serverPath,[string]$payload.serverSha256),
      @([string]$payload.launcherPath,[string]$payload.launcherSha256),
      @([string]$payload.contractPath,[string]$payload.contractSha256)
    )) {
    $trustedArtifact = Assert-AxStoreCanonicalFile -Path ([string]$artifact[0])
    if ((Get-AxStoreSha256 $trustedArtifact) -ne [string]$artifact[1]) {
      throw 'A registered AX Store legacy-transition artifact changed.'
    }
  }
  if (
    -not [string]::Equals([string]$ProcessIdentity.executablePath,$legacyNode,[StringComparison]::OrdinalIgnoreCase) -or
    [string]$ProcessIdentity.userSid -cne [string]$payload.userSid -or
    [string]$ProcessIdentity.userSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  ) { throw 'The legacy AX Store executable or user identity does not match signed registration.' }
  $arguments = @(Get-AxStoreCommandLineArguments -CommandLine ([string]$ProcessIdentity.commandLine))
  if (
    $arguments.Count -ne 2 -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$arguments[0]),$legacyNode,[StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$arguments[1]),$serverPath,[StringComparison]::OrdinalIgnoreCase)
  ) { throw 'The legacy AX Store command line contains an unregistered executable, entrypoint, or argument.' }
  $identityPayload = [ordered]@{
    processId = [int]$ProcessIdentity.processId
    creationTimeFileTimeUtc = [int64]$ProcessIdentity.creationTimeFileTimeUtc
    executablePath = $legacyNode
    executableSha256 = [string]$payload.legacyNodeSha256
    serverPath = $serverPath
    serverSha256 = [string]$payload.serverSha256
    commandLineSha256 = [string]$ProcessIdentity.commandLineSha256
    userSid = [string]$ProcessIdentity.userSid
    controlPort = $script:ControlPort
    runtimePort = $script:RuntimePort
    registrationDigest = [string]$Registration.digest
  }
  return [pscustomobject]@{
    processId = [int]$ProcessIdentity.processId
    processCreationTimeFileTimeUtc = [int64]$ProcessIdentity.creationTimeFileTimeUtc
    commandLineSha256 = [string]$ProcessIdentity.commandLineSha256
    identityDigest = Get-AxStoreTextSha256 (ConvertTo-AxStoreCanonicalJson $identityPayload)
    payload = [pscustomobject]$identityPayload
  }
}

function Get-AxStoreLegacyTransitionEvidence {
  param(
    [Parameter(Mandatory = $true)]$Registration,
    [Parameter(Mandatory = $true)]$Owners,
    [switch]$SkipHealth
  )
  $controlOwners = @($Owners[$script:ControlPort])
  $runtimeOwners = @($Owners[$script:RuntimePort])
  if ($controlOwners.Count -ne 1 -or $runtimeOwners.Count -ne 1 -or [int]$controlOwners[0] -ne [int]$runtimeOwners[0]) {
    throw 'Legacy transition requires the same exclusive PID on both AX Store ports.'
  }
  $processIdentity = Get-AxStoreProcessIdentity -ProcessId ([int]$controlOwners[0])
  $identity = Test-AxStoreLegacyIdentitySnapshot -Registration $Registration -Owners $Owners -ProcessIdentity $processIdentity
  if (-not $SkipHealth) {
    $controlResponse = Invoke-WebRequest -Uri ([string]$Registration.payload.legacyControlHealthUrl) -UseBasicParsing -TimeoutSec 3
    $runtimeResponse = Invoke-WebRequest -Uri ([string]$Registration.payload.legacyRuntimeHealthUrl) -UseBasicParsing -TimeoutSec 3
    $contractResponse = Invoke-WebRequest -Uri ([string]$Registration.payload.runtimeContractUrl) -UseBasicParsing -TimeoutSec 3
    $controlHealth = $controlResponse.Content | ConvertFrom-Json
    $runtimeHealth = $runtimeResponse.Content | ConvertFrom-Json
    if (
      [int]$controlResponse.StatusCode -ne 200 -or
      [int]$runtimeResponse.StatusCode -ne 200 -or
      [int]$contractResponse.StatusCode -ne 200 -or
      $controlHealth.ok -ne $true -or [string]$controlHealth.status -ne 'ready' -or [string]$controlHealth.service -ne 'ax-store-control' -or
      $runtimeHealth.ok -ne $true -or [string]$runtimeHealth.status -ne 'ready' -or [string]$runtimeHealth.service -ne 'ax-store-runtime' -or
      (Get-AxStoreTextSha256 ([string]$contractResponse.Content)) -ne [string]$Registration.payload.contractSha256
    ) { throw 'The legacy AX Store health and runtime-contract evidence did not match signed registration.' }
  }
  return [pscustomobject]@{
    identity = $identity
    process = $processIdentity
    healthVerified = -not $SkipHealth
  }
}

function Get-AxStoreLegacyTransitionPaths {
  param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)]$Registration
  )
  $transitionKey = [string]$Registration.payload.legacyTransitionKey
  if ($transitionKey -notmatch '^[0-9a-f]{64}$') {
    throw 'The signed legacy transition key is invalid.'
  }
  $root = Join-Path $RuntimeRoot 'ax-store-lifecycle\legacy-transitions'
  return [pscustomobject]@{
    root=$root
    claimPath=(Join-Path $root "transition-claim-$transitionKey.json")
    transitionKey=$transitionKey
  }
}

function Assert-AxStoreLegacyIdentityContinuity {
  param(
    [Parameter(Mandatory = $true)]$BaselineEvidence,
    [Parameter(Mandatory = $true)]$FreshProcess,
    [Parameter(Mandatory = $true)]$FreshIdentity
  )
  if (
    [int]$FreshProcess.processId -ne [int]$BaselineEvidence.process.processId -or
    [int64]$FreshProcess.creationTimeFileTimeUtc -ne [int64]$BaselineEvidence.process.creationTimeFileTimeUtc -or
    [string]$FreshIdentity.identityDigest -cne [string]$BaselineEvidence.identity.identityDigest
  ) { throw 'Legacy AX Store identity changed after confirmation; guarded termination was refused.' }
}

function Write-AxStoreSignedDocumentExclusive {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][byte[]]$Secret,
    [Parameter(Mandatory = $true)]$Payload
  )
  $document = [ordered]@{payload=$Payload;signature=Get-AxStoreHmac -Secret $Secret -Payload $Payload}
  $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
    $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),4096,$true)
    try { $writer.Write(($document | ConvertTo-Json -Depth 10)); $writer.Flush(); $stream.Flush($true) } finally { $writer.Dispose() }
  } finally { $stream.Dispose() }
  Protect-AxStoreLifecycleFile -Path $Path
  return [pscustomobject]$document
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
  $result = [ordered]@{ state='Offline'; owned=$false; stoppable=$false; legacyTransitionAvailable=$false; reason='AX Store is not listening.'; instance=$null; legacy=$null; ports=$owners }
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
      foreach ($property in @('launcherPath','launcherSha256','serverPath','serverSha256','contractPath','contractSha256','bundledNodePath','bundledNodeSha256','userSid','controlHealthUrl','runtimeHealthUrl','healthContractDigest')) {
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
      if (
        -not [string]::Equals([string]$payload.executablePath,[string]$registration.payload.bundledNodePath,[StringComparison]::OrdinalIgnoreCase) -or
        [string]$payload.executableSha256 -ne [string]$registration.payload.bundledNodeSha256
      ) { throw 'The broker runtime no longer matches the installer-pinned bundled Node runtime.' }
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
    try {
      $legacy = Get-AxStoreLegacyTransitionEvidence -Registration $registration -Owners $owners -SkipHealth:$SkipHealth
      $legacyPaths = Get-AxStoreLegacyTransitionPaths -RuntimeRoot $RuntimeRoot -Registration $registration
      if (Test-Path -LiteralPath $legacyPaths.claimPath) {
        $result.state='LegacyTransitionConsumed'
        $result.reason='The one-time transition for this exact legacy AX Store runtime was already claimed; automatic retry is disabled.'
        $result.legacy=$legacy
        return [pscustomobject]$result
      }
      $result.state=$(if($SkipHealth){'LegacyTransitionCandidate'}else{'LegacyStopEligible'})
      $result.reason='A signed, exact-identity one-time transition is available for the pre-broker AX Store process.'
      $result.legacyTransitionAvailable=$true
      $result.legacy=$legacy
      return [pscustomobject]$result
    } catch {
      $result.state='RunningUnowned'; $result.reason='AX Store is running, but signed ownership or exact legacy-transition identity could not be verified.'
    }
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
  if (
    -not [string]::Equals($bundledNode,[string]$registration.payload.bundledNodePath,[StringComparison]::OrdinalIgnoreCase) -or
    (Get-AxStoreSha256 $bundledNode) -ne [string]$registration.payload.bundledNodeSha256
  ) { throw 'The requested bundled Node runtime does not match signed AX Store registration.' }
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

function Stop-AxStoreVerifiedLegacyInstance {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Item,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$Reason,
    [switch]$AcknowledgedImpact,
    [switch]$AcknowledgedLegacyTermination
  )
  if (-not $AcknowledgedImpact -or -not $AcknowledgedLegacyTermination -or $Reason.Trim().Length -lt 3) {
    throw 'A reason and both explicit impact and legacy-termination acknowledgements are required.'
  }
  $mutex = [Threading.Mutex]::new($false,$script:LegacyTransitionMutex)
  $acquired = $false
  $registration = $null
  $evidence = $null
  $requestId = $null
  $completionPath = $null
  $requestWritten = $false
  try {
    $acquired = $mutex.WaitOne(0)
    if (-not $acquired) {
      return [pscustomobject]@{success=$false;state='STOP_ALREADY_IN_PROGRESS';error='Another AX Store legacy transition is already running.'}
    }
    $registration = Read-AxStoreLifecycleRegistration -Item $Item -RuntimeRoot $RuntimeRoot
    $owners = Get-AxStorePortOwners
    $evidence = Get-AxStoreLegacyTransitionEvidence -Registration $registration -Owners $owners
    $requestId = [guid]::NewGuid().ToString('N')
    $paths = Get-AxStoreLegacyTransitionPaths -RuntimeRoot $RuntimeRoot -Registration $registration
    Protect-AxStoreLifecycleDirectory -Path $paths.root
    $requestPath = $paths.claimPath
    $completionPath = Join-Path $paths.root "transition-completed-$requestId.json"
    $requestPayload = [ordered]@{
      schema = $script:LegacyTransitionSchema
      action = 'STOP_LEGACY_ONCE'
      requestId = $requestId
      identityDigest = [string]$evidence.identity.identityDigest
      registrationDigest = [string]$registration.digest
      transitionKey = [string]$paths.transitionKey
      processId = [int]$evidence.process.processId
      processCreationTimeFileTimeUtc = [int64]$evidence.process.creationTimeFileTimeUtc
      reason = $Reason.Trim()
      acknowledgedImpact = $true
      acknowledgedLegacyTermination = $true
      requestedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
      Write-AxStoreSignedDocumentExclusive -Path $requestPath -Secret $registration.secret -Payload $requestPayload | Out-Null
    } catch [IO.IOException] {
      return [pscustomobject]@{success=$false;state='STOP_ALREADY_CLAIMED';error='The one-time transition for this exact legacy runtime was already claimed.';requestPath=$requestPath}
    }
    $requestWritten = $true

    $verifiedHandle = $null
    $forcedMigrationTermination = $false
    try {
      $verifiedHandle = Open-AxStoreVerifiedProcessHandle -ProcessId ([int]$evidence.process.processId)
      Assert-AxStoreVerifiedProcessHandle -Handle $verifiedHandle -BaselineEvidence $evidence -Registration $registration
      $freshOwners = Get-AxStorePortOwners
      $freshProcess = Get-AxStoreProcessIdentity -ProcessId ([int]$evidence.process.processId)
      $freshIdentity = Test-AxStoreLegacyIdentitySnapshot -Registration $registration -Owners $freshOwners -ProcessIdentity $freshProcess
      Assert-AxStoreLegacyIdentityContinuity -BaselineEvidence $evidence -FreshProcess $freshProcess -FreshIdentity $freshIdentity
      Assert-AxStoreVerifiedProcessHandle -Handle $verifiedHandle -BaselineEvidence $evidence -Registration $registration
      $forcedMigrationTermination = $true
      $terminated = $verifiedHandle.TerminateAndWait(12000)
      if (-not $terminated) { throw 'The verified legacy AX Store process did not exit within the bounded wait.' }
    } finally {
      if ($null -ne $verifiedHandle) { $verifiedHandle.Dispose() }
    }
    $finalOwners = Get-AxStorePortOwners
    $processStillAlive = $null -ne (Get-Process -Id ([int]$evidence.process.processId) -ErrorAction SilentlyContinue)
    $controlPortClosed = @($finalOwners[$script:ControlPort]).Count -eq 0
    $runtimePortClosed = @($finalOwners[$script:RuntimePort]).Count -eq 0
    $verifiedStopped = -not $processStillAlive -and $controlPortClosed -and $runtimePortClosed
    $completionPayload = [ordered]@{
      schema = $script:LegacyTransitionSchema
      action = 'STOP_LEGACY_ONCE'
      requestId = $requestId
      identityDigest = [string]$evidence.identity.identityDigest
      registrationDigest = [string]$registration.digest
      status = $(if($verifiedStopped){'STOPPED_FOR_MIGRATION'}else{'PARTIAL_OR_UNKNOWN'})
      gracefulAttempted = $false
      gracefulAvailable = $false
      forcedMigrationTermination = $forcedMigrationTermination
      processExited = -not $processStillAlive
      controlPortClosed = $controlPortClosed
      runtimePortClosed = $runtimePortClosed
      completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-AxStoreSignedDocumentExclusive -Path $completionPath -Secret $registration.secret -Payload $completionPayload | Out-Null
    return [pscustomobject]@{
      success=$verifiedStopped
      state=[string]$completionPayload.status
      processId=[int]$evidence.process.processId
      controlPortClosed=$controlPortClosed
      runtimePortClosed=$runtimePortClosed
      forcedMigrationTermination=$forcedMigrationTermination
      requestPath=$requestPath
      receiptPath=$completionPath
    }
  } catch {
    $failureMessage = $_.Exception.Message
    $failureReceiptPath = $null
    if ($requestWritten -and $null -ne $registration -and $null -ne $evidence -and -not [string]::IsNullOrWhiteSpace([string]$completionPath)) {
      try {
        $failureOwners = Get-AxStorePortOwners
        $failureProcessAlive = $null -ne (Get-Process -Id ([int]$evidence.process.processId) -ErrorAction SilentlyContinue)
        $failurePayload = [ordered]@{
          schema = $script:LegacyTransitionSchema
          action = 'STOP_LEGACY_ONCE'
          requestId = $requestId
          identityDigest = [string]$evidence.identity.identityDigest
          registrationDigest = [string]$registration.digest
          status = 'PARTIAL_OR_UNKNOWN'
          processExited = -not $failureProcessAlive
          controlPortClosed = @($failureOwners[$script:ControlPort]).Count -eq 0
          runtimePortClosed = @($failureOwners[$script:RuntimePort]).Count -eq 0
          error = $failureMessage
          completedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-AxStoreSignedDocumentExclusive -Path $completionPath -Secret $registration.secret -Payload $failurePayload | Out-Null
        $failureReceiptPath = $completionPath
      } catch {
        $failureReceiptPath = $null
      }
    }
    return [pscustomobject]@{success=$false;state='STOP_DENIED_OR_FAILED';error=$failureMessage;receiptPath=$failureReceiptPath}
  } finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

Export-ModuleMember -Function Get-AxStoreLifecycleStatus,Register-AxStoreLifecycle,Start-AxStoreOwnedInstance,Stop-AxStoreOwnedInstance,Stop-AxStoreVerifiedLegacyInstance,Test-AxStoreLifecycleItem
