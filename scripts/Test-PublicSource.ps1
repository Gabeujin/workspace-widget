[CmdletBinding()]
param(
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$gitDirectory = Join-Path $ProjectRoot '.git'
if (-not (Test-Path -LiteralPath $gitDirectory)) {
  throw 'Public-source verification requires a Git checkout.'
}

$findings = [System.Collections.Generic.List[object]]::new()

function Add-PublicSourceFinding {
  param(
    [Parameter(Mandatory = $true)][string]$Rule,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Detail = '',
    [int]$Line = 0
  )

  $findings.Add([pscustomobject][ordered]@{
      rule = $Rule
      path = $Path
      line = $Line
      detail = $Detail
    })
}

$trackedFiles = @(
  & git -C $ProjectRoot ls-files 2>&1 |
    ForEach-Object { [string]$_ } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($LASTEXITCODE -ne 0) {
  throw "git ls-files failed: $($trackedFiles -join [Environment]::NewLine)"
}
if ($trackedFiles.Count -eq 0) {
  Add-PublicSourceFinding `
    -Rule 'empty-tracked-set' `
    -Path '.' `
    -Detail 'No tracked source files were found.'
}

$forbiddenPrefixes = @(
  'artifacts/',
  'bin/',
  'build/',
  'coverage/',
  'design/',
  'diagnostics/',
  'dist/',
  'obj/',
  'out/',
  'quality/',
  'release/',
  'runtime/',
  'skin/',
  'staging/',
  'testresults/'
)
$forbiddenExtensions = @(
  '.7z',
  '.appinstaller',
  '.appx',
  '.appxbundle',
  '.bak',
  '.cer',
  '.crt',
  '.db',
  '.dll',
  '.dmp',
  '.dump',
  '.enc',
  '.exe',
  '.jks',
  '.kdbx',
  '.key',
  '.keystore',
  '.lnk',
  '.log',
  '.msi',
  '.msix',
  '.msixbundle',
  '.p12',
  '.pdb',
  '.pem',
  '.pfx',
  '.rar',
  '.snk',
  '.sqlite',
  '.sqlite3',
  '.tmp',
  '.trx',
  '.url',
  '.zip'
)

$textExtensions = @(
  '.cmd',
  '.cs',
  '.iss',
  '.js',
  '.json',
  '.md',
  '.mjs',
  '.cjs',
  '.ps1',
  '.txt',
  '.xml',
  '.yaml',
  '.yml'
)
$sensitivePatterns = [ordered]@{
  privateKey = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
  openAiKey = '(?i)\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}'
  githubToken = '\bgh[pousr]_[A-Za-z0-9]{20,}'
  awsAccessKey = '\bAKIA[A-Z0-9]{16}\b'
  slackToken = '\bxox[baprs]-[A-Za-z0-9-]{20,}'
  bearerCredential = '(?i)\bBearer\s+[A-Za-z0-9._~-]{20,}'
  urlCredential = '(?i)https?://[^/\s:@]+:[^/\s@]+@'
  passwordLiteral = '(?i)\b(?:password|passwd)\s*[:=]\s*[''"][^''"]{6,}[''"]'
  apiKeyLiteral = '(?i)\bapi[_-]?key\s*[:=]\s*[''"][^''"]{12,}[''"]'
  emailAddress = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
  fixedWindowsUserPath = '(?i)\b[A-Z]:\\Users\\(?!<)'
  privateWorkspacePath = '(?i)\bD:\\workspace\\'
  signedMediaQuery = '(?i)[?&](?:token|signature|sig|hmac)=[^&\s)''"]{8,}'
  internalTerms = '(?i)\b(?:LEGOGov|Tibero|WebSquare|LocalDock)\b|KTC Board|Work Archive|Business Platform'
  developmentEnvironment = '(?i)codex-runtimes|Codex-Change-Backups|Codex Security|OpenAI Codex for Administrator'
  privateExampleVideo = '\bdhfS-JlD3iM\b'
  privateEvidenceReference = '(?i)\bquality/'
}

foreach ($trackedFile in $trackedFiles) {
  $relativePath = $trackedFile.Replace('\', '/')
  $relativeLower = $relativePath.ToLowerInvariant()
  $fullPath = Join-Path $ProjectRoot $trackedFile

  foreach ($prefix in $forbiddenPrefixes) {
    if ($relativeLower.StartsWith($prefix)) {
      Add-PublicSourceFinding `
        -Rule 'forbidden-tracked-path' `
        -Path $relativePath `
        -Detail "Tracked path is inside '$prefix'."
      break
    }
  }

  $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
  if ($extension -in $forbiddenExtensions) {
    Add-PublicSourceFinding `
      -Rule 'forbidden-tracked-extension' `
      -Path $relativePath `
      -Detail "Tracked extension '$extension' is not allowed."
  }

  $fileName = [System.IO.Path]::GetFileName($relativePath)
  if (
    $fileName -eq '.env' -or
    ($fileName.StartsWith('.env.') -and $fileName -ne '.env.example') -or
    $fileName -eq '.localdock.json' -or
    $fileName -eq 'state.json' -or
    $fileName -eq 'state.json.previous' -or
    $fileName -eq 'design-qa.md'
  ) {
    Add-PublicSourceFinding `
      -Rule 'forbidden-local-file' `
      -Path $relativePath `
      -Detail 'Tracked file is local state, configuration, or private QA evidence.'
  }

  if (
    $relativeLower -like 'packaging/msix/store-identity*.json' -and
    $relativeLower -ne 'packaging/msix/store-identity.example.json'
  ) {
    Add-PublicSourceFinding `
      -Rule 'real-store-identity' `
      -Path $relativePath `
      -Detail 'Only the placeholder Store identity example may be tracked.'
  }

  if (
    $extension -notin $textExtensions -or
    -not (Test-Path -LiteralPath $fullPath -PathType Leaf)
  ) {
    continue
  }

  $content = [System.IO.File]::ReadAllText($fullPath)
  foreach ($pattern in $sensitivePatterns.GetEnumerator()) {
    if (
      $relativePath -eq 'scripts/Test-PublicSource.ps1' -and
      $pattern.Key -in @(
        'internalTerms',
        'developmentEnvironment',
        'privateExampleVideo',
        'privateEvidenceReference'
      )
    ) {
      continue
    }

    $match = [regex]::Match($content, [string]$pattern.Value)
    if (-not $match.Success) {
      continue
    }
    $line = 1
    if ($match.Index -gt 0) {
      $line = (
        $content.Substring(0, $match.Index) -split "\r?\n"
      ).Count
    }
    Add-PublicSourceFinding `
      -Rule $pattern.Key `
      -Path $relativePath `
      -Line $line `
      -Detail 'Sensitive or private content pattern matched.'
  }
}

$defaultStatePath = Join-Path $ProjectRoot 'app\default-state.json'
$publicDefaultStatePath = Join-Path `
  $ProjectRoot `
  'app\public-default-state.json'
if (
  -not (Test-Path -LiteralPath $defaultStatePath -PathType Leaf) -or
  -not (Test-Path -LiteralPath $publicDefaultStatePath -PathType Leaf)
) {
  Add-PublicSourceFinding `
    -Rule 'missing-public-default' `
    -Path 'app' `
    -Detail 'Both default-state templates must exist.'
} else {
  $defaultState = Get-Content -LiteralPath $defaultStatePath -Raw |
    ConvertFrom-Json
  $publicDefaultState = Get-Content `
    -LiteralPath $publicDefaultStatePath `
    -Raw |
    ConvertFrom-Json
  if (
    @($defaultState.items).Count -ne 0 -or
    @($publicDefaultState.items).Count -ne 0
  ) {
    Add-PublicSourceFinding `
      -Rule 'nonempty-public-default' `
      -Path 'app/default-state.json' `
      -Detail 'Public source defaults must not contain registered items.'
  }
  $defaultHash = (
    Get-FileHash -LiteralPath $defaultStatePath -Algorithm SHA256
  ).Hash
  $publicHash = (
    Get-FileHash -LiteralPath $publicDefaultStatePath -Algorithm SHA256
  ).Hash
  if ($defaultHash -ne $publicHash) {
    Add-PublicSourceFinding `
      -Rule 'default-template-drift' `
      -Path 'app/default-state.json' `
      -Detail 'The source and public default templates must be byte-identical.'
  }
}

$commitEmails = @(
  & git -C $ProjectRoot log --all --format='%ae%n%ce' 2>$null |
    ForEach-Object { [string]$_ } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
)
foreach ($commitEmail in $commitEmails) {
  if ($commitEmail -match '(?i)@ktc\.re\.kr$') {
    Add-PublicSourceFinding `
      -Rule 'company-email-in-history' `
      -Path '.git' `
      -Detail 'A commit author or committer email uses a company domain.'
  }
}

$result = [pscustomobject][ordered]@{
  success = $findings.Count -eq 0
  trackedFileCount = $trackedFiles.Count
  commitEmailCount = $commitEmails.Count
  defaultTemplatesMatch = if (
    (Test-Path -LiteralPath $defaultStatePath -PathType Leaf) -and
    (Test-Path -LiteralPath $publicDefaultStatePath -PathType Leaf)
  ) {
    (
      Get-FileHash -LiteralPath $defaultStatePath -Algorithm SHA256
    ).Hash -eq (
      Get-FileHash -LiteralPath $publicDefaultStatePath -Algorithm SHA256
    ).Hash
  } else {
    $false
  }
  findingCount = $findings.Count
  findings = @($findings)
}

$result | ConvertTo-Json -Depth 6
if (-not $result.success) {
  exit 1
}
