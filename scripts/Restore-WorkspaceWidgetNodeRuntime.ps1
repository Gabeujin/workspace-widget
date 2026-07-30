[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '24.18.0',
  [ValidatePattern('^[A-Fa-f0-9]{64}$')]
  [string]$PackageSha256 = '0ae68406b42d7725661da979b1403ec9926da205c6770827f33aac9d8f26e821'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$distributionName = "node-v$Version-win-x64"
$sourceUrl = "https://nodejs.org/download/release/v$Version/$distributionName.zip"
$dependencyRoot = Join-Path $ProjectRoot "artifacts\dependencies\Node.js\$Version"
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

$runtimeRoot = $null

if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $runtimeRoot = Join-Path $dependencyRoot ("runtime-" + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
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

$runtimeFiles = @(
  Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      [ordered]@{
        path = $_.FullName.Substring($runtimeRoot.Length).TrimStart('\')
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    }
)

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
