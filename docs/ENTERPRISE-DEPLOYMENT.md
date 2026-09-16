# Enterprise Deployment

The supported public deployment is the Microsoft Store MSIX described in
[Microsoft Store release](MICROSOFT-STORE-RELEASE.md). Organizations should
deploy the certified Store listing through their normal Store/Intune policy
after validating the publisher and package identity.

The unpackaged Inno material below is retained only for controlled development,
compatibility, and migration testing. It is not the supported public release
channel and must not be published as an official download.

## Legacy unpackaged migration model

- Windows 11 x64, build 22000 or later
- Per-user installation
- Interactive, non-elevated application process
- Default install root:
  `%LOCALAPPDATA%\Programs\WorkspaceWidget`
- The source-checkout migration helper stores immutable, content-addressed
  release folders below `releases\<version>-<content-id>` and repoints the
  shortcut and scheduled task only after exact file/hash validation. It never
  removes older releases automatically.
- Per-user state root:
  `%LOCALAPPDATA%\WorkspaceServiceWidget`

The installer does not install a Windows service, browser extension, kernel
driver, machine-wide environment variable, file association, machine-wide
Node.js runtime, pnpm runtime, or WebView2 Evergreen Runtime. It carries a
private, application-local Node.js runtime and npm.

Deploy the installer in the target user's context. A `SYSTEM` deployment or an
installer launched as a different administrator account resolves
`%LOCALAPPDATA%` for that other security principal and is not the supported
model.

## Package contents and provenance

The build script produces:

```text
%LOCALAPPDATA%\WorkspaceWidget\Builds\<version>\build\WorkspaceWidget.exe
%LOCALAPPDATA%\WorkspaceWidget\Builds\<version>\staging\WorkspaceWidget\
%LOCALAPPDATA%\WorkspaceWidget\Builds\<version>\WorkspaceWidget-<version>-manifest.json
%LOCALAPPDATA%\WorkspaceWidget\Builds\<version>\WorkspaceWidget-Setup-<version>.exe
```

The staged package contains the x64 native host, WPF application script, clean
public default state, icons, autostart helper, legal notices, pinned WebView2
SDK files, and the official Node.js 24.21.0 LTS Windows x64 distribution. The
dependency restore scripts accept only pinned sources and verify exact SHA-256
values before extracting files.

Before deployment:

1. build from a reviewed source revision;
2. scan source, staged files, and the installer with approved tooling;
3. compare every staged file with the generated manifest;
4. verify Authenticode signatures;
5. retain the source revision, build log, dependency checksum, manifest, and
   installer hash; and
6. test on a clean Windows 11 x64 user profile.

Both source default-state templates are byte-identical and contain no
registered shortcuts. Per-user registrations remain under LocalAppData and
must never be copied into a build stage.

## Silent installation

The Inno Setup package supports standard silent switches. Run it in the target
user's context:

```powershell
.\WorkspaceWidget-Setup-0.1.0.exe `
  /VERYSILENT `
  /SUPPRESSMSGBOXES `
  /NORESTART `
  /TASKS="desktopicon,autostart"
```

Choose tasks explicitly for deterministic deployment:

- `desktopicon`: create the desktop shortcut.
- `autostart`: configure Start with Windows.

The Start menu shortcut is installed independently of those optional tasks.
Silent setup does not launch the widget at the end.

Do not use `/SUPPRESSMSGBOXES` until package prerequisites, disk access, and
user context have been validated in a pilot group, because unattended dialogs
can otherwise hide a deployment failure.

### Detection

Use both install path and version:

```powershell
$exe = Join-Path $env:LOCALAPPDATA 'Programs\WorkspaceWidget\WorkspaceWidget.exe'
$installed = Test-Path -LiteralPath $exe -PathType Leaf
$version = if ($installed) {
  [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
}
```

For the historical `0.1.0` example above, the host file version is `0.1.0.0`.
The build `-Version` argument
rewrites assembly version attributes in a generated C# source copy and uses the
same value for installer and manifest metadata. It does not modify the checked-in
native source.

## Upgrade behavior

The installer has a stable application identifier and installs new versions
over the existing per-user program directory. State is stored outside that
directory and is preserved.

The source-checkout migration helper uses side-by-side content-addressed
release folders instead. It refuses to force-stop another running release, so
the user must exit the widget from the tray before the helper changes the
shortcut and scheduled task. Previous release folders remain available for
manual rollback and are not deleted automatically.

For a controlled upgrade:

