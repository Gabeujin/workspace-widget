[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [datetime]$AsOf = (Get-Date)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')

function Read-RequiredText {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $path = Join-Path $ProjectRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required security input was not found: $RelativePath"
  }
  return Get-Content -LiteralPath $path -Raw
}

$baselinePath = Join-Path $ProjectRoot 'security\official-security-baseline.json'
if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
  throw 'Official security baseline was not found.'
}
$baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
$securityReviewPath = Join-Path $ProjectRoot 'security\official-security-review.json'
if (-not (Test-Path -LiteralPath $securityReviewPath -PathType Leaf)) {
  throw 'Official security review receipt was not found.'
}
$securityReview = Get-Content -LiteralPath $securityReviewPath -Raw | ConvertFrom-Json
$reviewedAt = [datetime]::ParseExact(
  [string]$baseline.reviewedAt,
  'yyyy-MM-dd',
  [Globalization.CultureInfo]::InvariantCulture
)
$reviewBy = [datetime]::ParseExact(
  [string]$baseline.reviewBy,
  'yyyy-MM-dd',
  [Globalization.CultureInfo]::InvariantCulture
)
$asOfDate = $AsOf.Date
$securityCheckedAt = [datetime]::ParseExact(
  [string]$securityReview.checkedAt,
  'yyyy-MM-dd',
  [Globalization.CultureInfo]::InvariantCulture
)
$securityValidThrough = [datetime]::ParseExact(
  [string]$securityReview.validThrough,
  'yyyy-MM-dd',
  [Globalization.CultureInfo]::InvariantCulture
)

$nodeRestore = Read-RequiredText 'scripts\Restore-WorkspaceWidgetNodeRuntime.ps1'
$webViewRestore = Read-RequiredText 'scripts\Restore-WorkspaceWidgetDependencies.ps1'
$releaseVerifier = Read-RequiredText 'scripts\Test-WorkspaceWidgetRelease.ps1'
$app = Read-RequiredText 'app\WorkspaceWidget.ps1'
$workflow = Read-RequiredText '.github\workflows\public-source.yml'
$manifestText = Read-RequiredText 'packaging\msix\AppxManifest.template.xml'
$defaultStateText = Read-RequiredText 'app\default-state.json'
$publicDefaultStateText = Read-RequiredText 'app\public-default-state.json'
$appPath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$startupFixture = Join-Path $ProjectRoot 'tests\fixtures\node-health-app\server.js'

$validStartupProbeOutput = @(
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appPath `
    -ProjectRoot $ProjectRoot `
    -StartupTargetProbe `
    -StartupProbeTarget $startupFixture `
    -StartupProbeArgs '--port=43123' 2>&1
)
$validStartupProbeExit = $LASTEXITCODE
$validStartupProbe = ($validStartupProbeOutput -join [Environment]::NewLine) |
  ConvertFrom-Json
$invalidUncProbeOutput = @(
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appPath `
    -ProjectRoot $ProjectRoot `
    -StartupTargetProbe `
    -StartupProbeTarget '\\example.invalid\share\server.js' 2>&1
)
$invalidUncProbeExit = $LASTEXITCODE
$invalidUncProbe = ($invalidUncProbeOutput -join [Environment]::NewLine) |
  ConvertFrom-Json
$encodedProbeValues = [ordered]@{
  app = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($appPath))
  root = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ProjectRoot))
  target = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($startupFixture))
  arguments = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('bad"argument'))
}
$invalidArgumentProbeScript = @"
`$decode = { param([string]`$value) [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(`$value)) }
& (& `$decode '$($encodedProbeValues.app)') -ProjectRoot (& `$decode '$($encodedProbeValues.root)') -StartupTargetProbe -StartupProbeTarget (& `$decode '$($encodedProbeValues.target)') -StartupProbeArgs (& `$decode '$($encodedProbeValues.arguments)')
"@
$invalidArgumentProbeEncoded = [Convert]::ToBase64String(
  [Text.Encoding]::Unicode.GetBytes($invalidArgumentProbeScript)
)
$invalidArgumentProbeOutput = @(
  & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -EncodedCommand $invalidArgumentProbeEncoded 2>&1
)
$invalidArgumentProbeExit = $LASTEXITCODE
$invalidArgumentProbe = ($invalidArgumentProbeOutput -join [Environment]::NewLine) |
  ConvertFrom-Json
