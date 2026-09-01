[CmdletBinding()]
param(
  [string]$ProjectRoot,
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '0.1.2',
  [string]$OutputRoot,
  [string]$CertificateThumbprint,
  [string]$TimestampUrl,
  [string]$SignToolPath,
  [string]$CompilerPath,
  [string]$SystemRuntimeFacadePath,
  [string]$SourceRevision,
  [switch]$SkipInstaller
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

$sourceDirty = $null
$gitMetadataPath = Join-Path $ProjectRoot '.git'
if (Test-Path -LiteralPath $gitMetadataPath) {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
  if ([string]::IsNullOrWhiteSpace($git)) {
    throw 'Git metadata exists but git.exe was not found.'
  }
  $detectedRevision = (& $git -C $ProjectRoot rev-parse HEAD 2>$null) -join ''
  if ($LASTEXITCODE -ne 0 -or $detectedRevision -notmatch '^[0-9a-fA-F]{40,64}$') {
    throw 'The source revision could not be resolved from Git.'
  }
  if (
    -not [string]::IsNullOrWhiteSpace($SourceRevision) -and
    -not [string]::Equals(
      $SourceRevision,
      $detectedRevision,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw 'SourceRevision does not match the checked-out Git HEAD.'
  }
  $SourceRevision = $detectedRevision.ToLowerInvariant()
  $sourceStatus = (& $git -C $ProjectRoot status --porcelain --untracked-files=all 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw 'The Git working-tree state could not be inspected.'
  }
  $sourceDirty = -not [string]::IsNullOrWhiteSpace($sourceStatus)
} else {
  if (-not [string]::IsNullOrWhiteSpace($SourceRevision)) {
    throw 'SourceRevision cannot be asserted without repository Git metadata.'
  }
  $SourceRevision = 'unversioned'
}

if (-not [string]::IsNullOrWhiteSpace($CompilerPath)) {
  $compiler = [System.IO.Path]::GetFullPath($CompilerPath)
} else {
  $compilerCandidates = [System.Collections.Generic.List[string]]::new()
  foreach ($visualStudioRoot in @(
      (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022'),
      (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022')
    )) {
    if (-not (Test-Path -LiteralPath $visualStudioRoot -PathType Container)) {
      continue
    }
    foreach ($edition in Get-ChildItem -LiteralPath $visualStudioRoot -Directory) {
      $candidate = Join-Path `
        $edition.FullName `
        'MSBuild\Current\Bin\Roslyn\csc.exe'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $compilerCandidates.Add($candidate)
      }
    }
  }
  $frameworkCompiler = Join-Path `
    $env:WINDIR `
    'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (Test-Path -LiteralPath $frameworkCompiler -PathType Leaf) {
    $compilerCandidates.Add($frameworkCompiler)
  }
  $compiler = $compilerCandidates | Select-Object -First 1
}
$automationAssembly = Get-ChildItem `
  -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') `
  -Recurse `
  -Filter 'System.Management.Automation.dll' `
  -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
$windowsWinMd = Get-ChildItem `
  -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\UnionMetadata') `
  -Recurse `
  -Filter 'Windows.winmd' `
  -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\Facade\\' } |
  Sort-Object FullName -Descending |
  Select-Object -First 1 -ExpandProperty FullName
$windowsRuntimeAssembly = Join-Path `
  $env:WINDIR `
  'Microsoft.NET\Framework64\v4.0.30319\System.Runtime.WindowsRuntime.dll'
if ([string]::IsNullOrWhiteSpace($SystemRuntimeFacadePath)) {
  $facadeSearchRoots = @(
    (Join-Path `
      ${env:ProgramFiles(x86)} `
      'Reference Assemblies\Microsoft\Framework\.NETFramework'),
    $(if (-not [string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) {
        $env:NUGET_PACKAGES
      }),
    (Join-Path `
      $env:USERPROFILE `
      '.nuget\packages\microsoft.netframework.referenceassemblies.net48')
  ) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
    (Test-Path -LiteralPath $_ -PathType Container)
  }
  $SystemRuntimeFacadePath = $facadeSearchRoots |
    ForEach-Object {
      Get-ChildItem `
        -LiteralPath $_ `
        -Recurse `
        -File `
        -Filter 'System.Runtime.dll' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\Facades\\' }
    } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
$hostSource = Join-Path $ProjectRoot 'native\WorkspaceWidgetHost.cs'
$iconPath = Join-Path $ProjectRoot 'assets\workspace-widget.ico'
$buildRoot = Join-Path $OutputRoot 'build'
$stageRoot = Join-Path $OutputRoot 'staging\WorkspaceWidget'
$hostExecutable = Join-Path $buildRoot 'WorkspaceWidget.exe'
$generatedHostSource = Join-Path $buildRoot 'WorkspaceWidgetHost.generated.cs'

function Invoke-ArtifactSigning {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    return
  }
  if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
    throw 'TimestampUrl is required when CertificateThumbprint is supplied.'
  }
  if ([string]::IsNullOrWhiteSpace($script:resolvedSignTool)) {
    throw 'signtool.exe was not found. Supply SignToolPath.'
  }
  $signOutput = & $script:resolvedSignTool sign `
    /sha1 $CertificateThumbprint `
    /fd SHA256 `
    /tr $TimestampUrl `
    /td SHA256 `
    $Path 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Authenticode signing failed for '$Path'.`n$($signOutput -join [Environment]::NewLine)"
  }
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "Authenticode verification failed for '$Path': $($signature.Status)"
  }
}

