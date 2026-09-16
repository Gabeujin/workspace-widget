[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$DependencyRoot,
  [string]$WebView2Version = '1.0.4191.47'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($DependencyRoot)) {
  $cacheBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    [System.IO.Path]::GetTempPath()
  } else {
    $env:LOCALAPPDATA
  }
  $DependencyRoot = Join-Path $cacheBase 'WorkspaceWidget\DependencyCache'
}
$DependencyRoot = [System.IO.Path]::GetFullPath($DependencyRoot)

$supported = @{
  '1.0.4191.47' = @{
    sha256 = 'F492BBF547D0DA329553B6727435B677579B1E9F91CC9E4A1AD029366D5F23D0'
    uri = 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4191.47'
  }
}
if (-not $supported.ContainsKey($WebView2Version)) {
  throw "WebView2 version '$WebView2Version' is not pinned in this restore script."
}

$packageRoot = Join-Path $DependencyRoot "Microsoft.Web.WebView2\$WebView2Version"
$packagePath = Join-Path $packageRoot "Microsoft.Web.WebView2.$WebView2Version.nupkg"
$runtimeRoot = Join-Path $packageRoot 'runtime'
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
  Invoke-WebRequest `
    -Uri $supported[$WebView2Version].uri `
    -OutFile $packagePath `
    -UseBasicParsing
}

$actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
if (-not [string]::Equals(
    $actualHash,
    $supported[$WebView2Version].sha256,
    [System.StringComparison]::OrdinalIgnoreCase
  )) {
  throw "WebView2 package checksum mismatch. Expected $($supported[$WebView2Version].sha256), received $actualHash."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$entries = [ordered]@{
  'lib/net462/Microsoft.Web.WebView2.Core.dll' = 'Microsoft.Web.WebView2.Core.dll'
  'lib/net462/Microsoft.Web.WebView2.Wpf.dll' = 'Microsoft.Web.WebView2.Wpf.dll'
  'runtimes/win-x64/native/WebView2Loader.dll' = 'WebView2Loader.dll'
  'LICENSE.txt' = 'Microsoft.Web.WebView2.LICENSE.txt'
  'NOTICE.txt' = 'Microsoft.Web.WebView2.NOTICE.txt'
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
try {
  foreach ($mapping in $entries.GetEnumerator()) {
    $entry = $archive.GetEntry($mapping.Key)
    if ($null -eq $entry) {
      throw "Required WebView2 package entry is missing: $($mapping.Key)"
    }
    $destination = Join-Path $runtimeRoot $mapping.Value
    $sourceStream = $entry.Open()
    try {
      $destinationStream = [System.IO.File]::Open(
        $destination,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
      try {
        $sourceStream.CopyTo($destinationStream)
      } finally {
        $destinationStream.Dispose()
      }
    } finally {
      $sourceStream.Dispose()
    }
  }
} finally {
  $archive.Dispose()
}

$restoredFiles = @(
  Get-ChildItem -LiteralPath $runtimeRoot -File |
    Sort-Object Name |
    ForEach-Object {
      [ordered]@{
        name = $_.Name
        path = $_.FullName
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    }
)

[pscustomobject]@{
  success = $true
  package = 'Microsoft.Web.WebView2'
  version = $WebView2Version
  packagePath = $packagePath
  packageSha256 = $actualHash
  runtimeRoot = $runtimeRoot
  files = $restoredFiles
} | ConvertTo-Json -Depth 6
