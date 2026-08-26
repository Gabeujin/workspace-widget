[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PackagePath,
  [Parameter(Mandatory = $true)]
  [string]$ReceiptPath,
  [string]$IdentityFile,
  [string]$ProjectRoot,
  [string]$StageManifestPath,
  [switch]$StoreCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$PackagePath = [System.IO.Path]::GetFullPath($PackagePath)
$ReceiptPath = [System.IO.Path]::GetFullPath($ReceiptPath)
foreach ($requiredPath in @($PackagePath, $ReceiptPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required MSIX verification input was not found: $requiredPath"
  }
}

$receiptRaw = Get-Content -LiteralPath $ReceiptPath -Raw
$receipt = $receiptRaw | ConvertFrom-Json
$requiredReceiptProperties = @(
  'files',
  'fileCount',
  'packageSha256',
  'packageSigned',
  'identity',
  'version',
  'packageVersion'
)
if (
  @(
    $requiredReceiptProperties |
      Where-Object { $_ -notin $receipt.PSObject.Properties.Name }
  ).Count -gt 0 -or
  $null -eq $receipt.identity -or
  @(
    @('name', 'publisher', 'publisherDisplayName') |
      Where-Object { $_ -notin $receipt.identity.PSObject.Properties.Name }
  ).Count -gt 0
) {
  throw 'The Store package receipt is incomplete.'
}

$expectedIdentity = $null
if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
  $IdentityFile = [System.IO.Path]::GetFullPath($IdentityFile)
  if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
    throw "IdentityFile was not found: $IdentityFile"
  }
  $expectedIdentity = Get-Content -LiteralPath $IdentityFile -Raw |
    ConvertFrom-Json
  if (
    @(
      @(
        'packageIdentityName',
        'publisher',
        'publisherDisplayName'
      ) | Where-Object {
        $_ -notin $expectedIdentity.PSObject.Properties.Name
      }
    ).Count -gt 0
  ) {
    throw 'IdentityFile is incomplete.'
  }
}
if (
  $StoreCandidate -and (
    $null -eq $expectedIdentity -or
    [string]::IsNullOrWhiteSpace($ProjectRoot) -or
    [string]::IsNullOrWhiteSpace($StageManifestPath)
  )
) {
  throw (
    'StoreCandidate verification requires IdentityFile, ProjectRoot, and ' +
    'StageManifestPath.'
  )
}

