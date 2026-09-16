[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $ProjectRoot 'scripts\Repair-WorkspaceWidgetLifecycle.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Repair script did not parse.' }
$assignment = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  $node.Left.Extent.Text -ceq '$blockingWidget'
}, $true)
if ($null -eq $assignment) { throw 'Production process gate was not found.' }
$ExpectedPreviousHost = 'C:\widget-test\previous\WorkspaceWidget.exe'
$targetHost = 'C:\widget-test\next\WorkspaceWidget.exe'
$cases = @(
  @{ name='previous-ui'; path=$ExpectedPreviousHost; args='--state-path state.json'; blocked=$true },
  @{ name='previous-supervisor'; path=$ExpectedPreviousHost; args='--service-supervisor 0123456789abcdef0123456789abcdef'; blocked=$false },
  @{ name='destination-supervisor'; path=$targetHost; args='--service-supervisor 0123456789abcdef0123456789abcdef'; blocked=$true },
  @{ name='unrelated-ui'; path='C:\widget-test\qa\WorkspaceWidget.exe'; args='--state-path test.json'; blocked=$false },
  @{ name='malformed-supervisor'; path=$ExpectedPreviousHost; args='--service-supervisor invalid'; blocked=$true },
  @{ name='embedded-supervisor-argument'; path=$ExpectedPreviousHost; args='--state-path "--service-supervisor 0123456789abcdef0123456789abcdef"'; blocked=$true },
  @{ name='unreadable-process'; path=''; args=''; blocked=$true }
)
foreach ($case in $cases) {
  $runningWidget = @([pscustomobject]@{ExecutablePath=$case.path; CommandLine=('"' + $case.path + '" ' + $case.args)})
  Invoke-Expression $assignment.Extent.Text
  if (($blockingWidget.Count -gt 0) -ne $case.blocked) { throw "Upgrade gate failed: $($case.name)" }
}
[pscustomobject]@{success=$true; assertions=$cases.Count; scope='production process predicate, synthetic identities only'} | ConvertTo-Json -Compress
