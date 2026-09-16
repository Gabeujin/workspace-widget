[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Assert-That {
  param([bool]$Condition, [string]$Message)
  if (!$Condition) { throw $Message }
}

$experiencePath = Join-Path $ProjectRoot 'app\WidgetExperience.ps1'
$workspacePath = Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($workspacePath, [ref]$tokens, [ref]$errors)
Assert-That ($errors.Count -eq 0) 'WorkspaceWidget source does not parse.'
. $experiencePath
$script:state = [pscustomobject]@{ window = [pscustomobject]@{ language = 'en-US' } }

$keys = @(
  'Remove ''{0}'' from Workspace?{1}{1}The original file, application, folder, or URL will not be deleted.',
  '{0} removed from Workspace',
  'Name and target are required.',
  'Workspace supports up to {0} shortcuts.',
  'Use an absolute http/https URL without embedded credentials, or an existing local path.',
  'The shortcut target could not be resolved.',
  'The resolved target no longer exists:{0}{1}',
  'Health URL must be an absolute http/https URL without embedded credentials.',
  'Wait for the HTTPS icon preview, then confirm that it is the icon you want.',
  'Custom icon must be a readable local PNG, JPG, BMP, ICO, or GIF file, or a verified public HTTPS image URL.',
  'Hover media must be a supported local file, public HTTPS image, or YouTube link.',
  'A Node start target can only be paired with a loopback health URL such as http://127.0.0.1:3000/health. Remote health monitoring remains available when no Node start target is configured.',
  'Node start target must be an existing JS entry file or project folder.',
  'A Node project folder must contain package.json.',
  'For a project folder, enter one package script name such as dev or start.',
  'A start script file must end in .js, .mjs, .cjs, or .ps1.',
  'Workspace could not save this registration. No changes were kept.',
  'The server ''{0}'' did not finish stopping within 40 seconds.{1}{1}Force-stop its verified process group? Unsaved server work may be lost.',
  'Force-stop local server'
)

$checks = [ordered]@{}
foreach ($key in $keys) {
  $script:state.window.language = 'ko-KR'
  $korean = Get-WidgetText $key
  $checks["korean-$key"] = -not [string]::Equals($korean, $key, [StringComparison]::Ordinal)
  Assert-That $checks["korean-$key"] "Korean dialog key was not localized: $key"
  foreach ($placeholder in @('{0}', '{1}')) {
    if ($key.Contains($placeholder)) {
      $checks["placeholder-$key-$placeholder"] = $korean.Contains($placeholder)
      Assert-That $checks["placeholder-$key-$placeholder"] "Korean dialog template lost ${placeholder}: $key"
    }
  }
  $script:state.window.language = 'en-US'
  $checks["english-$key"] = [string]::Equals((Get-WidgetText $key), $key, [StringComparison]::Ordinal)
  Assert-That $checks["english-$key"] "English dialog key did not round-trip: $key"
}

$functionKeys = @{
  'Remove-ItemRegistration' = @($keys[0], $keys[1])
  'Show-ItemDialog' = @($keys[2..16])
  'Stop-TrackedLocalServer' = @($keys[17..18])
}
foreach ($name in $functionKeys.Keys) {
  $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Assert-That ($null -ne $definition) "Missing production function: $name"
  foreach ($key in $functionKeys[$name]) {
    $claim = "Get-WidgetText '$($key.Replace("'", "''"))'"
    $checks["source-$name-$key"] = $definition.Extent.Text.Contains($claim)
    Assert-That $checks["source-$name-$key"] "Production dialog does not use the locale lookup: $name / $key"
  }
}

$script:state.window.language = 'ko-KR'
$force = (Get-WidgetText $keys[17]) -f 'Fixture server', [Environment]::NewLine
Assert-That ($force.Contains('40') -and -not $force.Contains('{0}') -and -not $force.Contains('{1}')) 'Korean force-stop warning lost its timeout or did not format the consent prompt.'
$checks.forceWarningPreservesTimeoutAndFormats = $true

[pscustomobject]@{
  success = $true
  checks = $checks.Count
  scope = 'Production dictionary lookup plus AST assertions for registration validation, deletion, and verified force-stop dialog templates; no UI, server, or user state was touched.'
} | ConvertTo-Json -Compress