$script:resolvedSignTool = $SignToolPath
if (
  -not [string]::IsNullOrWhiteSpace($script:resolvedSignTool) -and
  -not (Test-Path -LiteralPath $script:resolvedSignTool -PathType Leaf)
) {
  throw "SignToolPath was not found: $($script:resolvedSignTool)"
}
if (
  -not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -and
  [string]::IsNullOrWhiteSpace($script:resolvedSignTool)
) {
  $script:resolvedSignTool = Get-ChildItem `
    -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') `
    -Recurse `
    -Filter signtool.exe `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}

if (
  [string]::IsNullOrWhiteSpace($SystemRuntimeFacadePath) -or
  -not (Test-Path -LiteralPath $SystemRuntimeFacadePath -PathType Leaf)
) {
  throw (
    'System.Runtime.dll from the .NET Framework reference-assembly Facades ' +
    'directory was not found. Install the .NET Framework 4.8 Developer Pack, ' +
    'restore Microsoft.NETFramework.ReferenceAssemblies.net48, or pass ' +
    'SystemRuntimeFacadePath explicitly.'
  )
}

foreach ($required in @(
    $compiler,
    $automationAssembly,
    $windowsWinMd,
    $windowsRuntimeAssembly,
    $SystemRuntimeFacadePath,
    $hostSource,
    $iconPath
  )) {
  if ([string]::IsNullOrWhiteSpace($required) -or -not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required build input was not found: $required"
  }
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$hostSourceContent = Get-Content -LiteralPath $hostSource -Raw
$hostSourceContent = [regex]::Replace(
  $hostSourceContent,
  '\[assembly: AssemblyVersion\("[^"]+"\)\]',
  "[assembly: AssemblyVersion(`"$Version.0`")]"
)
$hostSourceContent = [regex]::Replace(
  $hostSourceContent,
  '\[assembly: AssemblyFileVersion\("[^"]+"\)\]',
  "[assembly: AssemblyFileVersion(`"$Version.0`")]"
)
$hostSourceContent = [regex]::Replace(
  $hostSourceContent,
  '\[assembly: AssemblyInformationalVersion\("[^"]+"\)\]',
  "[assembly: AssemblyInformationalVersion(`"$Version`")]"
)
[System.IO.File]::WriteAllText(
  $generatedHostSource,
  $hostSourceContent,
  [System.Text.UTF8Encoding]::new($false)
)

$compilerHelp = (& $compiler /help 2>&1) -join [Environment]::NewLine
$compilerSupportsDeterministic =
  $compilerHelp -match '(?i)(?:/|-)deterministic'

$compilerArguments = @(
  '/nologo',
  '/target:winexe',
  '/platform:x64',
  '/optimize+'
)
if ($compilerSupportsDeterministic) {
  $compilerArguments += @(
    '/deterministic+',
    "/pathmap:$ProjectRoot=/_/src,$OutputRoot=/_/out"
  )
}
$compilerArguments += @(
  "/win32icon:$iconPath",
  "/reference:$automationAssembly",
  "/reference:$windowsWinMd",
  "/reference:$windowsRuntimeAssembly",
  "/reference:$SystemRuntimeFacadePath",
  '/reference:System.dll',
  '/reference:System.Core.dll',
  '/reference:System.Windows.Forms.dll',
  "/out:$hostExecutable",
  $generatedHostSource
)
$compilerOutput = & $compiler @compilerArguments 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
  throw "WorkspaceWidget.exe compilation failed.`n$($compilerOutput -join [Environment]::NewLine)"
}
Invoke-ArtifactSigning -Path $hostExecutable

