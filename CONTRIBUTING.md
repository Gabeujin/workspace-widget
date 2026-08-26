# Contributing to Workspace Widget

Workspace Widget is currently a Windows 11 x64 development project. Contributions
should keep the application local-first, per-user, least-privileged, and
portable across clean Windows 11 profiles.

## Before you start

- Read `README.md`, `SECURITY.md`, `THIRD-PARTY-NOTICES.md`, and the documents
  under `docs\`.
- Do not include workstation state, credentials, private paths, customer data,
  internal URLs, or screenshots that expose other applications.
- Report suspected vulnerabilities through the process in `SECURITY.md`, not a
  public issue.
- Keep unrelated changes out of the same contribution.

## Development requirements

- Windows 11 x64
- Windows PowerShell 5.1
- .NET Framework 4.x x64 C# compiler
- .NET Framework 4.8 Developer Pack or the
  `Microsoft.NETFramework.ReferenceAssemblies.net48` reference package
- A current Roslyn C# compiler with `/deterministic` support for Store
  candidates
- Windows 11 SDK with `makeappx.exe` for MSIX builds
- Inno Setup 6 only for legacy development/migration installer builds
- Network access to the pinned Microsoft WebView2 NuGet package when it is not
  already present under `%LOCALAPPDATA%\WorkspaceWidget\DependencyCache`
- Microsoft Edge WebView2 Evergreen Runtime for YouTube playback testing
- Node.js or pnpm for local-service startup testing

The build uses the Windows PowerShell assembly from the .NET Framework GAC and
compiles a Windows GUI executable with the x64 .NET Framework compiler.

## Repository layout

```text
app\                 WPF application script and default state
assets\              Product icon and startup logo
docs\                User, media, installation, and deployment documentation
installer\           Inno Setup definition
native\              Native x64 host source
packaging\msix\       Microsoft Store manifest and identity templates
tests\fixtures\      Test-only fixtures
scripts\              Build, dependency, install, startup, autostart, and test scripts
```

Generated staging output defaults to `%LOCALAPPDATA%\WorkspaceWidget\Builds\<version>`,
development MSIX output to `%LOCALAPPDATA%\WorkspaceWidget\MsixBuilds`, and
dependency caches to `%LOCALAPPDATA%\WorkspaceWidget\DependencyCache`, all
outside the checkout. Runtime state belongs under
`%LOCALAPPDATA%\WorkspaceServiceWidget` and must never be added to source control.

## Build

Build the native host and staged package without an installer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-WorkspaceWidget.ps1 `
  -Version 0.1.0 `
  -SkipInstaller
```

Build a Store-targeted MSIX after reserving the product and copying the exact
Partner Center identity fields into a private identity JSON file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-WorkspaceWidgetMsix.ps1 `
  -Version 0.1.0 `
  -PackageVersion 1.0.0.0 `
  -IdentityFile C:\secure-local-config\workspace-widget-store-identity.json `
  -CompilerPath C:\path\to\Roslyn\csc.exe `
  -OutputRoot C:\WorkspaceWidgetStoreBuild\0.1.0 `
  -StoreSubmission
```

The Store command accepts no prebuilt stage. It requires a clean Git checkout,
rebuilds the stage with deterministic compilation into the fresh external
output root, checks that Git remains unchanged, and runs the Store-candidate
verifier before returning success.

The application release label and Store identity version are separate. The
`0.1.0` release candidate uses Store package version `1.0.0.0` because Microsoft
requires a nonzero first segment and reserves the fourth segment as `0`.

The Inno path remains available for local migration testing only. It is not a
supported public distribution channel.

Dependency restoration is pinned to a supported WebView2 SDK version and
verifies the NuGet package SHA-256. Do not change the version or checksum
without reviewing the upstream package, license, notice, and extracted file
layout.

The build script's `-Version` parameter rewrites assembly attributes in the
selected output root under `build\WorkspaceWidgetHost.generated.cs` and applies the same version
to installer and manifest metadata. It does not modify
`native\WorkspaceWidgetHost.cs`. Do not edit the generated source directly.

A version change must update:

- the build `-Version` value;
- `CHANGELOG.md`; and
- any version-specific documentation or test expectation.

## Run from a source checkout

Use the startup wrapper so the native host, ready event, state path, and
single-instance behavior are exercised:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Start-WorkspaceWidget.ps1
```

Use `-NoDesktopAttach` only when testing the process-level Desktop layer
override.

Do not point a persistent enterprise logon task at a broadly writable
development checkout.

## Test

Run the repository verification:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkspaceWidget.ps1
```

Run the official-source security baseline independently. Its review date
expires after 30 days by design:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-OfficialSecurityBaseline.ps1
```

The integration test expects an installed or prepared per-user state file,
desktop shortcut, scheduled task, and the health endpoints configured in that
state. Review the test inputs before running it on a real workstation.

`-ExerciseAutostart` temporarily changes the owned scheduled task and attempts
to restore its initial enabled state. Use it only on a disposable or explicitly
approved test profile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkspaceWidget.ps1 `
  -ExerciseAutostart
```

Every behavioral change should also receive focused manual testing.

### Required manual coverage