1. ask the user to exit from the tray, or close the app through deployment
   tooling;
2. back up `%LOCALAPPDATA%\WorkspaceServiceWidget` when the deployment risk
   requires rollback protection;
3. install the new version in the same user context and directory;
4. verify the executable version and signature;
5. start the widget or allow its owned scheduled task to start it; and
6. inspect `host.log` and `runtime.log`.

The application reads current schema 5 state and migrates supported older
state fields at runtime. It writes state atomically and can read
`state.json.previous` if the primary JSON file is invalid.

An intentionally disabled owned autostart task remains disabled when it is
repaired by the installer. An unrelated task with the same name is not
overwritten.

Downgrades are not an established compatibility path. If rollback is required,
retain the older installer and a state backup created by that version. Validate
state compatibility in a pilot profile before a broad rollback.

## State and profile management

Workspace Widget state is local, not roaming:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget\state.json
```

The JSON can contain:

- local application and file-system paths;
- URLs and health endpoints;
- Shell Link arguments and working directories;
- local Node.js and PowerShell entry points and package script names;
- media file paths and remote media URLs; and
- layout and appearance preferences.

Treat the state as user configuration, not as a secret store. Do not put
credentials, access tokens, connection strings, or passwords in URL query
strings, shortcut arguments, health endpoints, or Node.js arguments.

Do not synchronize or replace the state file while the widget is running. For
backup, exit the tray process and copy the complete state directory.

If the organization supplies a default configuration, build it from the clean
public schema, use paths that exist on every target device, and validate it in
a disposable user profile. Do not package a real employee's state file.

## Autostart policy

The optional task is:

```text
\Workspace Service Widget
```

Its expected characteristics are:

- trigger: current user logon with a 30-second delay;
- logon type: interactive;
- run level: limited;
- working directory: the application root;
- multiple-instance policy: ignore new;
- execution time limit: unlimited for the native host; and
- action: the private installed `WorkspaceWidget.exe`.

The task description includes a product ownership marker. Runtime settings
enable or disable only an exact owned task and refuse to repair unrelated task
content. Uninstall asks the native host to unregister the owned task.

If Task Scheduler inspection is blocked, the UI reports a permission error.
If the definition is drifted, the UI reports **Needs repair** and directs the
user to the installer.

Organizations that prohibit logon tasks can omit the `autostart` setup task and
leave **Start with Windows** off. If policy must prevent users from creating the
task later, enforce that through Windows policy; the current application does
not provide a separate administrative policy file.

## Window-layer policy

The application exposes two user settings:

- **Always on top**
- **Keep on desktop layer when inactive**

Desktop layer returns the window behind ordinary applications when it loses
focus. Reopening from the shortcut or tray temporarily brings it forward.
Always on top overrides Desktop layer.

These are per-user preferences, not security controls. Secure desktop prompts,
Windows shell surfaces, and managed full-screen applications can behave
differently.

The source launcher accepts `-NoDesktopAttach`, and the native host accepts
`--no-desktop-attach`, as process-level overrides. The installer does not
currently expose an administrative default for this option.

## Network and runtime dependencies

Allow only the network destinations required by approved configuration:

- configured HTTP/HTTPS health endpoints, polled every 30 seconds;
- approved public HTTPS static-image origins and YouTube playback policy;
- `i.ytimg.com` for configured YouTube posters;
- `youtube-nocookie.com` and related YouTube delivery services for configured
  YouTube hover playback; and
- local web apps opened by user action.

YouTube playback requires the Microsoft Edge WebView2 Evergreen Runtime.
Workspace Widget ships SDK assemblies and a native loader but does not install
or silently download the runtime.

Node.js 24.21.0 LTS and npm are included under `runtime\node`; pnpm is not.
The official Node.js archive is checksum-pinned and its full license material
is retained. If local service startup is approved, restrict shortcut
configuration to trusted projects. Workspace Widget does not install project
dependencies. The selected entry file or package script runs with the current
user's permissions.

## Security controls

- Keep the install root writable only by the target user, administrators, and
  SYSTEM according to organizational policy.
- Do not point autostart at a shared or broadly writable development checkout.
- Restrict configuration to trusted local paths and network origins.
- Installed packages use only their package-local checksum-pinned Node runtime;
  environment and system `PATH` overrides are development-only.
- Automatic local-server startup accepts only local drive-rooted targets and
  loopback health URLs. Stop first requests cooperative shutdown; a force-stop after
  timeout requires fresh ownership verification and user confirmation. Tray Exit
  leaves servers running. Preserve lifecycle evidence and release folders while
  their supervisors are alive.
- Run `scripts\Test-OfficialSecurityBaseline.ps1`; a review older than 30 days
  fails closed until official Node.js, WebView2, Windows, and Store sources are
  reviewed again.
- Review `.lnk` TargetPath, arguments, and working directory before
  registration.
- Treat user-supplied media as active parsing input.
- Redact personal paths, customer names, source code, and internal service URLs
  from screenshots and support bundles.
- Preserve `LICENSE`, `THIRD-PARTY-NOTICES.md`, and the WebView2 license and
  notice files.
- Follow `SECURITY.md` for vulnerability reporting.

## Legacy external-distribution code signing

The build script produces unsigned files when no certificate thumbprint is
supplied and writes `signed: false` in the manifest. Unsigned development
packages can trigger Microsoft Defender SmartScreen and must not be represented
as an official enterprise release.

A release-signing process requires:

1. an organization-controlled Authenticode certificate with a protected private
   key;
2. SHA-256 file and timestamp digests;
3. an RFC 3161 timestamp endpoint supplied by the certificate authority;
4. signing of the compiled host before it is copied into the stage;
5. signing of the final installer;
6. signature verification on a clean device; and
7. a final manifest generated from the signed bytes.

The build script has a controlled signing path. It locates an x64 Windows Kits
SignTool automatically, or accepts an explicit path, signs and verifies the
native host, compiles and signs the installer, and then creates the manifest
from the signed staged bytes.

Use environment variables so the repository and shell history contain no real
thumbprint, organization-specific timestamp URL, or tool path:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-WorkspaceWidget.ps1 `
  -Version 0.1.0 `
  -CertificateThumbprint $env:WORKSPACE_WIDGET_SIGN_CERT_THUMBPRINT `
  -TimestampUrl $env:WORKSPACE_WIDGET_TIMESTAMP_URL `
  -SignToolPath $env:WORKSPACE_WIDGET_SIGNTOOL_PATH
```

