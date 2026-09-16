[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$DependencyRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '24.21.0',
  [ValidatePattern('^[A-Fa-f0-9]{64}$')]
  [string]$PackageSha256 = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$distributionName = "node-v$Version-win-x64"
$sourceUrl = "https://nodejs.org/download/release/v$Version/$distributionName.zip"
if ([string]::IsNullOrWhiteSpace($DependencyRoot)) {
  $cacheBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    [System.IO.Path]::GetTempPath()
  } else {
    $env:LOCALAPPDATA
  }
  $DependencyRoot = Join-Path $cacheBase 'WorkspaceWidget\DependencyCache'
}
$DependencyRoot = [System.IO.Path]::GetFullPath($DependencyRoot)
$dependencyRoot = Join-Path $DependencyRoot "Node.js\$Version"
$archivePath = Join-Path $dependencyRoot "$distributionName.zip"

New-Item -ItemType Directory -Path $dependencyRoot -Force | Out-Null

if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
  $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  if (-not [string]::Equals(
      $archiveHash,
      $PackageSha256,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw (
      "The cached Node.js archive hash does not match the pinned release. " +
      "Expected $PackageSha256 but found $archiveHash at '$archivePath'."
    )
  }
} else {
  $downloadPath = "$archivePath.download-$PID"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadPath -UseBasicParsing
  $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
  if (-not [string]::Equals(
      $downloadHash,
      $PackageSha256,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw (
      "Downloaded Node.js archive hash mismatch. " +
      "Expected $PackageSha256 but found $downloadHash. " +
      "The untrusted download was preserved at '$downloadPath' for inspection."
    )
  }
  Move-Item -LiteralPath $downloadPath -Destination $archivePath
}

$runtimeRoot = Join-Path $dependencyRoot 'runtime'
$runtimeCacheManifestPath = Join-Path $dependencyRoot 'runtime-cache-manifest.json'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ArchiveRuntimeInventory {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$DistributionName
  )

  $inventory = [System.Collections.Generic.List[object]]::new()
  $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    if ($archive.Entries.Count -gt 15000) {
      throw "The Node.js archive has an unexpected entry count: $($archive.Entries.Count)"
    }
    $totalUncompressedBytes = [int64](
      $archive.Entries |
        Measure-Object -Property Length -Sum |
        Select-Object -ExpandProperty Sum
    )
    if ($totalUncompressedBytes -gt 600MB) {
      throw 'The Node.js archive expands beyond the 600 MB safety limit.'
    }

    $runtimePrefix = "$DistributionName/"
    foreach ($entry in $archive.Entries) {
      $entryPath = $entry.FullName.Replace('\', '/')
      if (-not $entryPath.StartsWith(
          $runtimePrefix,
          [System.StringComparison]::Ordinal
        )) {
        throw "Unexpected path in the Node.js archive: $entryPath"
      }
      $relativePath = $entryPath.Substring($runtimePrefix.Length)
      if ([string]::IsNullOrWhiteSpace($relativePath)) {
        continue
      }
      $segments = @($relativePath.Split('/') | Where-Object { $_.Length -gt 0 })
      if (
        $relativePath.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $relativePath.Contains(':') -or
        $segments -contains '..'
      ) {
        throw "Unsafe path in the Node.js archive: $entryPath"
      }
      if ([string]::IsNullOrWhiteSpace($entry.Name)) {
        continue
      }

      $normalizedPath = $relativePath.Replace('/', '\')
      if (-not $seenPaths.Add($normalizedPath)) {
        throw "Duplicate runtime path in the Node.js archive: $normalizedPath"
      }
      $sourceStream = $entry.Open()
      $hasher = [System.Security.Cryptography.SHA256]::Create()
      try {
        $entryHash = [BitConverter]::ToString(
          $hasher.ComputeHash($sourceStream)
        ).Replace('-', '')
      } finally {
        $hasher.Dispose()
        $sourceStream.Dispose()
      }
      $inventory.Add([pscustomobject][ordered]@{
          path = $normalizedPath
          size = [int64]$entry.Length
          sha256 = $entryHash
        })
    }
  } finally {
    $archive.Dispose()
  }
  return @($inventory | Sort-Object path)
}

function Test-RuntimeMatchesArchive {
  param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][object[]]$ArchiveFiles
  )

  $actualPaths = @(
    Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File |
      ForEach-Object { $_.FullName.Substring($RuntimeRoot.Length).TrimStart('\') } |
      Sort-Object
  )
  $expectedPaths = @($ArchiveFiles | ForEach-Object { [string]$_.path } | Sort-Object)
  if ([string]::Join('|', $actualPaths) -cne [string]::Join('|', $expectedPaths)) {
    return $false
  }
  foreach ($entry in $ArchiveFiles) {
    $cachedPath = Join-Path $RuntimeRoot ([string]$entry.path)
    $cachedItem = Get-Item -LiteralPath $cachedPath
    if (
      [int64]$cachedItem.Length -ne [int64]$entry.size -or
      -not [string]::Equals(
        (Get-FileHash -LiteralPath $cachedPath -Algorithm SHA256).Hash,
        [string]$entry.sha256,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      return $false
    }
  }
  return $true
}

$archiveRuntimeFiles = @(
  Get-ArchiveRuntimeInventory `
    -ArchivePath $archivePath `
    -DistributionName $distributionName
)
$runtimeIsReusable = $false
if (
  (Test-Path -LiteralPath $runtimeRoot -PathType Container) -and
  (Test-Path -LiteralPath $runtimeCacheManifestPath -PathType Leaf)
) {
  $cacheManifest = Get-Content -LiteralPath $runtimeCacheManifestPath -Raw |
    ConvertFrom-Json
  $runtimeIsReusable = (
    [string]$cacheManifest.version -eq $Version -and
    [string]::Equals(
      [string]$cacheManifest.packageSha256,
      $PackageSha256,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  )
  if ($runtimeIsReusable) {
    $runtimeIsReusable = Test-RuntimeMatchesArchive `
      -RuntimeRoot $runtimeRoot `
      -ArchiveFiles $archiveRuntimeFiles
  }
}

if (-not $runtimeIsReusable) {
  if (
    (Test-Path -LiteralPath $runtimeRoot) -or
    (Test-Path -LiteralPath $runtimeCacheManifestPath -PathType Leaf)
  ) {
    throw (
      "The cached Node.js runtime is incomplete or has the wrong version at '$runtimeRoot'. " +
      'Review it manually or pass a fresh DependencyRoot; the restore will not overwrite it.'
    )
  }
  New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

  $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    if ($archive.Entries.Count -gt 15000) {
      throw "The Node.js archive has an unexpected entry count: $($archive.Entries.Count)"
    }
    $totalUncompressedBytes = [int64](
      $archive.Entries |
        Measure-Object -Property Length -Sum |
        Select-Object -ExpandProperty Sum
    )
    if ($totalUncompressedBytes -gt 600MB) {
      throw "The Node.js archive expands beyond the 600 MB safety limit."
    }

    $runtimePrefix = "$distributionName/"
    foreach ($entry in $archive.Entries) {
      $entryPath = $entry.FullName.Replace('\', '/')
      if (-not $entryPath.StartsWith(
          $runtimePrefix,
          [System.StringComparison]::Ordinal
        )) {
        throw "Unexpected path in the Node.js archive: $entryPath"
      }
      $relativePath = $entryPath.Substring($runtimePrefix.Length)
      if ([string]::IsNullOrWhiteSpace($relativePath)) {
        continue
      }

      $destinationPath = [System.IO.Path]::GetFullPath(
        (Join-Path $runtimeRoot $relativePath.Replace('/', '\'))
      )
      $runtimePrefixPath = $runtimeRoot.TrimEnd('\') + '\'
      if (-not $destinationPath.StartsWith(
          $runtimePrefixPath,
          [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Unsafe path in the Node.js archive: $entryPath"
      }

      if ([string]::IsNullOrWhiteSpace($entry.Name)) {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        continue
      }

      $destinationDirectory = Split-Path -Parent $destinationPath
      New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
      $sourceStream = $entry.Open()
      $destinationStream = [System.IO.File]::Open(
        $destinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
      try {
        $sourceStream.CopyTo($destinationStream)
      }
      finally {
        $destinationStream.Dispose()
        $sourceStream.Dispose()
      }
    }
  }
  finally {
    $archive.Dispose()
  }
}

if (-not (Test-RuntimeMatchesArchive -RuntimeRoot $runtimeRoot -ArchiveFiles $archiveRuntimeFiles)) {
  throw (
    "The restored Node.js runtime does not match the pinned official archive at '$archivePath'. " +
    'The runtime was preserved for inspection and was not executed.'
  )
}

$nodePath = Join-Path $runtimeRoot 'node.exe'
$npmPath = Join-Path $runtimeRoot 'npm.cmd'
$licensePath = Join-Path $runtimeRoot 'LICENSE'
foreach ($required in @($nodePath, $npmPath, $licensePath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "The restored Node.js runtime is incomplete: $required"
  }
}

$actualVersion = (& $nodePath --version 2>&1 | Select-Object -First 1)
if ([string]$actualVersion -ne "v$Version") {
  throw "Restored Node.js version mismatch. Expected v$Version but found $actualVersion."
}

$runtimeFiles = @($archiveRuntimeFiles)
if (-not (Test-Path -LiteralPath $runtimeCacheManifestPath -PathType Leaf)) {
  [pscustomobject][ordered]@{
    schemaVersion = 1
    version = $Version
    packageSha256 = $PackageSha256.ToUpperInvariant()
    files = $runtimeFiles
  } | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $runtimeCacheManifestPath -Encoding UTF8
}

[pscustomobject][ordered]@{
  success = $true
  product = 'Node.js'
  version = $Version
  sourceUrl = $sourceUrl
  packagePath = $archivePath
  packageSha256 = $PackageSha256.ToUpperInvariant()
  runtimeRoot = $runtimeRoot
  nodePath = $nodePath
  npmPath = $npmPath
  fileCount = $runtimeFiles.Count
  files = $runtimeFiles
} | ConvertTo-Json -Depth 6