$storeSourceBound = $true
$storeSourceChecks = [ordered]@{}
if ($StoreCandidate) {
  $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
  $StageManifestPath = [System.IO.Path]::GetFullPath($StageManifestPath)
  if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) {
    throw 'StoreCandidate verification requires a Git checkout.'
  }
  if (-not (Test-Path -LiteralPath $StageManifestPath -PathType Leaf)) {
    throw "StageManifestPath was not found: $StageManifestPath"
  }
  $git = Get-Command git.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrWhiteSpace($git)) {
    throw 'StoreCandidate verification requires git.exe.'
  }
  $gitRevision = (& $git -C $ProjectRoot rev-parse HEAD 2>$null) -join ''
  $gitRevisionExitCode = $LASTEXITCODE
  $gitStatus = (
    & $git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null
  ) -join "`n"
  $gitStatusExitCode = $LASTEXITCODE
  $stageManifestRaw = Get-Content -LiteralPath $StageManifestPath -Raw
  $stageManifest = $stageManifestRaw | ConvertFrom-Json

  $receiptRevision = if (
    $receipt.PSObject.Properties.Name -contains 'source' -and
    $null -ne $receipt.source -and
    $receipt.source.PSObject.Properties.Name -contains 'revision'
  ) {
    [string]$receipt.source.revision
  } else {
    ''
  }
  $receiptStageManifestHash = if (
    $receipt.PSObject.Properties.Name -contains 'source' -and
    $null -ne $receipt.source -and
    $receipt.source.PSObject.Properties.Name -contains 'stageManifestSha256'
  ) {
    [string]$receipt.source.stageManifestSha256
  } else {
    ''
  }
  $stageRevision = if (
    $stageManifest.PSObject.Properties.Name -contains 'source' -and
    $null -ne $stageManifest.source -and
    $stageManifest.source.PSObject.Properties.Name -contains 'revision'
  ) {
    [string]$stageManifest.source.revision
  } else {
    ''
  }
  $stageDirty = if (
    $stageManifest.PSObject.Properties.Name -contains 'source' -and
    $null -ne $stageManifest.source -and
    $stageManifest.source.PSObject.Properties.Name -contains 'dirty'
  ) {
    $stageManifest.source.dirty
  } else {
    $null
  }
  $stageDeterministic = (
    $stageManifest.PSObject.Properties.Name -contains 'toolchain' -and
    $null -ne $stageManifest.toolchain -and
    $stageManifest.toolchain.PSObject.Properties.Name -contains
      'deterministic' -and
    [bool]$stageManifest.toolchain.deterministic
  )
  $provenancePropertyNames = if (
    $receipt.PSObject.Properties.Name -contains 'provenance' -and
    $null -ne $receipt.provenance
  ) {
    @($receipt.provenance.PSObject.Properties.Name)
  } else {
    @()
  }
  $provenanceValid = (
    @(
      @(
        'mode',
        'sourceRebuilt',
        'preBuildSourceClean',
        'postBuildSourceClean',
        'finalSourceClean'
      ) | Where-Object { $_ -notin $provenancePropertyNames }
    ).Count -eq 0 -and
    [string]$receipt.provenance.mode -eq 'clean-git-rebuild' -and
    [bool]$receipt.provenance.sourceRebuilt -and
    [bool]$receipt.provenance.preBuildSourceClean -and
    [bool]$receipt.provenance.postBuildSourceClean -and
    [bool]$receipt.provenance.finalSourceClean
  )

  $msixBuilderPath = Join-Path `
    $ProjectRoot `
    'scripts\Build-WorkspaceWidgetMsix.ps1'
  $sourceBuilderPath = Join-Path `
    $ProjectRoot `
    'scripts\Build-WorkspaceWidget.ps1'
  $manifestTemplatePath = Join-Path `
    $ProjectRoot `
    'packaging\msix\AppxManifest.template.xml'
  $candidateVerifierPath = Join-Path `
    $ProjectRoot `
    'scripts\Test-WorkspaceWidgetMsix.ps1'
  $buildInputPropertyNames = if (
    $receipt.PSObject.Properties.Name -contains 'buildInputs' -and
    $null -ne $receipt.buildInputs
  ) {
    @($receipt.buildInputs.PSObject.Properties.Name)
  } else {
    @()
  }
  $buildInputHashesValid = (
    @(
      @(
        'msixBuilderSha256',
        'sourceBuilderSha256',
        'manifestTemplateSha256',
        'candidateVerifierSha256'
      ) | Where-Object { $_ -notin $buildInputPropertyNames }
    ).Count -eq 0 -and
    [string]$receipt.buildInputs.msixBuilderSha256 -eq (
      Get-FileHash -LiteralPath $msixBuilderPath -Algorithm SHA256
    ).Hash -and
    [string]$receipt.buildInputs.sourceBuilderSha256 -eq (
      Get-FileHash -LiteralPath $sourceBuilderPath -Algorithm SHA256
    ).Hash -and
    [string]$receipt.buildInputs.manifestTemplateSha256 -eq (
      Get-FileHash -LiteralPath $manifestTemplatePath -Algorithm SHA256
    ).Hash -and
    [string]$receipt.buildInputs.candidateVerifierSha256 -eq (
      Get-FileHash -LiteralPath $candidateVerifierPath -Algorithm SHA256
    ).Hash
  )

  $storeSourceChecks = [ordered]@{
    receiptSchema = (
      $receipt.PSObject.Properties.Name -contains 'schemaVersion' -and
      [int]$receipt.schemaVersion -eq 4
    )
    storeSubmission = (
      $receipt.PSObject.Properties.Name -contains 'storeSubmission' -and
      [bool]$receipt.storeSubmission
    )
    gitRevision = (
      $gitRevisionExitCode -eq 0 -and
      $gitRevision -match '^[0-9a-fA-F]{40,64}$' -and
      [string]::Equals(
        $gitRevision,
        $receiptRevision,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    )
    gitClean = (
      $gitStatusExitCode -eq 0 -and
      [string]::IsNullOrWhiteSpace($gitStatus)
    )
    stageManifestHash = [string]::Equals(
      $receiptStageManifestHash,
      (Get-FileHash -LiteralPath $StageManifestPath -Algorithm SHA256).Hash,
      [System.StringComparison]::OrdinalIgnoreCase
    )
    stageRevision = (
      $stageRevision -match '^[0-9a-fA-F]{40,64}$' -and
      [string]::Equals(
        $stageRevision,
        $gitRevision,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    )
    stageClean = $stageDirty -eq $false
    deterministicCompiler = $stageDeterministic
    cleanRebuildProvenance = $provenanceValid
    committedBuildInputs = $buildInputHashesValid
  }
  $storeSourceBound = @(
    $storeSourceChecks.GetEnumerator() |
      Where-Object { -not [bool]$_.Value }
  ).Count -eq 0
}

function Get-ZipEntrySha256 {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchiveEntry]$Entry
  )

  $stream = $Entry.Open()
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (
      [System.BitConverter]::ToString(
        $sha256.ComputeHash($stream)
      ).Replace('-', '')
    )
  }
  finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

