# Public Release Review

## Current 0.2.0 candidate — 2026-09-16

This is an unsigned development candidate, not a certified Microsoft Store
download. The current source separates ordinary shortcuts from managed servers,
supports one to sixteen ordered health checks, includes eighteen semantic icons,
and unifies Korean/English settings and appearance editing. Full and MIN layouts
share opacity and use interruptible, explicit-target bounds transitions.

Current local evidence includes production-WPF appearance tests (63 assertions),
motion integration (47 assertions), sampled shared-opacity/transition tests,
direct and package-script startup/health/graceful-stop integration, and installed
readback preserving user registrations and running supervisors. These tests have
bounded scopes; they do not prove a 90 Hz compositor rate, mixed-DPI physical
monitor interaction, or a Store-signed package lifecycle.

The runtime inputs are Node.js 24.21.0 LTS, npm 11.19.0 and WebView2 SDK
1.0.4191.47. The checksum-pinned inputs and dated official-security receipt are
checked by the build/test workflow. The older versions and counts below belong
to the archived 0.1.0 review, not the current candidate.

At this review boundary, hosted CI startup diagnosis, an exact clean-source
Store package, and its candidate-specific certification evidence remain open.
The KGJ project doctor reports HOLD (draft contract and incomplete typed native
evidence); no independently derived 9.9 score is claimed. Public source-only
release candidates can document these limitations, but unsigned executable
packages must not be presented as supported public downloads.

The final package receipt and CI run must identify the actual release source
revision. Previous WACK and malware results below cannot be inherited by a new
MSIX. Partner Center submission/certification remains a separate human-account
workflow; generating a submission candidate does not perform that workflow.

## Archived 0.1.0 evidence

Review date: 2026-08-26
Candidate: 0.1.0, Windows 11 x64

## Decision

**The exact clean-commit Store candidate passes the implemented local quality,
security, package, malware, and WACK gates; Partner Center submission and
independent-device lifecycle evidence remain open.**

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

The exact clean-commit Store candidate was scanned with the installed ESET
Security command-line scanner in no-clean/no-quarantine mode. It inspected the
MSIX archive and reported zero detections. Microsoft Defender remains disabled
by policy on the current PC, so this is one current reputable-engine result, not
a dual-engine claim.

The public product, privacy, and support pages are deployed under
<https://gabeujin.github.io/workspace-widget/>. Four neutral Store screenshots,
the documented brand set, the bilingual Store listing kit, and the independent
Windows 11 test checklist are prepared. These are publication-preparation
artifacts, not Microsoft certification evidence.

On 2026-08-26, the Microsoft Store developer account was verified, the product
name was reserved, and the exact Partner Center identity was supplied through a
local Git-ignored JSON file. The required field schema and ignore boundary were
verified without copying the identity values into public source or this report.
The clean source was then rebuilt into an external Store output directory. Its
receipt binds the MSIX to the exact source revision, and the independent package
verifier confirmed every Store-candidate contract without packaging the private
identity JSON.

Windows App Certification Kit 10.0.26100.7705 completed a non-partial command-
line run against that exact unsigned MSIX with overall result `PASS`. One
optional blocked-executable subtest reported expected process-launch and shell
name references from the full-trust host, bundled Node.js runtime, npm material,
and user documentation; the other 23 test results passed. This result must be
retained with the package receipt and does not replace Store certification.

## Remaining publication blockers

1. Verify first launch, update, sign-in startup, tray restore, shortcuts, media
   fallback, Node startup, state migration, and uninstall on an independent
   supported Windows 11 device when one is available. The current-device
   installed candidate has already passed the corresponding integration suite.
2. Complete the Partner Center listing, properties, IARC age rating,
   `runFullTrust` justification, target markets, and product/trademark review
   using the prepared listing kit.
3. Upload the exact verified MSIX and resolve every Partner Center package or
   policy validation warning. Partner Center certification remains the
   authoritative Store gate.
4. Pass Partner Center certification and verify the resulting Store-signed
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
| Current verification | 55/55 integration, 27/27 official-security baseline, 11/11 network-boundary, 18/18 release, and 14/14 Store-candidate checks pass locally. The prospective public-source scan found zero findings, WACK reported overall PASS, and ESET reported zero detections for the exact MSIX. Independent-device lifecycle and Partner Center certification remain open. |

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