$stageDirectories = @(
  $stageRoot,
  (Join-Path $stageRoot 'app'),
  (Join-Path $stageRoot 'assets'),
  (Join-Path $stageRoot 'assets\semantic-icons'),
  (Join-Path $stageRoot 'lib\webview2'),
  (Join-Path $stageRoot 'runtime\node'),
  (Join-Path $stageRoot 'scripts'),
  (Join-Path $stageRoot 'docs'),
  (Join-Path $stageRoot 'licenses')
)
foreach ($directory in $stageDirectories) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$semanticIconAssetNames = @(
  'manifest.json',
  'launch.svg', 'launch.png',
  'service.svg', 'service.png',
  'people.svg', 'people.png',
  'workspace.svg', 'workspace.png',
  'web.svg', 'web.png',
  'data.svg', 'data.png',
  'automation.svg', 'automation.png',
  'lab.svg', 'lab.png'
)
$stageFiles = @(
  [pscustomobject]@{ Source = $hostExecutable; Destination = (Join-Path $stageRoot 'WorkspaceWidget.exe') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'app\WorkspaceWidget.ps1'); Destination = (Join-Path $stageRoot 'app\WorkspaceWidget.ps1') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'app\AxStoreLifecycle.psm1'); Destination = (Join-Path $stageRoot 'app\AxStoreLifecycle.psm1') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'app\ax-store-lifecycle-broker.js'); Destination = (Join-Path $stageRoot 'app\ax-store-lifecycle-broker.js') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'app\public-default-state.json'); Destination = (Join-Path $stageRoot 'app\default-state.json') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'assets\workspace-widget.ico'); Destination = (Join-Path $stageRoot 'assets\workspace-widget.ico') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'assets\workspace-widget-logo.png'); Destination = (Join-Path $stageRoot 'assets\workspace-widget-logo.png') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'scripts\Set-WorkspaceWidgetAutostart.ps1'); Destination = (Join-Path $stageRoot 'scripts\Set-WorkspaceWidgetAutostart.ps1') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\INSTALLATION.md'); Destination = (Join-Path $stageRoot 'docs\INSTALLATION.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\USER-GUIDE.md'); Destination = (Join-Path $stageRoot 'docs\USER-GUIDE.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\MEDIA-CUSTOMIZATION.md'); Destination = (Join-Path $stageRoot 'docs\MEDIA-CUSTOMIZATION.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\ENTERPRISE-DEPLOYMENT.md'); Destination = (Join-Path $stageRoot 'docs\ENTERPRISE-DEPLOYMENT.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\MICROSOFT-STORE-RELEASE.md'); Destination = (Join-Path $stageRoot 'docs\MICROSOFT-STORE-RELEASE.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\PARTNER-CENTER-SUBMISSION-KO.md'); Destination = (Join-Path $stageRoot 'docs\PARTNER-CENTER-SUBMISSION-KO.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\AI-ASSISTED-DEVELOPMENT.md'); Destination = (Join-Path $stageRoot 'docs\AI-ASSISTED-DEVELOPMENT.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\SEMANTIC-ICON-LIBRARY.md'); Destination = (Join-Path $stageRoot 'docs\SEMANTIC-ICON-LIBRARY.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\SEMANTIC-ICON-GALLERY.html'); Destination = (Join-Path $stageRoot 'docs\SEMANTIC-ICON-GALLERY.html') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'docs\AX-STORE-OWNED-LIFECYCLE.md'); Destination = (Join-Path $stageRoot 'docs\AX-STORE-OWNED-LIFECYCLE.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'README.md'); Destination = (Join-Path $stageRoot 'README.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'PUBLIC-RELEASE-REVIEW.md'); Destination = (Join-Path $stageRoot 'PUBLIC-RELEASE-REVIEW.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'SECURITY.md'); Destination = (Join-Path $stageRoot 'SECURITY.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'PRIVACY.md'); Destination = (Join-Path $stageRoot 'PRIVACY.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'LICENSE'); Destination = (Join-Path $stageRoot 'LICENSE') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'THIRD-PARTY-NOTICES.md'); Destination = (Join-Path $stageRoot 'THIRD-PARTY-NOTICES.md') },
  [pscustomobject]@{ Source = (Join-Path $ProjectRoot 'CHANGELOG.md'); Destination = (Join-Path $stageRoot 'CHANGELOG.md') }
) + @(
  foreach ($assetName in $semanticIconAssetNames) {
    [pscustomobject]@{
      Source = Join-Path $ProjectRoot "assets\semantic-icons\$assetName"
      Destination = Join-Path $stageRoot "assets\semantic-icons\$assetName"
    }
  }
)
foreach ($entry in $stageFiles) {
  if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) {
    throw "Release input was not found: $($entry.Source)"
  }
  Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination -Force
}

