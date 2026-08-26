# Public Release Review

Review date: 2026-08-25
Candidate: 0.1.0, Windows 11 x64

## Decision

**The current local product-engineering candidate passes its implemented
quality and security gates; official Microsoft Store submission remains on
hold.**

The x64 full-trust WPF host, allowlisted runtime stage, Store manifest
template, package receipt, package-aware startup task, clean public default,
license, notices, and Store release runbook now exist. Windows SDK `makeappx`
accepts the development-identity package structure. This is structural
evidence, not a public release approval.

The 2026-08-25 refresh pins Node.js 24.19.0 LTS and WebView2 SDK 1.0.4129.50,
isolates packaged runtime selection from developer environment variables and
`PATH`, bounds state/media/cache/log growth, validates URL and Node-startup
trust boundaries, scopes single-instance IPC by state path, and installs local
migration builds as integrity-verified side-by-side releases. Current checks
pass 55/55 workstation integration, 27/27 official-security baseline, 11/11
network boundary, 18/18 unpackaged release, and 14/14 development MSIX
contracts. A deliberately corrupted Node runtime cache was refused before
execution, and the public-source scan found zero findings across 72 prospective
tracked files.

The earlier ESET result in
[the Phase 7 verification receipt](docs/PHASE7-VERIFICATION-RECEIPT.md) remains
historical evidence for the July candidate only. Microsoft Defender is disabled
by policy on the current PC, so its exact-candidate scan failed before scanning
with `0x80004005`; no malware-clean claim is made for the current candidate.

The public product, privacy, and support pages are deployed under
<https://gabeujin.github.io/workspace-widget/>. Four neutral Store screenshots,
the documented brand set, the bilingual Store listing kit, and the independent
Windows 11 test checklist are prepared. These are publication-preparation
artifacts, not Microsoft certification evidence.

On 2026-08-26, the Microsoft Store developer account was verified, the product
name was reserved, and the exact Partner Center identity was supplied through a
local Git-ignored JSON file. The required field schema and ignore boundary were
verified without copying the identity values into public source or this report.

## Remaining publication blockers

1. Review and commit the current source changes, then build the exact Store MSIX
   from the clean commit with `-StoreSubmission`; verify package allowlist,
   dependency versions, hashes, notices, absence of private state, and the
   source-revision receipt.
2. Verify first launch, update, sign-in startup, tray restore, shortcuts, media
   fallback, Node startup, state migration, and uninstall on an independent
   supported Windows 11 device when one is available. The current-device
   installed candidate has already passed the corresponding integration suite.
3. Run the Windows App Certification Kit against the exact candidate on the
   independent device and resolve every applicable failure. Partner Center
   certification remains the authoritative Store gate.
4. Complete the Partner Center listing, properties, IARC age rating,
   `runFullTrust` justification, target markets, and product/trademark review
   using the prepared listing kit.
5. Repeat secret, dependency, malware, and source security scans against the
   exact committed Store candidate and uploaded MSIX on a machine where the
   required security tooling is enabled.
6. Pass Partner Center certification and verify the resulting Store-signed
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
| User state | Runtime state remains outside the install root, is written atomically, and keeps `state.json.previous`. The current unpackaged upgrade preserved its SHA-256; Store update, uninstall, and reinstall persistence remains an independent-device gate. |
| Recovery safety | State size/schema/item limits are applied before a candidate is accepted. A future schema stops startup without writing or fallback; malformed JSON may recover from the verified `.previous` document before public defaults. |
| Local upgrade | The migration helper preflights running hosts before building, relocates a verified stage into a hash-verified content-addressed release, refuses to overwrite a damaged release, and refuses to force-stop another running version. Older releases and failed staging evidence are preserved rather than automatically deleted. |
| Shortcut import | `.lnk` registration stores the real target plus arguments, working directory, icon resource, and window style. |
| Window recovery | Explicit open presents a desktop-layer window in front; off-screen recovery uses physical monitor geometry, and the UI exposes desktop-layer behavior. |
| Public defaults | The staged package renames `public-default-state.json` to `app/default-state.json` and contains no workstation shortcuts. |
| Package scope | The Store build rechecks every freshly generated stage path, size, and SHA-256; its independent candidate verifier also enforces the exact application, StartupTask, capability, identity, and provenance contracts. |
| Dependencies | Node.js 24.19.0 LTS and WebView2 SDK 1.0.4129.50 inputs are checksum-pinned; every reused Node cache file is compared directly with the pinned official ZIP before execution, license material is retained, and a project-internal policy expires the release-day official review receipt after 3 days. This is not a Microsoft Store or WACK validity period. |
| Remote content | Raster media uses public-address checks, redirect and size limits, type/dimension validation, and a per-user cache; direct remote video is rejected; health polling consumes headers only; YouTube WebView2 denies permissions, popups, downloads, messages, and host objects. |
| Host code boundary | The full-trust native host loads only its adjacent application script and rejects a caller-selected external project root. |
| Licensing | MIT license and third-party notices are included. |
| MSIX | Windows SDK `makeappx` accepts the development package structure and manifest. |
| Receipt | The Store build writes package-relative file sizes and SHA-256 values plus the final MSIX hash. |
| Public web | Product, privacy, and support pages are deployed over HTTPS through GitHub Pages workflow run `30536510159`. |
| Store handoff | Four 1366 × 768 screenshots, brand assets, bilingual listing copy, and the independent Windows 11 lifecycle checklist are prepared. |
| Current verification | 55/55 integration, 27/27 official-security baseline, 11/11 network-boundary, 18/18 release, and 14/14 MSIX checks pass locally. Working-tree prospective public source: 72 files, zero findings. Exact-candidate malware and WACK evidence remain HOLD. |

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
- Windows App Certification Kit result for the exact Store candidate;
- Partner Center certification result and Store-signed package identity;
- secret/dependency/security scan reports;
- archived product, privacy-policy, and support URL verification;
- Microsoft Defender and a second reputable malware scan result;
- release notes and exact source commit.