`-SignToolPath` can be omitted when the build host has a discoverable x64
Windows Kits SignTool. `-TimestampUrl` is required whenever a certificate
thumbprint is supplied.

Verify the result independently:

```powershell
$buildRoot = Join-Path $env:LOCALAPPDATA 'WorkspaceWidget\Builds\0.1.0'
$hostExe = Join-Path $buildRoot 'staging\WorkspaceWidget\WorkspaceWidget.exe'
$setupExe = Join-Path $buildRoot 'WorkspaceWidget-Setup-0.1.0.exe'

signtool.exe verify /pa /all /v $hostExe
signtool.exe verify /pa /all /v $setupExe

Get-AuthenticodeSignature -LiteralPath $hostExe
Get-AuthenticodeSignature -LiteralPath $setupExe
Get-FileHash -LiteralPath $setupExe -Algorithm SHA256
```

The final manifest reports `signed: true` only when both the host and installer
have valid Authenticode signatures. Do not manually change that field.

Do not commit a PFX, private key, password, certificate-provider credential,
real certificate thumbprint, or private timestamp-service credential.

## Validation and rollout

Before broad deployment, validate:

- installation and upgrade as a standard user;
- installation with each optional task combination;
- startup after sign-in;
- an intentionally disabled autostart task;
- tray hide, restore, and Exit;
- Desktop layer and Always on top;
- MIN UI on single-monitor and mixed-DPI multi-monitor systems;
- state retention across upgrade;
- recovery from a deliberately invalid primary state using a valid
  `state.json.previous`;
- `.lnk` TargetPath, arguments, and working-directory behavior;
- approved health endpoints and Node.js startup;
- media with and without WebView2;
- silent uninstall; and
- signature and manifest verification.

Roll out to a pilot ring before general availability. Monitor:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget\host.log
%LOCALAPPDATA%\WorkspaceServiceWidget\runtime.log
```

Logs can contain local paths and configured URLs. Collect them only under the
organization's privacy and data-handling rules.

## Uninstall and retained data

Standard Inno Setup uninstall removes the installed application and shortcuts
and invokes the native host to unregister its owned autostart task.

The state directory is intentionally retained. If policy requires complete
removal, treat deletion of
`%LOCALAPPDATA%\WorkspaceServiceWidget` as a separate destructive operation:
identify the exact target user, back up anything required for recovery, obtain
the applicable approval, and then remove it with approved endpoint tooling.
