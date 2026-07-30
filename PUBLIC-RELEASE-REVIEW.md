# Public Release Review

Review date: 2026-07-30
Candidate: 0.1.0, Windows 11 x64

## Decision

**Engineering gate passed at 9.9 / 10.0; official Microsoft Store submission
remains on hold.**

The x64 full-trust WPF host, allowlisted runtime stage, Store manifest
template, package receipt, package-aware startup task, clean public default,
license, notices, and Store release runbook now exist. Windows SDK `makeappx`
accepts the development-identity package structure. This is structural
evidence, not a public release approval.

The final current-device verification passed 48/48 integration checks, 17/17
unpackaged release checks, and 14/14 development-identity MSIX checks. The
installer upgrade preserved the user-state SHA-256, the staged and installed
native-host hashes match, all configured health-check targets were online, and
ESET reported zero detections across the final installer and MSIX contents.
The arbitrary-project-root regression was rejected before its proof marker
could change.

## Remaining publication blockers

1. Register the Microsoft Store Individual developer account, reserve the MSIX
   product name, and copy the exact Partner Center identity Name, Publisher,
   and PublisherDisplayName values.
2. Commit the reviewed source to a clean Git checkout. The current copied
   workspace has no source revision that can be bound to a Store upload.
3. Build the exact Store MSIX with `-StoreSubmission`; verify package allowlist,
   dependency versions, hashes, notices, absence of private state, and the
   source-revision receipt.
4. Verify first launch, update, sign-in startup, tray restore, shortcuts, media
   fallback, Node startup, state migration, and uninstall on an independent
   supported Windows 11 device when one is available. The current-device
   installed candidate has already passed the corresponding integration suite.
5. Optionally rehearse with the Windows App Certification Kit. Partner Center
   certification is the authoritative Store gate.
6. Publish `PRIVACY.md` at a stable HTTPS URL, verify the support contact, and
   complete Partner Center listing, age rating, `runFullTrust` justification,
   and product/trademark review.
7. Repeat secret, dependency, malware, and source security scans against the
   exact committed Store candidate and uploaded MSIX.
8. Pass Partner Center certification and verify the resulting Store-signed
   installation.

Until these gates pass, generated MSIX and legacy installer files are
development artifacts and must not be described as official downloads.

## Completed controls

| Area | Result |
| --- | --- |
| Platform | The MSIX declares x64 and Windows.Desktop build 22000 or newer. |
| Native identity | `WorkspaceWidget.exe` runs as a packaged Win32 desktop application with no console or WScript launcher. |
| Package identity | Store packaging refuses development placeholders when `-StoreSubmission` is set. |
| Source binding | Store packaging refuses external stages, rebuilds from a clean Git HEAD into a fresh external output root, checks the checkout again after building, and binds the deterministic stage manifest to that revision. |
| Startup safety | `WorkspaceWidgetStartup` is declared through `windows.startupTask`; Windows preserves user and policy control. |
| User state | Runtime state remains outside the install root, is written atomically, keeps `state.json.previous`, and survives upgrade/uninstall. |
| Shortcut import | `.lnk` registration stores the real target plus arguments, working directory, icon resource, and window style. |
| Window recovery | Explicit open presents a desktop-layer window in front; off-screen recovery uses physical monitor geometry, and the UI exposes desktop-layer behavior. |
| Public defaults | The staged package renames `public-default-state.json` to `app/default-state.json` and contains no workstation shortcuts. |
| Package scope | The Store build rechecks every freshly generated stage path, size, and SHA-256; its independent candidate verifier also enforces the exact application, StartupTask, capability, identity, and provenance contracts. |
| Dependencies | WebView2 and Node inputs are checksum-pinned and their license material is retained; final dependency versions remain a release gate. |
| Remote content | Raster media uses public-address checks, redirect and size limits, type/dimension validation, and a per-user cache; direct remote video is rejected; health polling consumes headers only; YouTube WebView2 denies permissions, popups, downloads, messages, and host objects. |
| Host code boundary | The full-trust native host loads only its adjacent application script and rejects a caller-selected external project root. |
| Licensing | MIT license and third-party notices are included. |
| MSIX | Windows SDK `makeappx` accepts the development package structure and manifest. |
| Receipt | The Store build writes package-relative file sizes and SHA-256 values plus the final MSIX hash. |
| Current verification | 48/48 integration, 17/17 release, and 14/14 MSIX checks passed; ESET detected 0 threats in 4,033 scanned objects. |

## Public package contents

The staged runtime contains only:

- `WorkspaceWidget.exe`;
- `app/WorkspaceWidget.ps1` and the clean `app/default-state.json`;
- final ICO and logo assets;
- pinned WebView2 runtime bridge files and notices;
- pinned Node.js Windows x64 runtime, npm, license files, and a
  runtime content manifest;
- Store logo/tile assets and `AppxManifest.xml`;
- README, security and privacy policies, license, notices, and user
  documentation.

Developer tests, screenshots, source-only build files, runtime state, logs,
legacy recovery files, and diagnostics are not installed.

## Required release evidence

Archive these together for each public version:

- Store-targeted unsigned MSIX and its SHA-256 receipt;
- exact Partner Center identity record and source revision;
- install/update/uninstall log from an independent supported Windows 11 device;
- sign-out/sign-in `StartupTask` evidence;
- optional Windows App Certification Kit rehearsal result;
- Partner Center certification result and Store-signed package identity;
- secret/dependency/security scan reports;
- archived privacy-policy URL and support-contact verification;
- Microsoft Defender and a second reputable malware scan result;
- release notes and exact source commit.