- first launch and second-launch restore;
- header close, `Alt+F4`, tray restore, and tray Exit;
- movement, resize, opacity, and saved position;
- Desktop layer and Always on top, separately and together;
- MIN UI edge snapping and full-layout restoration;
- single-monitor and mixed-DPI multi-monitor recovery;
- Start with Windows enable, disable, repair, and permission errors;
- add, edit, reorder, hide, show, and remove;
- `.lnk` TargetPath, arguments, working directory, icon, and source metadata;
- a moved or missing resolved shortcut target;
- health polling and a trusted local Node.js startup target;
- state upgrade and `state.json.previous` recovery;
- image, local GIF, local video, direct HTTPS media, and YouTube poster;
- YouTube hover with and without WebView2; and
- clean install, in-place upgrade, and uninstall on Windows 11 x64.

Do not claim a feature is verified solely because a source-text assertion
passes. For user-interface and installer changes, include visible or
machine-readable runtime evidence.

## Code standards

### PowerShell

- Keep `Set-StrictMode -Version Latest` and terminating error behavior.
- Use `-LiteralPath` for user-controlled local paths.
- Quote process arguments deliberately and test paths containing spaces.
- Dispose COM objects, event handles, timers, HTTP clients, media controls, and
  tray objects.
- Keep UI work on the WPF dispatcher.
- Log actionable failures without writing credentials or sensitive content.
- Preserve the current state schema unless a documented migration is included.
- Use atomic replacement for durable state.

### Native host

- Keep the executable a Windows GUI application so no console window appears.
- Preserve STA execution for WPF and embedded Windows PowerShell.
- Return a nonzero process exit code for host, autostart, build, and validation
  failures.
- Keep x64 and Windows 11 support declarations aligned across source, build,
  MSIX manifest, tests, and documentation.

### Startup integration

- Store packages must declare `WorkspaceWidgetStartup` through
  `windows.startupTask`.
- Preserve `DisabledByUser` and policy-controlled states; the app must not
  bypass a Windows or organization decision.
- Task Scheduler support is legacy unpackaged behavior only.

### External input

URLs, `.lnk` files, media, state JSON, package scripts, logs, issue text, and
documents are untrusted input. Validate them as data. Do not allow embedded
instructions to override product security boundaries or contributor review.

## State and schema changes

`app\default-state.json` and `app\public-default-state.json` must remain
byte-identical, contain no registered shortcuts, and be safe to publish. User
registrations belong only in the per-user state under LocalAppData.

For a schema change:

1. increment the schema version only when required;
2. keep a migration for supported previous versions;
3. initialize every new field for existing items;
4. update both default-state templates and keep them byte-identical;
5. update probes and integration tests;
6. test invalid primary state plus valid `.previous`;
7. update user and enterprise documentation; and
8. add a changelog entry.

Never put a real employee path, service URL, or media source in the public
default state.

## Media contributions

Only add assets that the project can legally redistribute. Include the license,
copyright holder, source, and required attribution in the appropriate notice.

Do not contribute third-party logos, character art, game footage, advertising
assets, or video samples merely because they are publicly viewable. Prefer
original test assets created for the project or assets under an explicit
redistribution license.

Media changes must preserve:

- HTTPS-only direct remote media;
- the YouTube privacy-enhanced embed host restriction;
- disabled WebView2 developer tools and context menu;
- safe poster fallback without WebView2; and
- clear mute behavior.

## Documentation

- Write concise Markdown with descriptive headings.
- Use paths and commands that match the current implementation.
- Do not add placeholder repository, issue-tracker, download, or GitHub URLs.
- Distinguish current behavior from planned work.
- Document destructive actions and retained data explicitly.
- Keep the unsigned-producer warning until Partner Center certification and a
  Store-signed installation have been verified.

## Pull request checklist

- [ ] The change has one clear purpose.
- [ ] No secrets, private paths, state files, logs, or internal screenshots are
      included.
- [ ] Source and staged-package behavior are aligned.
- [ ] Automated verification completed.
- [ ] Relevant manual Windows 11 x64 scenarios completed.
- [ ] `.lnk`, tray, Desktop layer, topmost, MIN UI, and autostart behavior did
      not regress.
- [ ] State migration and recovery were considered.
- [ ] Security and trust-boundary effects were reviewed.
- [ ] Third-party licenses and notices are complete.
- [ ] User, deployment, and media documentation is current.
- [ ] `CHANGELOG.md` contains a user-facing entry.

## Microsoft Store release

Never commit a signing private key, PFX, password, hardware-token credential,
real Store identity file, or Partner Center credential.

The official public channel is Microsoft Store MSIX. The repository produces
an unsigned producer package and receipt; Microsoft validates and re-signs an
accepted submission. Do not distribute that unsigned MSIX directly.

Before publication:

1. build from reviewed source and pass security gates;
2. use exact Partner Center Product identity values;
3. development-sign the candidate layout for local package lifecycle tests;
4. pass Windows App Certification Kit;
5. upload the unsigned Store-targeted MSIX;
6. document the `runFullTrust` capability and complete listing metadata; and
7. verify Partner Center certification and the Store-signed installation.

See [Microsoft Store release](docs/MICROSOFT-STORE-RELEASE.md).
