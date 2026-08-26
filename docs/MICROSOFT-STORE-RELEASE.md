# Microsoft Store MSIX release

Workspace Widget's supported public distribution channel is the Microsoft
Store MSIX path. The existing Inno Setup installer and unpackaged scripts are
retained only for local development and migration testing. They are not public
release artifacts.

For a Korean, click-by-click account, name reservation, identity, submission,
certification, and rollout checklist, see
[Partner Center submission guide](PARTNER-CENTER-SUBMISSION-KO.md).

## Why MSIX

- Microsoft signs accepted Store MSIX packages at no certificate cost.
- Microsoft hosts the package and manages updates.
- Package identity gives the app a supported Windows startup-task entry.
- Install, update, and uninstall use the Windows package lifecycle instead of
  custom installer actions.

Submitting an existing MSI or EXE through the Store is a different route. It
still requires the publisher to buy or otherwise obtain a publicly trusted code
signing certificate, host an immutable versioned installer URL, and maintain
updates. Workspace Widget does not use that route.

## Partner Center values required

Register an Individual developer account through the Microsoft Store developer
onboarding flow, reserve the product name as an **MSIX or PWA app**, and then
open **Product management > Product identity**. Copy these values exactly:

1. Package/Identity/Name
2. Package/Identity/Publisher
3. Package/Properties/PublisherDisplayName

Do not invent these values and do not substitute the Publisher ID, Store ID,
Package Family Name, seller ID, or marketing name. Start from
`packaging/msix/store-identity.example.json`, keep the completed local identity
file out of public commits until it has been reviewed, and pass it to the build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-WorkspaceWidgetMsix.ps1 `
  -Version 0.1.0 `
  -IdentityFile C:\secure-local-config\workspace-widget-store-identity.json `
  -CompilerPath C:\path\to\Roslyn\csc.exe `
  -OutputRoot C:\WorkspaceWidgetStoreBuild\0.1.0 `
  -StoreSubmission
```

The Store build refuses the development identity when `-StoreSubmission` is
set. It refuses an externally supplied stage and rebuilds into a fresh output
directory outside the repository from a clean Git checkout. It checks the Git
HEAD and clean state before and after the stage build and before sealing the
receipt, then rechecks every staged path, size, and SHA-256 before packaging.
The output includes an unsigned `.msix`, a package-relative SHA-256 receipt,
the exact generated layout, and the clean-source stage manifest under
`source-build`. The builder invokes the independent Store-candidate verifier
before it reports success. The unsigned producer artifact is expected for this
route: Microsoft re-signs the accepted package. Do not distribute that
unsigned pre-submission file directly.

Verify the exact package and receipt before WACK or upload:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkspaceWidgetMsix.ps1 `
  -PackagePath <generated-msix> `
  -ReceiptPath <generated-receipt-json> `
  -IdentityFile C:\secure-local-config\workspace-widget-store-identity.json `
  -ProjectRoot . `
  -StageManifestPath <output-root>\source-build\WorkspaceWidget-0.1.0-manifest.json `
  -StoreCandidate
```

This verifier reads the MSIX and source evidence as data; it does not install
or execute the package. It rechecks the package hash, every receipt-bound
payload file, exact Store identity, application executable and trust contract,
the single disabled-by-default startup task, the exact `runFullTrust`
capability allowlist, unsigned producer state, clean Git revision, deterministic
stage manifest, provenance record, and committed build-input hashes. WACK and
runtime lifecycle testing remain separate mandatory gates.

## Runtime model

- Architecture: Windows 11 x64
- Application: full-trust WPF desktop process
- Restricted capability: `runFullTrust`
- Startup integration: `WorkspaceWidgetStartup` declared with
  `windows.startupTask`
- Mutable state and logs: per-user local application data, never the protected
  package installation directory
- Bundled Node.js and WebView2 bridge: immutable package payloads updated only
  through a new Store package

The base-stage receipt records hashes for the compiler and framework/Windows
metadata inputs. `-StoreSubmission` additionally requires the stage to report a
compiler with deterministic output enabled. A legacy .NET Framework `csc.exe`
without `/deterministic` remains usable for local development but cannot
produce a Store candidate. Pass a current Roslyn executable through
`-CompilerPath` when it is not discoverable under Visual Studio 2022.

The Submission options explanation for `runFullTrust` should say:

> Workspace Widget is a user-controlled desktop launcher. It opens local apps,
> files, folders, and URLs selected by the user and can start user-selected
> local Node.js projects under the signed-in user's existing permissions. It
> does not elevate, install a service or driver, or run as SYSTEM.

The Store description must disclose that the optional local-service feature
runs projects explicitly selected by the user. Downloaded remote code must not
silently extend the certified product.

## Startup behavior

The Store package does not create a Task Scheduler entry. It declares a Windows
startup task. The user must launch the app at least once. The app can request
enablement while the task is in the ordinary Disabled state, but it cannot
override a user or organization policy decision. Users retain control through
**Settings > Apps > Startup** and Task Manager.

The legacy 30-second Task Scheduler delay is not part of the Store v1 package.
Adding a delay later requires a dedicated packaged startup shim and a separate
quality review.

## Release gates

Before uploading:

1. Resolve every reportable finding from the repository security scans.
2. Replace the development identity with the exact Partner Center identity.
3. Build from a clean, reviewed stage; never package restored release output as
   trusted source.
4. Validate package allowlist, hashes, architecture, manifest, startup task,
   runtime versions, license notices, and absence of private state.
5. Install a development-signed package on Windows 11 and exercise first
   launch, app launch, shortcuts, Node service startup, WebView2, startup-task
   enable/disable, update, and uninstall.
6. Run the Windows App Certification Kit against the exact candidate.
7. Publish `PRIVACY.md` at a stable public HTTPS URL, enter that exact URL in
   Partner Center, and verify that the Store support contact is reachable.
8. Upload the unsigned Store-targeted MSIX to Partner Center, document the
   `runFullTrust` justification, complete the listing and age-rating fields, and
   submit for certification.
9. Treat only the Store-signed certified package as the supported public
   binary.

Docker is useful for isolated Node fixtures and static checks, but it cannot
validate WindowsApps deployment, WPF/tray behavior, StartupTask, package update
or uninstall, WACK, or Store certification.

## Official references

- [Open a free developer account](https://learn.microsoft.com/en-us/windows/apps/publish/faq/open-developer-account)
- [Reserve an app name](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/reserve-your-apps-name)
- [View exact app identity fields](https://learn.microsoft.com/en-us/windows/apps/publish/view-app-identity-details)
- [Create an MSIX app submission](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/create-app-submission)
- [MSIX package requirements](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)
- [Code-signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
- [App capability declarations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)
- [Windows App Certification Kit](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-app-certification-kit)
- [Microsoft Store policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies)