$dependencyRestore = & (Join-Path $ProjectRoot 'scripts\Restore-WorkspaceWidgetDependencies.ps1') `
  -ProjectRoot $ProjectRoot |
  ConvertFrom-Json
if (-not $dependencyRestore.success) {
  throw 'Workspace Widget dependency restore did not report success.'
}
$webViewRuntimeRoot = [string]$dependencyRestore.runtimeRoot
foreach ($managedAssembly in @(
    'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.Wpf.dll'
  )) {
  Copy-Item `
    -LiteralPath (Join-Path $webViewRuntimeRoot $managedAssembly) `
    -Destination (Join-Path $stageRoot "lib\webview2\$managedAssembly") `
    -Force
}
Copy-Item `
  -LiteralPath (Join-Path $webViewRuntimeRoot 'WebView2Loader.dll') `
  -Destination (Join-Path $stageRoot 'WebView2Loader.dll') `
  -Force
Copy-Item `
  -LiteralPath (Join-Path $webViewRuntimeRoot 'Microsoft.Web.WebView2.LICENSE.txt') `
  -Destination (Join-Path $stageRoot 'licenses\Microsoft.Web.WebView2.LICENSE.txt') `
  -Force
Copy-Item `
  -LiteralPath (Join-Path $webViewRuntimeRoot 'Microsoft.Web.WebView2.NOTICE.txt') `
  -Destination (Join-Path $stageRoot 'licenses\Microsoft.Web.WebView2.NOTICE.txt') `
  -Force

$nodeRestore = & (Join-Path $ProjectRoot 'scripts\Restore-WorkspaceWidgetNodeRuntime.ps1') `
  -ProjectRoot $ProjectRoot |
  ConvertFrom-Json
if (-not $nodeRestore.success) {
  throw 'Workspace Widget Node.js restore did not report success.'
}
$nodeRuntimeRoot = [string]$nodeRestore.runtimeRoot
$nodeStageRoot = Join-Path $stageRoot 'runtime\node'
$nodeStagePaths = @(
  foreach ($runtimeFile in @($nodeRestore.files)) {
    $relativePath = [string]$runtimeFile.path
    $sourcePath = Join-Path $nodeRuntimeRoot $relativePath
    $destinationPath = Join-Path $nodeStageRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      throw "Restored Node.js runtime file was not found: $sourcePath"
    }
    $destinationDirectory = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    "runtime\node\$relativePath"
  }
)
$nodeRuntimeManifest = [ordered]@{
  product = [string]$nodeRestore.product
  version = [string]$nodeRestore.version
  sourceUrl = [string]$nodeRestore.sourceUrl
  packageSha256 = [string]$nodeRestore.packageSha256
  files = @($nodeRestore.files)
}
$nodeRuntimeManifestPath = Join-Path $nodeStageRoot 'WORKSPACE-WIDGET-RUNTIME-MANIFEST.json'
[System.IO.File]::WriteAllText(
  $nodeRuntimeManifestPath,
  ($nodeRuntimeManifest | ConvertTo-Json -Depth 7),
  [System.Text.UTF8Encoding]::new($false)
)
$nodeStagePaths += 'runtime\node\WORKSPACE-WIDGET-RUNTIME-MANIFEST.json'

$expectedStagePaths = @(
  $stageFiles | ForEach-Object {
    $_.Destination.Substring($stageRoot.Length).TrimStart('\')
  }
) + @(
  'lib\webview2\Microsoft.Web.WebView2.Core.dll',
  'lib\webview2\Microsoft.Web.WebView2.Wpf.dll',
  'WebView2Loader.dll',
  'licenses\Microsoft.Web.WebView2.LICENSE.txt',
  'licenses\Microsoft.Web.WebView2.NOTICE.txt'
) + $nodeStagePaths
$unexpectedStagePaths = @(
  Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
    ForEach-Object {
      $_.FullName.Substring($stageRoot.Length).TrimStart('\')
    } |
    Where-Object { $_ -notin $expectedStagePaths }
)
if ($unexpectedStagePaths.Count -gt 0) {
  throw (
    "The release stage contains files outside the public allowlist:`n" +
    ($unexpectedStagePaths -join [Environment]::NewLine)
  )
}

$installerPath = $null
$installerCompiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty Source
if ([string]::IsNullOrWhiteSpace($installerCompiler)) {
  $innoCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
  )
  foreach ($candidate in $innoCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $installerCompiler = $candidate
      break
    }
  }
}