function Read-ZipEntryText {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchiveEntry]$Entry
  )

  $stream = $Entry.Open()
  $reader = [System.IO.StreamReader]::new(
    $stream,
    [System.Text.Encoding]::UTF8,
    $true
  )
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
  $entries = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($entry in $archive.Entries) {
    if ([string]::IsNullOrWhiteSpace($entry.Name)) {
      continue
    }
    $entryPath = [System.Uri]::UnescapeDataString(
      $entry.FullName
    ).Replace('/', '\')
    if ($entries.ContainsKey($entryPath)) {
      throw "The MSIX contains a duplicate path: $entryPath"
    }
    $entries.Add($entryPath, $entry)
  }

  if (-not $entries.ContainsKey('AppxManifest.xml')) {
    throw 'The MSIX does not contain AppxManifest.xml.'
  }
  [xml]$manifest = Read-ZipEntryText -Entry $entries['AppxManifest.xml']
  $namespaces = [System.Xml.XmlNamespaceManager]::new(
    $manifest.NameTable
  )
  $namespaces.AddNamespace(
    'f',
    'http://schemas.microsoft.com/appx/manifest/foundation/windows10'
  )
  $namespaces.AddNamespace(
    'uap10',
    'http://schemas.microsoft.com/appx/manifest/uap/windows10/10'
  )
  $namespaces.AddNamespace(
    'desktop',
    'http://schemas.microsoft.com/appx/manifest/desktop/windows10'
  )
  $namespaces.AddNamespace(
    'rescap',
    'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities'
  )

  $identityNodes = $manifest.SelectNodes('/f:Package/f:Identity', $namespaces)
  $identityNode = if ($identityNodes.Count -eq 1) {
    $identityNodes[0]
  } else {
    $null
  }
  $applicationNodes = $manifest.SelectNodes(
    '/f:Package/f:Applications/f:Application',
    $namespaces
  )
  $applicationNode = if ($applicationNodes.Count -eq 1) {
    $applicationNodes[0]
  } else {
    $null
  }
  $startupExtensionNodes = $manifest.SelectNodes(
    (
      '/f:Package/f:Applications/f:Application/f:Extensions/' +
      'desktop:Extension'
    ),
    $namespaces
  )
  $startupTaskNodes = $manifest.SelectNodes(
    (
      '/f:Package/f:Applications/f:Application/f:Extensions/' +
      'desktop:Extension[@Category="windows.startupTask"]/' +
      'desktop:StartupTask'
    ),
    $namespaces
  )
  $startupExtensionNode = if ($startupExtensionNodes.Count -eq 1) {
    $startupExtensionNodes[0]
  } else {
    $null
  }
  $startupTaskNode = if ($startupTaskNodes.Count -eq 1) {
    $startupTaskNodes[0]
  } else {
    $null
  }
  $capabilityNodes = $manifest.SelectNodes(
    '/f:Package/f:Capabilities/*',
    $namespaces
  )
  $targetDeviceFamilyNodes = $manifest.SelectNodes(
    '/f:Package/f:Dependencies/f:TargetDeviceFamily',
    $namespaces
  )

  $receiptEntries = @{}
  $receiptFilesValid = $true
  foreach ($file in @($receipt.files)) {
    if (
      $null -eq $file -or
      @(
        @('path', 'size', 'sha256') |
          Where-Object { $_ -notin $file.PSObject.Properties.Name }
      ).Count -gt 0
    ) {
      $receiptFilesValid = $false
      continue
    }
    $relativePath = ([string]$file.path -replace '/', '\').TrimStart('\')
    if (
      [string]::IsNullOrWhiteSpace($relativePath) -or
      [System.IO.Path]::IsPathRooted($relativePath) -or
      $relativePath -match '(^|\\)\.\.(\\|$)' -or
      [string]$file.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
      $receiptEntries.ContainsKey($relativePath) -or
      -not $entries.ContainsKey($relativePath)
    ) {
      $receiptFilesValid = $false
      continue
    }
    $receiptEntries[$relativePath] = $file
    $entry = $entries[$relativePath]
    if (
      [int64]$file.size -ne $entry.Length -or
      -not [string]::Equals(
        [string]$file.sha256,
        (Get-ZipEntrySha256 -Entry $entry),
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      $receiptFilesValid = $false
    }
  }

  $generatedPackageEntries = @(
    'AppxBlockMap.xml',
    '[Content_Types].xml',
    'AppxSignature.p7x',
    'AppxMetadata\CodeIntegrity.cat'
  )
  $unexpectedPackageEntries = @(
    $entries.Keys |
      Where-Object {
        -not $receiptEntries.ContainsKey($_) -and
        $_ -notin $generatedPackageEntries
      } |
      Sort-Object
  )

  $manifestName = if ($null -eq $identityNode) {
    ''
  } else {
    $identityNode.GetAttribute('Name')
  }
  $manifestPublisher = if ($null -eq $identityNode) {
    ''
  } else {
    $identityNode.GetAttribute('Publisher')
  }
  $manifestPublisherDisplayName = ''
  $publisherDisplayNameNode = $manifest.SelectSingleNode(
    '/f:Package/f:Properties/f:PublisherDisplayName',
    $namespaces
  )
  if ($null -ne $publisherDisplayNameNode) {
    $manifestPublisherDisplayName = $publisherDisplayNameNode.InnerText
  }

  $identityMatches = (
    [string]$receipt.identity.name -eq $manifestName -and
    [string]$receipt.identity.publisher -eq $manifestPublisher -and
    [string]$receipt.identity.publisherDisplayName -eq
      $manifestPublisherDisplayName
  )
  if ($null -ne $expectedIdentity) {
    $identityMatches = $identityMatches -and
      [string]$expectedIdentity.packageIdentityName -eq $manifestName -and
      [string]$expectedIdentity.publisher -eq $manifestPublisher -and
      [string]$expectedIdentity.publisherDisplayName -eq
      $manifestPublisherDisplayName
  }

  $runtimeBehaviorNamespace =
    'http://schemas.microsoft.com/appx/manifest/uap/windows10/10'
  $expectedPackageVersion = [string]$receipt.packageVersion
  $manifestPackageVersion = if ($null -eq $identityNode) {
    ''
  } else {
    $identityNode.GetAttribute('Version')
  }
  $manifestPackageVersionParts = @($manifestPackageVersion.Split('.'))
  $storeVersionPolicy = -not $StoreCandidate -or (
    $manifestPackageVersionParts.Count -eq 4 -and
    @(
      $manifestPackageVersionParts |
        Where-Object { $_ -notmatch '^\d{1,5}$' -or [int]$_ -gt 65535 }
    ).Count -eq 0 -and
    [int]$manifestPackageVersionParts[0] -gt 0 -and
    [int]$manifestPackageVersionParts[3] -eq 0
  )
  $applicationContract = (
    $applicationNodes.Count -eq 1 -and
    $applicationNode.GetAttribute('Id') -eq 'WorkspaceWidget' -and
    $applicationNode.GetAttribute('Executable') -eq 'WorkspaceWidget.exe' -and
    [string]::IsNullOrWhiteSpace(
      $applicationNode.GetAttribute('EntryPoint')
    ) -and
    $applicationNode.GetAttribute(
      'RuntimeBehavior',
      $runtimeBehaviorNamespace
    ) -eq 'win32App' -and
    $applicationNode.GetAttribute(
      'TrustLevel',
      $runtimeBehaviorNamespace
    ) -eq 'mediumIL'
  )
  $startupTaskContract = (
    $startupExtensionNodes.Count -eq 1 -and
    $startupTaskNodes.Count -eq 1 -and
    $startupExtensionNode.GetAttribute('Category') -eq
      'windows.startupTask' -and
    $startupExtensionNode.GetAttribute('Executable') -eq
      'WorkspaceWidget.exe' -and
    $startupExtensionNode.GetAttribute('EntryPoint') -eq
      'Windows.FullTrustApplication' -and
    $startupTaskNode.GetAttribute('TaskId') -eq
      'WorkspaceWidgetStartup' -and
    $startupTaskNode.GetAttribute('Enabled') -eq 'false' -and
    -not [string]::IsNullOrWhiteSpace(
      $startupTaskNode.GetAttribute('DisplayName')
    )
  )
  $capabilityContract = (
    $capabilityNodes.Count -eq 1 -and
    $capabilityNodes[0].NamespaceURI -eq
      'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities' -and
    $capabilityNodes[0].LocalName -eq 'Capability' -and
    $capabilityNodes[0].GetAttribute('Name') -eq 'runFullTrust'
  )
  $desktopDependencyContract = (
    $targetDeviceFamilyNodes.Count -eq 1 -and
    $targetDeviceFamilyNodes[0].GetAttribute('Name') -eq
      'Windows.Desktop' -and
    [version]$targetDeviceFamilyNodes[0].GetAttribute('MinVersion') -ge
      [version]'10.0.22000.0'
  )
  $storeIdentityPolicy = if ($StoreCandidate) {
    $manifestName -notmatch
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE' -and
    $manifestPublisher -notmatch
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE' -and
    $manifestPublisherDisplayName -notmatch
      '(?i)DEVELOPMENT|VALIDATION|TEST|DUMMY|CONTRIBUTORS|REPLACE|PLACEHOLDER|EXAMPLE'
  } else {
    $true
  }

  $checks = [ordered]@{
    packageHash = [string]::Equals(
      [string]$receipt.packageSha256,
      (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash,
      [System.StringComparison]::OrdinalIgnoreCase
    )
    receiptHasNoAbsoluteWindowsPath = $receiptRaw -notmatch '(?i)[A-Z]:\\'
    receiptFilesMatchPackage = $receiptFilesValid -and
      $receiptEntries.Count -eq [int]$receipt.fileCount
    noUnexpectedPayload = $unexpectedPackageEntries.Count -eq 0
    identityMatches = $identityMatches
    identityContract = $identityNodes.Count -eq 1 -and
      $identityNode.GetAttribute('Version') -eq $expectedPackageVersion
    storeVersionPolicy = $storeVersionPolicy
    storeIdentityPolicy = $storeIdentityPolicy
    x64 = $identityNodes.Count -eq 1 -and
      $identityNode.GetAttribute('ProcessorArchitecture') -eq 'x64'
    applicationContract = $applicationContract
    startupTaskContract = $startupTaskContract
    capabilityAllowlist = $capabilityContract
    desktopDependency = $desktopDependencyContract
    producerPackageUnsigned = -not $entries.ContainsKey('AppxSignature.p7x') -and
      -not [bool]$receipt.packageSigned
    storeSourceBound = $storeSourceBound
  }

  $failedChecks = @(
    $checks.GetEnumerator() |
      Where-Object { -not [bool]$_.Value } |
      ForEach-Object { $_.Key }
  )
  [pscustomobject]@{
    success = $failedChecks.Count -eq 0
    storeCandidate = [bool]$StoreCandidate
    failedChecks = $failedChecks
    checks = $checks
    package = [System.IO.Path]::GetFileName($PackagePath)
    packageSha256 = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    identity = [ordered]@{
      name = $manifestName
      publisher = $manifestPublisher
      publisherDisplayName = $manifestPublisherDisplayName
    }
    unexpectedPackageEntries = $unexpectedPackageEntries
    storeSourceChecks = $storeSourceChecks
  } | ConvertTo-Json -Depth 6

  if ($failedChecks.Count -gt 0) {
    exit 1
  }
}
finally {
  $archive.Dispose()
}
