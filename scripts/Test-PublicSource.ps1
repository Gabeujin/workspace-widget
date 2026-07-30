[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [string]$LocalDenylistPath
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
if ([string]::IsNullOrWhiteSpace($LocalDenylistPath)) {
  $LocalDenylistPath = Join-Path `
    $ProjectRoot `
    '.public-source-denylist.local.txt'
}
$LocalDenylistPath = [System.IO.Path]::GetFullPath($LocalDenylistPath)
$localPrivateTerms = @()
if (Test-Path -LiteralPath $LocalDenylistPath -PathType Leaf) {
  $localPrivateTerms = @(
    Get-Content -LiteralPath $LocalDenylistPath |
      ForEach-Object { ([string]$_).Trim() } |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not $_.StartsWith('#')
      } |
      Sort-Object -Unique
  )
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

function Get-TrackedFileText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $output = @(& git -C $ProjectRoot show ":$RelativePath" 2>&1)
  if ($LASTEXITCODE -ne 0) {
    Add-PublicSourceFinding `
      -Rule 'unreadable-index-blob' `
      -Path $RelativePath `
      -Detail 'The staged Git blob could not be read.'
    return ''
  }
  return [string]::Join(
    "`n",
    @($output | ForEach-Object { [string]$_ })
  )
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
  '.bat',
  '.cmd',
  '.cs',
  '.css',
  '.csv',
  '.htm',
  '.html',
  '.iss',
  '.js',
  '.json',
  '.md',
  '.mjs',
  '.cjs',
  '.ps1',
  '.psd1',
  '.psm1',
  '.sh',
  '.svg',
  '.txt',
  '.vbs',
  '.xml',
  '.yaml',
  '.yml'
)
$knownTextFileNames = @(
  '.editorconfig',
  '.gitattributes',
  '.gitignore',
  'CODEOWNERS',
  'Dockerfile',
  'LICENSE',
  'Makefile',
  'NOTICE'
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
  sourceCheckoutPath = '(?i)\b[A-Z]:\\(?:workspace|source|repos|dev)\\'
  localBuildPath = '(?i)\b[A-Z]:\\(?:WWBuild|WorkspaceWidgetBuilds)\\'
  signedMediaQuery = '(?i)[?&](?:token|signature|sig|hmac)=[^&\s)''"]{8,}'
  agentBackupPath = '(?i)\bCodex' + '-Change' + '-Backups\b'
}

foreach ($trackedFile in $trackedFiles) {
  $relativePath = $trackedFile.Replace('\', '/')
  $relativeLower = $relativePath.ToLowerInvariant()

  foreach ($localPrivateTerm in $localPrivateTerms) {
    if (
      $relativePath.IndexOf(
        $localPrivateTerm,
        [System.StringComparison]::OrdinalIgnoreCase
      ) -lt 0
    ) {
      continue
    }
    Add-PublicSourceFinding `
      -Rule 'local-private-path-term' `
      -Path $relativePath `
      -Detail 'A tracked path matches a maintainer-local denylist term.'
    break
  }

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
    $fileName -eq '.public-source-denylist.local.txt' -or
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
    $extension -notin $textExtensions -and
    $fileName -notin $knownTextFileNames
  ) {
    continue
  }

  $content = Get-TrackedFileText -RelativePath $relativePath
  foreach ($pattern in $sensitivePatterns.GetEnumerator()) {
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

  foreach ($localPrivateTerm in $localPrivateTerms) {
    $match = [regex]::Match(
      $content,
      [regex]::Escape($localPrivateTerm),
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
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
      -Rule 'local-private-term' `
      -Path $relativePath `
      -Line $line `
      -Detail 'A maintainer-local denylist term matched.'
    break
  }
}

$defaultStatePath = 'app/default-state.json'
$publicDefaultStatePath = 'app/public-default-state.json'
$defaultTemplatesMatch = $false
if (
  $defaultStatePath -notin $trackedFiles -or
  $publicDefaultStatePath -notin $trackedFiles
) {
  Add-PublicSourceFinding `
    -Rule 'missing-public-default' `
    -Path 'app' `
    -Detail 'Both default-state templates must exist.'
} else {
  $defaultStateText = Get-TrackedFileText -RelativePath $defaultStatePath
  $publicDefaultStateText = Get-TrackedFileText `
    -RelativePath $publicDefaultStatePath
  $defaultState = $defaultStateText | ConvertFrom-Json
  $publicDefaultState = $publicDefaultStateText | ConvertFrom-Json
  if (
    @($defaultState.items).Count -ne 0 -or
    @($publicDefaultState.items).Count -ne 0
  ) {
    Add-PublicSourceFinding `
      -Rule 'nonempty-public-default' `
      -Path 'app/default-state.json' `
      -Detail 'Public source defaults must not contain registered items.'
  }
  $defaultBlob = [string](
    & git -C $ProjectRoot rev-parse ":$defaultStatePath" 2>$null
  )
  $publicBlob = [string](
    & git -C $ProjectRoot rev-parse ":$publicDefaultStatePath" 2>$null
  )
  $defaultTemplatesMatch = (
    -not [string]::IsNullOrWhiteSpace($defaultBlob) -and
    $defaultBlob -eq $publicBlob
  )
  if (-not $defaultTemplatesMatch) {
    Add-PublicSourceFinding `
      -Rule 'default-template-drift' `
      -Path 'app/default-state.json' `
      -Detail 'The source and public default templates must be byte-identical.'
  }
}

$commitEmailOutput = @(
  & git -C $ProjectRoot log --all --format='%ae%n%ce' 2>&1
)
$commitHistoryExitCode = $LASTEXITCODE
$commitEmails = @()
if ($commitHistoryExitCode -ne 0) {
  Add-PublicSourceFinding `
    -Rule 'git-history-enumeration-failed' `
    -Path '.git' `
    -Detail 'Git commit metadata could not be enumerated.'
} else {
  $commitEmails = @(
    $commitEmailOutput |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )
}
if ($commitEmails.Count -eq 0) {
  Add-PublicSourceFinding `
    -Rule 'empty-git-history' `
    -Path '.git' `
    -Detail 'No commit email metadata was found.'
}
foreach ($commitEmail in $commitEmails) {
  if (
    $commitEmail -notmatch (
      '(?i)^(?:(?:\d+\+)?[A-Z0-9-]+(?:\[bot\])?' +
      '@users\.noreply\.github\.com|' +
      'noreply@github\.com)$'
    )
  ) {
    Add-PublicSourceFinding `
      -Rule 'unexpected-public-commit-email' `
      -Path '.git' `
      -Detail 'A commit email is not a GitHub noreply address.'
  }
  foreach ($localPrivateTerm in $localPrivateTerms) {
    if (
      $commitEmail.IndexOf(
        $localPrivateTerm,
        [System.StringComparison]::OrdinalIgnoreCase
      ) -lt 0
    ) {
      continue
    }
    Add-PublicSourceFinding `
      -Rule 'local-private-email-term' `
      -Path '.git' `
      -Detail 'A commit email matches a maintainer-local denylist term.'
    break
  }
}

$result = [pscustomobject][ordered]@{
  success = $findings.Count -eq 0
  trackedFileCount = $trackedFiles.Count
  commitEmailCount = $commitEmails.Count
  localDenylistTermCount = $localPrivateTerms.Count
  defaultTemplatesMatch = $defaultTemplatesMatch
  findingCount = $findings.Count
  findings = @($findings)
}

$result | ConvertTo-Json -Depth 6
if (-not $result.success) {
  exit 1
}
