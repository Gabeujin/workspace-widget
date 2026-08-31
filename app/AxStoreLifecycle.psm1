Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LifecycleSchema = 'workspace-widget/ax-store-lifecycle/v1'
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

function Protect-AxStoreLifecycleDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $propagation = [Security.AccessControl.PropagationFlags]::None
  $allow = [Security.AccessControl.AccessControlType]::Allow
  foreach ($sidValue in @(
      [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
      'S-1-5-18',
      'S-1-5-32-544'
    )) {
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
}

function Test-AxStoreLifecycleItem {
  param($Item)
  if ($null -eq $Item) { return $false }
  try {
    $target = [uri][string]$Item.target
    $health = [uri][string]$Item.health
    $launcher = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Item.startupTarget))
    return (
      [string]$Item.id -eq 'ax-store' -and
      $target.IsLoopback -and $target.Port -eq $script:ControlPort -and
      $health.IsLoopback -and $health.Port -eq $script:ControlPort -and
      [IO.Path]::GetFileName($launcher) -eq 'workspace-widget-launcher.js' -and
      $launcher -match '(?i)\\apps\\ax-store\\scripts\\workspace-widget-launcher\.js$'
    )
  } catch { return $false }
}

function Get-AxStoreLifecycleRoot {
  param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
  return Join-Path $RuntimeRoot 'ax-store-lifecycle\instances'
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
    $result.state = 'NotApplicable'; $result.reason = 'The shortcut does not match the fixed AX Store lifecycle contract.'
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
      if ((Get-Item -LiteralPath $directory.FullName -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lifecycle directory cannot be a reparse point.' }
      if ((Get-Item -LiteralPath $secretPath -Force).Length -gt 256 -or (Get-Item -LiteralPath $ownershipPath -Force).Length -gt 64KB) { throw 'Lifecycle evidence exceeds its size limit.' }
      if ((Get-Item -LiteralPath $secretPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-Item -LiteralPath $ownershipPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lifecycle evidence cannot be a reparse point.' }
      $acl = Get-Acl -LiteralPath $directory.FullName
      if (-not $acl.AreAccessRulesProtected) { throw 'Lifecycle directory inheritance is not protected.' }
      $allowedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
      )
      $rules = @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
      $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
      if ($rules.Count -lt 3 -or @($rules | Where-Object {
          $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
          $_.IdentityReference.Value -notin $allowedSids
        }).Count -gt 0 -or $ownerSid -notin $allowedSids -or @($allowedSids | Where-Object { $_ -notin @($rules.IdentityReference.Value) }).Count -gt 0) {
        throw 'Lifecycle directory ACL contains an untrusted principal or rule.'
      }
      $secret = [Convert]::FromBase64String((Get-Content -LiteralPath $secretPath -Raw).Trim())
      $document = Read-AxStoreSignedDocument -Path $ownershipPath -Secret $secret
      $payload = $document.payload
      if ($payload.schema -ne $script:LifecycleSchema -or [string]$payload.instanceId -ne $directory.Name) { throw 'Ownership identity is inconsistent.' }
      if ((Get-AxStoreByteSha256 $secret) -ne [string]$payload.capabilitySha256) { throw 'The lifecycle capability no longer matches its receipt.' }
      if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Item.startupTarget), [IO.Path]::GetFullPath([string]$payload.launcherPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'The shortcut launcher no longer matches the owner.' }
      foreach ($artifact in @(@($payload.brokerPath,$payload.brokerSha256),@($payload.launcherPath,$payload.launcherSha256),@($payload.contractPath,$payload.contractSha256),@($payload.executablePath,$payload.executableSha256))) {
        if (-not (Test-Path -LiteralPath $artifact[0] -PathType Leaf) -or ((Get-Item -LiteralPath $artifact[0] -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-AxStoreSha256 $artifact[0]) -ne [string]$artifact[1]) { throw 'A lifecycle artifact changed after ownership was established.' }
      }
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$payload.pid)" -ErrorAction Stop
      $creation = ([datetime]$process.CreationDate).ToUniversalTime()
      if ([math]::Abs(($creation - ([datetime]$payload.processCreationTimeUtc).ToUniversalTime()).TotalSeconds) -gt 1) { throw 'The PID was reused or its creation time changed.' }
      if (-not [string]::Equals([string]$process.ExecutablePath,[string]$payload.executablePath,[StringComparison]::OrdinalIgnoreCase)) { throw 'The broker executable path changed.' }
      $commandHash = Get-AxStoreTextSha256 ([string]$process.CommandLine)
      if ($commandHash -ne [string]$payload.commandLineSha256) { throw 'The broker command line changed.' }
      if (
        @($owners[$script:ControlPort]).Count -ne 1 -or
        @($owners[$script:RuntimePort]).Count -ne 1 -or
        [int]$owners[$script:ControlPort][0] -ne [int]$payload.pid -or
        [int]$owners[$script:RuntimePort][0] -ne [int]$payload.pid
      ) { throw 'The AX Store listeners are not owned exclusively by the recorded broker PID.' }
      if (-not $SkipHealth) {
        foreach ($url in @([string]$payload.controlHealthUrl,[string]$payload.runtimeHealthUrl)) {
          $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
          if ([int]$response.StatusCode -ne 200) { throw "Health contract failed: $url" }
        }
      }
      $result.state='OwnedOnline'; $result.owned=$true; $result.stoppable=$true; $result.reason='Workspace Widget owns the verified AX Store instance.'
      $result.instance=[pscustomobject]@{root=$directory.FullName;secret=$secret;ownership=$document;payload=$payload}
      return [pscustomobject]$result
    } catch { continue }
  }
  if ($occupied) {
    $result.state='RunningUnowned'; $result.reason='AX Store is running, but no valid Workspace Widget ownership receipt matches it.'
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
  if (-not (Test-AxStoreLifecycleItem $Item)) { throw 'AX Store startup is limited to the fixed ax-store shortcut contract.' }
  $status = Get-AxStoreLifecycleStatus -Item $Item -RuntimeRoot $RuntimeRoot -SkipHealth
  if ($status.state -eq 'OwnedOnline') { return [pscustomobject]@{success=$true;state='AlreadyOwned';pid=[int]$status.instance.payload.pid} }
  if ($status.state -eq 'RunningUnowned') { return [pscustomobject]@{success=$false;state='RunningUnowned';error=$status.reason} }
  $launcherPath = [IO.Path]::GetFullPath([string]$Item.startupTarget)
  $contractPath = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $launcherPath -Parent) -Parent) 'src\public\runtime-contract.json'))
  foreach ($path in @($BundledNodePath,$BrokerPath,$launcherPath,$contractPath)) { if (-not (Test-Path $path -PathType Leaf)) { throw "Required AX Store lifecycle artifact is missing: $path" } }
  foreach ($path in @($BundledNodePath,$BrokerPath,$launcherPath,$contractPath)) { if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "AX Store lifecycle artifacts cannot be reparse points: $path" } }
  $instanceId = [guid]::NewGuid().ToString('N')
  $instanceRoot = Join-Path (Get-AxStoreLifecycleRoot $RuntimeRoot) $instanceId
  Protect-AxStoreLifecycleDirectory -Path $instanceRoot
  $secret = [byte[]]::new(32)
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $random.GetBytes($secret) } finally { $random.Dispose() }
  $secretPath = Join-Path $instanceRoot 'capability.key'
  [IO.File]::WriteAllText($secretPath,[Convert]::ToBase64String($secret),[Text.UTF8Encoding]::new($false))
  $pipeName = "\\.\pipe\WorkspaceWidget.AxStore.$instanceId"
  $bootstrap = [ordered]@{schema=$script:LifecycleSchema;instanceId=$instanceId;instanceRoot=$instanceRoot;secretPath=$secretPath;activationPath=(Join-Path $instanceRoot 'activation.json');ownershipPath=(Join-Path $instanceRoot 'ownership.json');eventsPath=(Join-Path $instanceRoot 'events.jsonl');pipeName=$pipeName;launcherPath=$launcherPath;contractPath=$contractPath}
  $bootstrapPath = Join-Path $instanceRoot 'bootstrap.json'
  [IO.File]::WriteAllText($bootstrapPath,($bootstrap|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  $arguments = '"{0}" --bootstrap "{1}"' -f $BrokerPath,$bootstrapPath
  $process = Start-Process -FilePath $BundledNodePath -ArgumentList $arguments -WorkingDirectory (Split-Path $BrokerPath -Parent) -WindowStyle Hidden -PassThru
  $cim = $null
  for($attempt=0;$attempt -lt 40 -and $null -eq $cim;$attempt++){ Start-Sleep -Milliseconds 50; $cim=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue }
  if ($null -eq $cim) { throw 'Could not capture the AX Store broker process identity.' }
  $activation = [ordered]@{schema=$script:LifecycleSchema;instanceId=$instanceId;pid=$process.Id;processCreationTimeUtc=([datetime]$cim.CreationDate).ToUniversalTime().ToString('o');executablePath=[string]$cim.ExecutablePath;executableSha256=Get-AxStoreSha256 ([string]$cim.ExecutablePath);commandLineSha256=Get-AxStoreTextSha256 ([string]$cim.CommandLine);brokerSha256=Get-AxStoreSha256 $BrokerPath;launcherSha256=Get-AxStoreSha256 $launcherPath;contractSha256=Get-AxStoreSha256 $contractPath;activatedAt=(Get-Date).ToUniversalTime().ToString('o')}
  $activationDocument=[ordered]@{payload=$activation;signature=Get-AxStoreHmac -Secret $secret -Payload $activation}
  [IO.File]::WriteAllText($bootstrap.activationPath,($activationDocument|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  $deadline=(Get-Date).AddSeconds(20)
  while((Get-Date)-lt $deadline){
    if(Test-Path $bootstrap.ownershipPath -PathType Leaf){return [pscustomobject]@{success=$true;state='StartedOwned';pid=$process.Id;instanceId=$instanceId}}
    if($process.HasExited){return [pscustomobject]@{success=$false;state='NotOwnerOrFailed';error='AX Store was already running, stale, or startup failed. Review runtime.log and the lifecycle event receipt.'}}
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
  $request=[ordered]@{schema=$script:LifecycleSchema;action='STOP';instanceId=[string]$instance.payload.instanceId;requestId=$requestId;ownershipDigest=$ownershipDigest;reason=$Reason.Trim();acknowledgedImpact=$true;requestedAt=(Get-Date).ToUniversalTime().ToString('o')}
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

Export-ModuleMember -Function Get-AxStoreLifecycleStatus,Start-AxStoreOwnedInstance,Stop-AxStoreOwnedInstance,Test-AxStoreLifecycleItem
