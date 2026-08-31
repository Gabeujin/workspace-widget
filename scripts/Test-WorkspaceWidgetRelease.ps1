[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '0.1.0',
  [string]$OutputRoot,
  [switch]$RequireInstaller,
  [switch]$RequireSigned,
  [string]$ExpectedSignerThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $buildBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    [System.IO.Path]::GetTempPath()
  } else {
    $env:LOCALAPPDATA
  }
  $OutputRoot = Join-Path $buildBase "WorkspaceWidget\Builds\$Version"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$manifestPath = Join-Path $OutputRoot "WorkspaceWidget-$Version-manifest.json"
$installerScriptPath = Join-Path $ProjectRoot 'installer\WorkspaceWidget.iss'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Release manifest not found at '$manifestPath'. Run the build first."
}
if (-not (Test-Path -LiteralPath $installerScriptPath -PathType Leaf)) {
  throw "Installer source not found at '$installerScriptPath'."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$installerScriptContent = Get-Content -LiteralPath $installerScriptPath -Raw
$stageRoot = if (
  $manifest.PSObject.Properties.Name -contains 'stageRoot' -and
  -not [string]::IsNullOrWhiteSpace([string]$manifest.stageRoot)
) {
  [string]$manifest.stageRoot
} else {
  Join-Path $OutputRoot 'staging\WorkspaceWidget'
}
$installerPath = if ([string]::IsNullOrWhiteSpace([string]$manifest.installer)) {
  ''
} elseif ([System.IO.Path]::IsPathRooted([string]$manifest.installer)) {
  [string]$manifest.installer
} else {
  Join-Path $OutputRoot ([string]$manifest.installer)
}
$hostPath = Join-Path $stageRoot 'WorkspaceWidget.exe'
$stageStatePath = Join-Path $stageRoot 'app\default-state.json'
$stageAppPath = Join-Path $stageRoot 'app\WorkspaceWidget.ps1'
$nodeRuntimeRoot = Join-Path $stageRoot 'runtime\node'
$nodeRuntimeManifestPath = Join-Path $nodeRuntimeRoot 'WORKSPACE-WIDGET-RUNTIME-MANIFEST.json'
if (-not (Test-Path -LiteralPath $nodeRuntimeManifestPath -PathType Leaf)) {
  throw "Bundled Node.js runtime manifest not found at '$nodeRuntimeManifestPath'."
}
$nodeRuntimeManifest = Get-Content -LiteralPath $nodeRuntimeManifestPath -Raw |
  ConvertFrom-Json
$expectedNodeRuntimeFiles = @(
  @($nodeRuntimeManifest.files) |
    ForEach-Object { "runtime\node\$([string]$_.path)" }
) + @('runtime\node\WORKSPACE-WIDGET-RUNTIME-MANIFEST.json')
$expectedSemanticIconFiles = @(
  'manifest.json',
  'launch.svg', 'launch.png',
  'service.svg', 'service.png',
  'people.svg', 'people.png',
  'workspace.svg', 'workspace.png',
  'web.svg', 'web.png',
  'data.svg', 'data.png',
  'automation.svg', 'automation.png',
  'lab.svg', 'lab.png'
) | ForEach-Object { "assets\semantic-icons\$_" }

$expectedStageFiles = @(
  'WorkspaceWidget.exe',
  'WebView2Loader.dll',
  'app\WorkspaceWidget.ps1',
  'app\default-state.json',
  'assets\workspace-widget.ico',
  'assets\workspace-widget-logo.png',
  'lib\webview2\Microsoft.Web.WebView2.Core.dll',
  'lib\webview2\Microsoft.Web.WebView2.Wpf.dll',
  'licenses\Microsoft.Web.WebView2.LICENSE.txt',
  'licenses\Microsoft.Web.WebView2.NOTICE.txt',
  'scripts\Set-WorkspaceWidgetAutostart.ps1',
  'docs\INSTALLATION.md',
  'docs\USER-GUIDE.md',
  'docs\MEDIA-CUSTOMIZATION.md',
  'docs\ENTERPRISE-DEPLOYMENT.md',
  'docs\MICROSOFT-STORE-RELEASE.md',
  'docs\PARTNER-CENTER-SUBMISSION-KO.md',
  'docs\AI-ASSISTED-DEVELOPMENT.md',
  'docs\SEMANTIC-ICON-LIBRARY.md',
  'docs\SEMANTIC-ICON-GALLERY.html',
  'README.md',
  'PUBLIC-RELEASE-REVIEW.md',
  'SECURITY.md',
  'PRIVACY.md',
  'LICENSE',
  'THIRD-PARTY-NOTICES.md',
  'CHANGELOG.md'
) + $expectedSemanticIconFiles + $expectedNodeRuntimeFiles |
  Sort-Object

$actualStageFiles = @(
  Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
    ForEach-Object {
      $_.FullName.Substring($stageRoot.Length).TrimStart('\')
    } |
    Sort-Object
)
$missingStageFiles = @($expectedStageFiles | Where-Object { $_ -notin $actualStageFiles })
$unexpectedStageFiles = @($actualStageFiles | Where-Object { $_ -notin $expectedStageFiles })

$parserResults = @(
  foreach ($file in @(
      (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'),
      (Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidget.ps1'),
      (Join-Path $ProjectRoot 'scripts\Restore-WorkspaceWidgetDependencies.ps1'),
      (Join-Path $ProjectRoot 'scripts\Restore-WorkspaceWidgetNodeRuntime.ps1'),
      (Join-Path $ProjectRoot 'scripts\Set-WorkspaceWidgetAutostart.ps1'),
      (Join-Path $ProjectRoot 'scripts\Start-WorkspaceWidget.ps1'),
      (Join-Path $ProjectRoot 'scripts\Install-WorkspaceWidget.ps1'),
      (Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidget.ps1'),
      (Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidgetSemanticIcons.ps1'),
      (Join-Path $ProjectRoot 'scripts\Build-WorkspaceWidgetMsix.ps1'),
      (Join-Path $ProjectRoot 'scripts\Test-WorkspaceWidgetMsix.ps1'),
      $PSCommandPath
    )) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $file,
      [ref]$tokens,
      [ref]$errors
    ) | Out-Null
    [pscustomobject]@{
      path = $file
      valid = $errors.Count -eq 0
      errors = @($errors | ForEach-Object { $_.Message })
    }
  }
)

$stageState = Get-Content -LiteralPath $stageStatePath -Raw | ConvertFrom-Json
$manifestMismatches = @(
  foreach ($entry in @($manifest.files)) {
    $path = Join-Path $stageRoot ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      [pscustomobject]@{ path = [string]$entry.path; reason = 'missing' }
      continue
    }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (
      [int64]$entry.size -ne [int64]$item.Length -or
      -not [string]::Equals(
        [string]$entry.sha256,
        $hash,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      [pscustomobject]@{ path = [string]$entry.path; reason = 'size-or-hash' }
    }
  }
)
$manifestPaths = @($manifest.files | ForEach-Object { [string]$_.path } | Sort-Object)
$manifestCoverage = (
  [string]::Join('|', $manifestPaths) -ceq
  [string]::Join('|', $actualStageFiles)
)

$sourceStageMappings = @(
  [pscustomobject]@{ source='app\WorkspaceWidget.ps1'; stage='app\WorkspaceWidget.ps1' },
  [pscustomobject]@{ source='app\public-default-state.json'; stage='app\default-state.json' },
  [pscustomobject]@{ source='assets\workspace-widget.ico'; stage='assets\workspace-widget.ico' },
  [pscustomobject]@{ source='assets\workspace-widget-logo.png'; stage='assets\workspace-widget-logo.png' },
  [pscustomobject]@{ source='scripts\Set-WorkspaceWidgetAutostart.ps1'; stage='scripts\Set-WorkspaceWidgetAutostart.ps1' },
  [pscustomobject]@{ source='docs\INSTALLATION.md'; stage='docs\INSTALLATION.md' },
  [pscustomobject]@{ source='docs\USER-GUIDE.md'; stage='docs\USER-GUIDE.md' },
  [pscustomobject]@{ source='docs\MEDIA-CUSTOMIZATION.md'; stage='docs\MEDIA-CUSTOMIZATION.md' },
  [pscustomobject]@{ source='docs\ENTERPRISE-DEPLOYMENT.md'; stage='docs\ENTERPRISE-DEPLOYMENT.md' },
  [pscustomobject]@{ source='docs\MICROSOFT-STORE-RELEASE.md'; stage='docs\MICROSOFT-STORE-RELEASE.md' },
  [pscustomobject]@{ source='docs\PARTNER-CENTER-SUBMISSION-KO.md'; stage='docs\PARTNER-CENTER-SUBMISSION-KO.md' },
  [pscustomobject]@{ source='docs\AI-ASSISTED-DEVELOPMENT.md'; stage='docs\AI-ASSISTED-DEVELOPMENT.md' },
  [pscustomobject]@{ source='docs\SEMANTIC-ICON-LIBRARY.md'; stage='docs\SEMANTIC-ICON-LIBRARY.md' },
  [pscustomobject]@{ source='docs\SEMANTIC-ICON-GALLERY.html'; stage='docs\SEMANTIC-ICON-GALLERY.html' },
  [pscustomobject]@{ source='README.md'; stage='README.md' },
  [pscustomobject]@{ source='PUBLIC-RELEASE-REVIEW.md'; stage='PUBLIC-RELEASE-REVIEW.md' },
  [pscustomobject]@{ source='SECURITY.md'; stage='SECURITY.md' },
  [pscustomobject]@{ source='PRIVACY.md'; stage='PRIVACY.md' },
  [pscustomobject]@{ source='LICENSE'; stage='LICENSE' },
  [pscustomobject]@{ source='THIRD-PARTY-NOTICES.md'; stage='THIRD-PARTY-NOTICES.md' },
  [pscustomobject]@{ source='CHANGELOG.md'; stage='CHANGELOG.md' }
) + @(
  foreach ($assetPath in $expectedSemanticIconFiles) {
    [pscustomobject]@{ source=$assetPath; stage=$assetPath }
  }
)
$sourceStageMismatches = @(
  foreach ($mapping in $sourceStageMappings) {
    $sourcePath = Join-Path $ProjectRoot $mapping.source
    $stagedPath = Join-Path $stageRoot $mapping.stage
    if (
      -not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $stagedPath -PathType Leaf)
    ) {
      [pscustomobject]@{ source=$mapping.source; stage=$mapping.stage; reason='missing' }
      continue
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $stageHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash
    if (-not [string]::Equals(
        $sourceHash,
        $stageHash,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
      [pscustomobject]@{ source=$mapping.source; stage=$mapping.stage; reason='hash' }
    }
  }
)

$nodeRuntimeMismatches = @(
  foreach ($entry in @($nodeRuntimeManifest.files)) {
    $path = Join-Path $nodeRuntimeRoot ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      [pscustomobject]@{ path = [string]$entry.path; reason = 'missing' }
      continue
    }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (
      [int64]$entry.size -ne [int64]$item.Length -or
      -not [string]::Equals(
        [string]$entry.sha256,
        $hash,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      [pscustomobject]@{ path = [string]$entry.path; reason = 'size-or-hash' }
    }
  }
)

$sensitiveFindings = [System.Collections.Generic.List[object]]::new()
$textExtensions = @('.md', '.ps1', '.json', '.txt')
$sensitivePatterns = [ordered]@{
  fixedUserProfile = '(?i)\bC:\\Users\\[^%<\\]+'
  openAiKey = '(?i)\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}'
  genericSecret = '(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token)\s*[:=]\s*[''"][^''"]{6,}'
  privateKey = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
}
foreach ($file in Get-ChildItem -LiteralPath $stageRoot -Recurse -File) {
  $relativeFilePath = $file.FullName.Substring($stageRoot.Length).TrimStart('\')
  if ($relativeFilePath.StartsWith(
      'runtime\node\',
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    continue
  }
  if ($file.Extension.ToLowerInvariant() -notin $textExtensions) {
    continue
  }
  $content = Get-Content -LiteralPath $file.FullName -Raw
  foreach ($pattern in $sensitivePatterns.GetEnumerator()) {
    if ($content -match $pattern.Value) {
      $sensitiveFindings.Add([pscustomobject]@{
          path = $relativeFilePath
          rule = $pattern.Key
        })
    }
  }
}

$preExecutionIntegrityFailures = @(
  if ($missingStageFiles.Count -gt 0) { 'missing-stage-files' }
  if ($unexpectedStageFiles.Count -gt 0) { 'unexpected-stage-files' }
  if (-not $manifestCoverage) { 'manifest-coverage' }
  if ($manifestMismatches.Count -gt 0) { 'manifest-hashes' }
  if ($sourceStageMismatches.Count -gt 0) { 'source-stage-parity' }
  if ($nodeRuntimeMismatches.Count -gt 0) { 'node-runtime-hashes' }
  if ($sensitiveFindings.Count -gt 0) { 'sensitive-stage-text' }
)
if ($preExecutionIntegrityFailures.Count -gt 0) {
  throw (
    'Release candidate execution was refused because integrity validation ' +
    'failed: ' +
    ($preExecutionIntegrityFailures -join ', ')
  )
}

$mediaProbe = & powershell.exe `
  -NoLogo `
  -NoProfile `
  -NonInteractive `
  -STA `
  -ExecutionPolicy Bypass `
  -File $stageAppPath `
  -ProjectRoot $stageRoot `
  -MediaProbe |
  ConvertFrom-Json

$hostInfo = (Get-Item -LiteralPath $hostPath).VersionInfo
$hostSignature = Get-AuthenticodeSignature -LiteralPath $hostPath
$installerExists = (
  -not [string]::IsNullOrWhiteSpace($installerPath) -and
  (Test-Path -LiteralPath $installerPath -PathType Leaf)
)
$installerSignature = if ($installerExists) {
  Get-AuthenticodeSignature -LiteralPath $installerPath
} else {
  $null
}
$installerHashMatches = if ($installerExists) {
  [string]::Equals(
    [string]$manifest.installerSha256,
    (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash,
    [System.StringComparison]::OrdinalIgnoreCase
  )
} else {
  -not $RequireInstaller
}
$nodePath = Join-Path $nodeRuntimeRoot 'node.exe'
$npmPath = Join-Path $nodeRuntimeRoot 'npm.cmd'
$nodeVersion = if (Test-Path -LiteralPath $nodePath -PathType Leaf) {
  [string](& $nodePath --version 2>&1 | Select-Object -First 1)
} else {
  ''
}
$npmVersion = if (Test-Path -LiteralPath $npmPath -PathType Leaf) {
  [string](& $npmPath --version 2>&1 | Select-Object -First 1)
} else {
  ''
}
$nodeDependency = @(
  $manifest.dependencies |
    Where-Object { [string]$_.name -eq 'Node.js' }
) | Select-Object -First 1
$webView2Dependency = @(
  $manifest.dependencies |
    Where-Object { [string]$_.name -eq 'Microsoft.Web.WebView2' }
) | Select-Object -First 1

$checks = [ordered]@{
  manifestIdentity = (
    [string]$manifest.product -eq 'Workspace Widget' -and
    [string]$manifest.version -eq $Version -and
    [string]$manifest.platform -eq 'Windows 11 x64'
  )
  exactStageAllowlist = (
    $missingStageFiles.Count -eq 0 -and
    $unexpectedStageFiles.Count -eq 0
  )
  powershellParsers = @($parserResults | Where-Object { -not $_.valid }).Count -eq 0
  cleanPublicState = (
    [int]$stageState.schemaVersion -eq 4 -and
    @($stageState.items).Count -eq 0 -and
    $stageState.window.PSObject.Properties.Name -contains 'appearance'
  )
  nativeHostIdentity = (
    $hostInfo.ProductName -eq 'Workspace Widget' -and
    $hostInfo.OriginalFilename -eq 'WorkspaceWidget.exe' -and
    $hostInfo.ProductVersion -eq $Version
  )
  webView2MediaBridge = (
    $mediaProbe.success -and
    $mediaProbe.webView2AssembliesAvailable -and
    $mediaProbe.webView2ControlCreated -and
    $mediaProbe.nativeLoaderAvailable -and
    $mediaProbe.youtubePrivacyEnhancedEmbed
  )
  webView2DependencyPin = (
    $null -ne $webView2Dependency -and
    [string]$webView2Dependency.version -eq '1.0.4129.50' -and
    [string]$webView2Dependency.packageSha256 -eq
      'D3934F482D484B89FB4825DF720C710664E1143A1E90F7B3A60794EF33F473D2'
  )
  manifestCoverage = $manifestCoverage
  manifestHashes = $manifestMismatches.Count -eq 0
  sourceStageParity = $sourceStageMismatches.Count -eq 0
  installerHashMatches = $installerHashMatches
  installerAutostartStatePreserved = (
    $installerScriptContent -match "CreateOleObject\('Schedule\.Service'\)" -and
    $installerScriptContent -match 'Flags: checkedonce; Check: ShouldOfferAutostartTask' -and
    $installerScriptContent -match '(?s)function ShouldOfferAutostartTask\(\): Boolean;.*?not ExistingAutostartTaskFound' -and
    $installerScriptContent -match '(?s)function ShouldConfigureAutostart\(\): Boolean;.*?not ExistingAutostartTaskFound.*?WizardIsTaskSelected\(''autostart''\)' -and
    $installerScriptContent -match 'Parameters: "--autostart Repair --silent".*Check: ShouldRepairAutostart' -and
    $installerScriptContent -match 'Parameters: "--autostart Enable --silent".*Check: ShouldConfigureAutostart' -and
    $installerScriptContent -notmatch 'Parameters: "--autostart (Ensure|Disable) --silent"'
  )
  bundledNodeRuntime = (
    [string]$nodeRuntimeManifest.product -eq 'Node.js' -and
    [string]$nodeRuntimeManifest.version -eq '24.19.0' -and
    [string]$nodeRuntimeManifest.packageSha256 -eq
      '57F71AB3652E797D84ACDDC79C81CC9FF1C6DDB2A1974CDB83F00FEE9BFF4C73' -and
    [string]$nodeRuntimeManifest.sourceUrl -eq
      'https://nodejs.org/download/release/v24.19.0/node-v24.19.0-win-x64.zip' -and
    $nodeVersion -eq 'v24.19.0' -and
    -not [string]::IsNullOrWhiteSpace($npmVersion) -and
    $null -ne $nodeDependency -and
    [string]$nodeDependency.version -eq '24.19.0'
  )
  nodeRuntimeHashes = $nodeRuntimeMismatches.Count -eq 0
  noSensitiveStageText = $sensitiveFindings.Count -eq 0
  installerPresent = if ($RequireInstaller) { $installerExists } else { $true }
  signaturePolicy = if ($RequireSigned) {
    (
      $hostSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
      $installerExists -and
      $installerSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
    )
  } else {
    $true
  }
}
$signed = (
  $hostSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
  $installerExists -and
  $installerSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
)
$signatureManifestMatches = [bool]$manifest.signed -eq $signed
$checks['signatureManifestMatches'] = $signatureManifestMatches
if (-not [string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)) {
  $expectedThumbprint = $ExpectedSignerThumbprint.Replace(' ', '').ToUpperInvariant()
  $hostThumbprint = if ($null -ne $hostSignature.SignerCertificate) {
    [string]$hostSignature.SignerCertificate.Thumbprint
  } else {
    ''
  }
  $installerThumbprint = if (
    $null -ne $installerSignature -and
    $null -ne $installerSignature.SignerCertificate
  ) {
    [string]$installerSignature.SignerCertificate.Thumbprint
  } else {
    ''
  }
  $checks['expectedSigner'] = (
    $hostThumbprint.ToUpperInvariant() -eq $expectedThumbprint -and
    $installerThumbprint.ToUpperInvariant() -eq $expectedThumbprint
  )
}
$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })

[pscustomobject]@{
  success = $failed.Count -eq 0
  publicReady = $failed.Count -eq 0 -and $signed
  version = $Version
  failedChecks = @($failed | ForEach-Object { $_.Key })
  checks = $checks
  signed = $signed
  signatures = [ordered]@{
    host = $hostSignature.Status.ToString()
    installer = if ($null -ne $installerSignature) {
      $installerSignature.Status.ToString()
    } else {
      'Missing'
    }
  }
  stageRoot = $stageRoot
  installer = $installerPath
  missingStageFiles = $missingStageFiles
  unexpectedStageFiles = $unexpectedStageFiles
  parserResults = $parserResults
  manifestMismatches = $manifestMismatches
  sourceStageMismatches = $sourceStageMismatches
  nodeRuntimeMismatches = $nodeRuntimeMismatches
  nodeRuntime = [ordered]@{
    version = $nodeVersion
    npmVersion = $npmVersion
    packageSha256 = [string]$nodeRuntimeManifest.packageSha256
    fileCount = @($nodeRuntimeManifest.files).Count
  }
  sensitiveFindings = @($sensitiveFindings)
  mediaProbe = $mediaProbe
} | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
  exit 1
}