$invalidRelativeProbeOutput = @(
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appPath `
    -ProjectRoot $ProjectRoot `
    -StartupTargetProbe `
    -StartupProbeTarget 'server.js' 2>&1
)
$invalidRelativeProbeExit = $LASTEXITCODE
$invalidRelativeProbe = ($invalidRelativeProbeOutput -join [Environment]::NewLine) |
  ConvertFrom-Json

[xml]$manifest = $manifestText
$capabilities = @(
  $manifest.Package.Capabilities.ChildNodes |
    Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element } |
    ForEach-Object { [string]$_.Name }
)
$startupTask = @(
  $manifest.Package.Applications.Application.Extensions.ChildNodes |
    ForEach-Object { $_.ChildNodes } |
    Where-Object { $_.LocalName -eq 'StartupTask' }
) | Select-Object -First 1

$nodeVersion = [regex]::Escape([string]$baseline.components.node.version)
$nodeHash = [regex]::Escape([string]$baseline.components.node.sha256)
$nodeSource = [regex]::Escape([string]$baseline.components.node.source)
$webViewVersion = [regex]::Escape([string]$baseline.components.webView2.sdkVersion)
$webViewHash = [regex]::Escape([string]$baseline.components.webView2.packageSha256)
$webViewSource = [regex]::Escape([string]$baseline.components.webView2.source)

$trackedPaths = @(& git -C $ProjectRoot ls-files)
if ($LASTEXITCODE -ne 0) {
  throw 'git ls-files failed while checking local-path contamination.'
}
$localPathFindings = @(
  foreach ($relativePath in $trackedPaths) {
    $path = Join-Path $ProjectRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -notin @('.ps1', '.psm1', '.cs', '.xml', '.json', '.yml', '.yaml', '.md', '.txt')) {
      continue
    }
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -match '(?i)\b[A-Z]:\\Users\\(?!<)|\bD:\\workspace\\') {
      $relativePath
    }
  }
)

$checks = [ordered]@{
  baselineSchema = [int]$baseline.schemaVersion -eq 1
  baselineDates = $reviewedAt -le $reviewBy -and $asOfDate -le $reviewBy
  reviewAge = ($reviewBy - $reviewedAt).TotalDays -le [int]$baseline.releasePolicy.maximumReviewAgeDays
  releaseSecurityReceiptFresh = [int]$securityReview.schemaVersion -eq 1 -and
    $securityCheckedAt -le $asOfDate -and
    $asOfDate -le $securityValidThrough -and
    ($securityValidThrough - $securityCheckedAt).TotalDays -le
      [int]$baseline.releasePolicy.maximumReleaseSecurityReceiptAgeDays -and
    @($securityReview.unresolvedHighOrCriticalAffectingCandidate).Count -eq 0
  releaseSecurityReceiptVersions = [string]$securityReview.node.candidateVersion -eq
      [string]$baseline.components.node.version -and
    [string]$securityReview.node.latestLtsVersionObserved -eq
      [string]$baseline.components.node.version -and
    [string]$securityReview.webView2.candidateSdkVersion -eq
      [string]$baseline.components.webView2.sdkVersion -and
    [string]$securityReview.webView2.latestStableSdkVersionObserved -eq
      [string]$baseline.components.webView2.sdkVersion -and
    [string]$securityReview.webView2.sdkCompatibilityRuntimeObserved -eq '151.0.4129.50'
  emergencyReviewPolicy = @($baseline.releasePolicy.emergencyReviewTriggers).Count -ge 3 -and
    @($baseline.releasePolicy.emergencyReviewTriggers | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_)
      }).Count -eq 0
  officialSourceSet = @($baseline.officialSources).Count -ge 9 -and
    @($baseline.officialSources | Where-Object { $_ -notmatch '^https://' }).Count -eq 0
  officialComponentSources = [string]$baseline.components.node.releaseNotes -match '^https://nodejs\.org/' -and
    [string]$baseline.components.node.securityAdvisories -eq 'https://nodejs.org/en/blog/vulnerability/' -and
    [string]$baseline.components.webView2.releaseNotes -match '^https://learn\.microsoft\.com/' -and
    [string]$baseline.components.webView2.runtimeReleaseNotes -match '^https://learn\.microsoft\.com/'
  nodeRestorePin = $nodeRestore -match "Version = '$nodeVersion'" -and
    $nodeRestore -match $nodeHash -and
    $nodeRestore -match 'https://nodejs\.org/download/release/v\$Version/\$distributionName\.zip'
  nodeRuntimeCacheArchiveBound = $nodeRestore -match 'function Get-ArchiveRuntimeInventory' -and
    $nodeRestore -match 'function Test-RuntimeMatchesArchive' -and
    $nodeRestore -match '-ArchiveFiles \$archiveRuntimeFiles' -and
    $nodeRestore.IndexOf('Test-RuntimeMatchesArchive -RuntimeRoot', [System.StringComparison]::Ordinal) -ge 0 -and
    $nodeRestore.IndexOf('$actualVersion = (& $nodePath --version', [System.StringComparison]::Ordinal) -gt
      $nodeRestore.IndexOf('Test-RuntimeMatchesArchive -RuntimeRoot', [System.StringComparison]::Ordinal)
  nodeReleaseVerificationPin = $releaseVerifier -match $nodeVersion -and
    $releaseVerifier -match $nodeHash -and $releaseVerifier -match $nodeSource
  webView2RestorePin = $webViewRestore -match "WebView2Version = '$webViewVersion'" -and
    $webViewRestore -match $webViewHash -and $webViewRestore -match $webViewSource
  externalBuildWorkspace = $nodeRestore -match 'WorkspaceWidget\\DependencyCache' -and
    $webViewRestore -match 'WorkspaceWidget\\DependencyCache'
  packageRuntimeIsolation = $app -match '\$packageRuntimeEnforced' -and
    $app -match "'PackageLocal'" -and
    $app -match "'PackageLocalMissing'" -and
    $app -match '\$nodeCandidates = @\(\$packageNodePath\)'
  startupTrustBoundary = $app -match 'function Resolve-NodeStartupConfiguration' -and
    $app -match 'Network and device paths are not supported' -and
    $app -match 'Automatic Node startup requires a loopback health URL' -and
    $app -match 'Stop-ProcessTree' -and
    $app -match 'Force-stop local server'
  startupTrustBoundaryBehavior = $validStartupProbeExit -eq 0 -and
    [bool]$validStartupProbe.success -and
    [string]$validStartupProbe.kind -eq 'file' -and
    $invalidUncProbeExit -ne 0 -and
    -not [bool]$invalidUncProbe.success -and
    $invalidArgumentProbeExit -ne 0 -and
    -not [bool]$invalidArgumentProbe.success -and
    $invalidRelativeProbeExit -ne 0 -and
    -not [bool]$invalidRelativeProbe.success
  urlTrustBoundary = $app -match 'function Get-ValidatedWebUri' -and
    $app -match '\$candidate\.UserInfo'
  boundedLocalStateAndMedia = $app -match '\$script:maximumStateBytes = 4MB' -and
    $app -match '\$script:maximumShortcutCount = 250' -and
    $app -match '\$script:maximumManagedCacheBytes = 128MB' -and
    $app -match 'function Get-ValidatedLocalMediaInfo'
  stateSchemaFailClosed = $app -match '\[int\]\$candidateState\.schemaVersion -gt 4' -and
    $app -match 'throw \[System\.NotSupportedException\]::new' -and
    $app -match 'State read stopped to preserve a newer schema'
  webView2Isolation = $app -match 'AreHostObjectsAllowed = \$false' -and
    $app -match 'IsWebMessageEnabled = \$false' -and
    $app -match 'PermissionState\]::Deny' -and
    $app -match '\$downloadArgs\.Cancel = \$true'
  manifestMediumIntegrity = [string]$manifest.Package.Applications.Application.TrustLevel -eq 'mediumIL'
  manifestCapabilityAllowlist = $capabilities.Count -eq 1 -and $capabilities[0] -eq 'runFullTrust'
  startupDisabledByDefault = $null -ne $startupTask -and [string]$startupTask.Enabled -eq 'false'
  cleanPublicDefaults = $defaultStateText -ceq $publicDefaultStateText -and
    @($defaultStateText | ConvertFrom-Json | Select-Object -ExpandProperty items).Count -eq 0
  noTrackedLocalPathContamination = $localPathFindings.Count -eq 0
  workflowPinnedCheckout = $workflow -match 'actions/checkout@[0-9a-f]{40}' -and
    $workflow -notmatch 'actions/checkout@v\d'
  workflowRunsBaseline = $workflow -match 'Test-OfficialSecurityBaseline\.ps1'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value })
$result = [pscustomobject][ordered]@{
  success = $failed.Count -eq 0
  reviewedAt = $baseline.reviewedAt
  reviewBy = $baseline.reviewBy
  asOf = $asOfDate.ToString('yyyy-MM-dd')
  failedChecks = @($failed | ForEach-Object Key)
  checks = $checks
  localPathFindings = $localPathFindings
  components = $baseline.components
  startupTargetProbes = [ordered]@{
    valid = $validStartupProbe
    invalidUnc = $invalidUncProbe
    invalidArguments = $invalidArgumentProbe
  }
}
$result | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) {
  exit 1
}