if (-not $SkipInstaller) {
  if ([string]::IsNullOrWhiteSpace($installerCompiler)) {
    throw 'Inno Setup Compiler was not found. Install JRSoftware.InnoSetup or use -SkipInstaller.'
  }
  $installerScript = Join-Path $ProjectRoot 'installer\WorkspaceWidget.iss'
  if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Installer source was not found: $installerScript"
  }
  $installerOutput = & $installerCompiler `
    "/DAppVersion=$Version" `
    "/DProjectRoot=$ProjectRoot" `
    "/DStageRoot=$stageRoot" `
    "/DOutputRoot=$OutputRoot" `
    $installerScript 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Installer compilation failed.`n$($installerOutput -join [Environment]::NewLine)"
  }
  $installerPath = Join-Path $OutputRoot "WorkspaceWidget-Setup-$Version.exe"
  if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "The installer compiler completed without producing '$installerPath'."
  }
  Invoke-ArtifactSigning -Path $installerPath
}

$manifestFiles = @(
  Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      [ordered]@{
        path = $_.FullName.Substring($stageRoot.Length).TrimStart('\')
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    }
)
$manifest = [ordered]@{
  product = 'Workspace Widget'
  version = $Version
  platform = 'Windows 11 x64'
  generatedAt = (Get-Date).ToString('o')
  source = [ordered]@{
    revision = $SourceRevision
    dirty = $sourceDirty
  }
  hostExecutable = 'WorkspaceWidget.exe'
  installer = if ([string]::IsNullOrWhiteSpace($installerPath)) {
    $null
  } else {
    [System.IO.Path]::GetFileName($installerPath)
  }
  signed = (
    (Get-AuthenticodeSignature -LiteralPath $hostExecutable).Status -eq
      [System.Management.Automation.SignatureStatus]::Valid -and
    -not [string]::IsNullOrWhiteSpace($installerPath) -and
    (Get-AuthenticodeSignature -LiteralPath $installerPath).Status -eq
      [System.Management.Automation.SignatureStatus]::Valid
  )
  installerSha256 = if (
    -not [string]::IsNullOrWhiteSpace($installerPath) -and
    (Test-Path -LiteralPath $installerPath -PathType Leaf)
  ) {
    (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
  } else {
    $null
  }
  dependencies = @(
    [ordered]@{
      name = 'Microsoft.Web.WebView2'
      version = [string]$dependencyRestore.version
      packageSha256 = [string]$dependencyRestore.packageSha256
    }
    [ordered]@{
      name = [string]$nodeRestore.product
      version = [string]$nodeRestore.version
      sourceUrl = [string]$nodeRestore.sourceUrl
      packageSha256 = [string]$nodeRestore.packageSha256
      fileCount = @($nodeRestore.files).Count
    }
  )
  toolchain = [ordered]@{
    csharpCompilerVersion = (
      [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
        $compiler
      ).FileVersion
    )
    csharpCompilerSha256 = (
      Get-FileHash -LiteralPath $compiler -Algorithm SHA256
    ).Hash
    deterministic = [bool]$compilerSupportsDeterministic
    windowsMetadataVersion = (
      Split-Path -Leaf (Split-Path -Parent $windowsWinMd)
    )
    windowsMetadataSha256 = (
      Get-FileHash -LiteralPath $windowsWinMd -Algorithm SHA256
    ).Hash
    powerShellAutomationSha256 = (
      Get-FileHash -LiteralPath $automationAssembly -Algorithm SHA256
    ).Hash
    windowsRuntimeAssemblySha256 = (
      Get-FileHash -LiteralPath $windowsRuntimeAssembly -Algorithm SHA256
    ).Hash
    systemRuntimeFacadeVersion = (
      [System.Reflection.AssemblyName]::GetAssemblyName(
        $SystemRuntimeFacadePath
      ).Version.ToString()
    )
    systemRuntimeFacadeSha256 = (
      Get-FileHash -LiteralPath $SystemRuntimeFacadePath -Algorithm SHA256
    ).Hash
  }
  files = $manifestFiles
}
$manifestPath = Join-Path $OutputRoot "WorkspaceWidget-$Version-manifest.json"
[System.IO.File]::WriteAllText(
  $manifestPath,
  ($manifest | ConvertTo-Json -Depth 8),
  [System.Text.UTF8Encoding]::new($true)
)

[pscustomobject]@{
  success = $true
  version = $Version
  hostExecutable = $hostExecutable
  stageRoot = $stageRoot
  installer = $installerPath
  manifest = $manifestPath
  compiler = $compiler
  installerCompiler = $installerCompiler
} | ConvertTo-Json -Depth 5
