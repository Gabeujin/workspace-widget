# Workspace Widget public release roadmap

- Last updated: 2026-09-16
- Release target: 0.2.0 development preview
- Public repository: <https://github.com/Gabeujin/workspace-widget>
- Product site target: <https://gabeujin.github.io/workspace-widget/>

## Purpose

This document is the local source of truth for public-release work before and
after Microsoft Partner Center onboarding. A phase is complete only when its
implementation, verification result, and evidence path are recorded here.

The supported public binary channel remains Microsoft Store MSIX. Source code,
the source-only release candidate, and product documentation may be published
before Store certification. Unsigned MSIX and legacy installer artifacts must
not be offered as public downloads.

## Current 0.2.0 boundary

The current candidate is tracked in [the public release review](../PUBLIC-RELEASE-REVIEW.md)
and [the modernization worklog](MODERNIZATION-WORKLOG.md). Hosted lifecycle run
`35053951038` passed. Each later source revision requires fresh CI, exact-source
package verification, certification-kit and malware checks, and installed
readback before its source-only release. Final results belong to the release
notes and the local package handoff receipt, bound to that release revision.
The completed rows and quality score in the archived sections below describe
the 0.1.0 evidence only; they do not certify 0.2.0 or replace the current KGJ
evidence gate, which remains HOLD. No unsigned binary is a supported public download.

## Archived 0.1.0 baseline and phase evidence

| Area | Status | Evidence |
| --- | --- | --- |
| Public source | Complete | Public `main` branch and source-only `v0.1.0-rc.1` |
| Source CI | Complete | `Public source gate` workflow is green |
| Source-only RC | Complete | `v0.1.0-rc.1` release exists |
| Security boundary | Complete for current local engineering candidate | Integration 55/55, official security 27/27, network 11/11, release 18/18, MSIX 14/14; see `../PUBLIC-RELEASE-REVIEW.md` |
| Malware scan | Complete with one current engine | ESET scanned the exact Store candidate in no-clean/no-quarantine mode and reported zero detections; Microsoft Defender remains disabled by policy |
| Current PC install | Complete | Content-addressed side-by-side release with bundled Node.js 24.19.0; user-state hash preserved |
| Public screenshots | Complete | Five neutral native-app captures plus four 1366 × 768 Store exports |
| Store and web icons | Complete | Canonical PNG/ICO and documented web/Store derivatives |
| Product/privacy/support site | Complete | All three Pages URLs return HTTPS 200; lifecycle-qualified privacy copy deployed in workflow run `30536510159` |
| Store listing handoff | Complete before Partner Center | Bilingual listing kit and independent Windows 11 checklist prepared |
| GitHub public controls | Complete, maintainer-verified 2026-07-30 | Authenticated API checks confirmed homepage, alerts, security updates, secret scanning, push protection, and private reporting; see the Phase 7 receipt |
| Partner Center identity | Complete | Exact values are supplied only through a local Git-ignored JSON file and are rejected by the public-source gate if tracked |
| Store MSIX | Complete for local submission candidate | Clean-source `-StoreSubmission` build, independent 14/14 verification, WACK overall PASS, and exact-candidate ESET zero-detection evidence completed |
| Independent Windows 11 lifecycle test | Waiting on device | Docker cannot validate WPF, tray, StartupTask, MSIX update, or uninstall |

## Operating rules

1. Preserve existing user state and back up every existing file before changing
   it.
2. Do not permanently delete files without explicit approval for the resolved
   targets.
3. Keep workstation names, workstation-specific local paths, internal service
   names, logs, and personal shortcuts out of public assets. Generic
   demonstration paths must be clearly non-personal.
4. Treat remote media and copied web content as untrusted input.
5. Record exact commands, hashes, counts, and screenshots as evidence instead
   of relying on visual confidence alone.
6. Do not describe an unsigned package as an official download.

## Phase 0 - Baseline and work ledger

Status: **Complete**

### Deliverables

- [x] Reconfirm clean local source checkout and remote tracking state.
- [x] Reconfirm current installed bundled Node.js version.
- [x] Locate and clone the existing `Gabeujin.github.io` source checkout.
- [x] Create this roadmap.
- [x] Record the final baseline inventory and commit references.

### Completion gate

Both repositories are clean, their default branches and deployment workflow are
known, and all later phases have explicit evidence locations.

## Phase 1 - Current PC final RC update

Status: **Complete**

### Deliverables

- [x] Back up the installed application tree and mutable user state with hashes.
- [x] Stop only the confirmed Workspace Widget process.
- [x] Update the installed files without deleting user data.
- [x] Preserve `state.json` byte-for-byte unless a tested migration is required.
- [x] Restart the native host and confirm one responsive process.
- [x] Verify bundled Node.js 24.19.0 and rerun the current-device integration
      suite.

### Completion gate

The installed native host matches the final candidate, the state hash is
unchanged, and the integration suite passes with no private data copied into
the source tree.

## Phase 2 - Public usage scenarios and screenshots

Status: **Complete**

### Neutral demo scenarios

1. Full workspace overview with generic apps, folders, URLs, and one local
   health-checked service.
2. Add or edit a shortcut, including URL port extraction and optional health
   endpoint.
3. Import a Windows `.lnk` and show resolved executable metadata.
4. Add a custom icon from a safe URL or clipboard and show local caching.
5. Use the right-click organization and remove action.
6. Switch to MIN UI, adjust opacity, and dock the widget to a screen edge.
7. Toggle always-on-top, Start with Windows, close-to-tray, and Exit.
8. Demonstrate safe YouTube hover preview behavior and fallback.

### Deliverables

- [x] Create isolated neutral demo state outside the real user-state directory.
- [x] Capture real native UI at readable Windows display scaling.
- [x] Produce Store-ready and GitHub-ready crops without personal information.
- [x] Visually inspect every final image.
- [x] Record scenario, app version, display size, and source image hash.

### Completion gate

At least four polished screenshots cover the primary workflow, settings, MIN
UI, and media/customization without exposing private machine information.

## Phase 3 - Icon and visual asset set

Status: **Complete**

### Deliverables

- [x] Identify the canonical high-resolution logo source and application ICO.
- [x] Verify ICO frame sizes and alpha/color behavior in Windows.
- [x] Document the Store logo/tile assets generated by the MSIX build.
- [x] Generate web favicon, social preview, and product-card assets.
- [x] Add an asset inventory with dimensions, purpose, source, and hash.
- [x] Confirm that generated assets remain legible in light and dark contexts.

### Completion gate

Every tracked visual asset has one documented purpose and reproducible source;
no obsolete draft icon is used by the build or public site.

## Phase 4 - GitHub Pages product, privacy, and support pages

Status: **Complete**

Target URLs:

- Product: <https://gabeujin.github.io/workspace-widget/>
- Privacy: <https://gabeujin.github.io/workspace-widget/privacy/>
- Support: <https://gabeujin.github.io/workspace-widget/support/>

### Deliverables

- [x] Add Workspace Widget to the existing homepage app catalog.
- [x] Build a responsive product page under the existing subpath structure.
- [x] Publish the privacy policy at a stable HTTPS URL.
- [x] Publish a support page with issue-report and security-report routes.
- [x] Link source, documentation, and source-only RC without presenting an
      unsigned binary as an official download.
- [x] Verify desktop/mobile layout, keyboard navigation, links, and 404 behavior.
- [x] Deploy through the repository's existing GitHub Actions workflow.

### Completion gate

All three public URLs return the expected content over HTTPS, contain no private
data, and the GitHub Pages workflow is green.

## Phase 5 - GitHub public quality controls

Status: **Complete**

### Deliverables

- [x] Add the CI status badge and product-site links to the source README.
- [x] Set the repository homepage to the product URL.
- [x] Review default-branch protection or ruleset options without blocking the
      maintainer's current release flow.
- [x] Reconfirm secret scanning, push protection, vulnerability reporting, and
      release metadata.
- [x] Ensure issue/support/security links are mutually consistent.

### Completion gate

The public repository clearly distinguishes source, prerelease status, support,
security reporting, and the future Store distribution channel.

## Phase 6 - Store listing kit and independent test handoff

Status: **Complete before Partner Center**

### Deliverables that do not require Partner Center

- [x] Draft Korean and English short descriptions, full descriptions, keywords,
      feature list, and release notes.
- [x] Draft the proposed age-rating answers and `runFullTrust` justification
      for final entry in Partner Center.
- [x] Prepare a screenshot and icon upload map.
- [x] Prepare Windows 11 standard-user install, update, sign-in startup, tray,
      media, Node service, state migration, and uninstall test cases.
- [x] Prepare WACK and certification evidence templates.
- [x] Document the exact Partner Center identity values needed to resume.

### Completion gate

The submission kit and local product gates are complete. Partner Center account
verification, product-name reservation, and exact identity acquisition were
completed on 2026-08-26. The clean-commit Store candidate, independent 14/14
package verification, WACK overall PASS, and exact-candidate ESET scan are also
complete. Independent-device results, final listing properties, IARC receipt,
target markets, `runFullTrust` submission, upload, and certification remain open.

## Phase 7 - Final negative review

Status: **Complete**

### Review gates

- [x] Public-source scan passes from a clean checkout.
- [x] Integration, network-boundary, release, and MSIX structural tests pass.
- [x] Public pages and screenshots contain no private identifiers.
- [x] Documentation makes no unsupported security or certification claim.
- [x] Public links and deployment workflow are green.
- [x] P0 findings: 0.
- [x] P1 findings: 0.
- [x] Engineering quality score: 9.9/10.

This completion applies to the local and public-source preparation scope.
Partner Center onboarding, identity acquisition, and the exact Store candidate
are now complete. Independent-device lifecycle evidence, listing submission,
certification, and Store-signed installation remain in the waiting lane below.

## Partner Center waiting lane

Completed on 2026-08-26:

1. Register and verify the Store developer account.
2. Reserve the final product name.
3. Acquire the exact Package Identity Name, Publisher, and PublisherDisplayName
   in a local Git-ignored identity file.
4. Build the exact Store MSIX from a clean commit and pass the independent
   14/14 Store-candidate verification.
5. Run WACK against the exact unsigned MSIX and retain its overall PASS report.
6. Scan the exact MSIX with ESET in no-clean/no-quarantine mode and retain the
   zero-detection report.

Remaining:

1. Upload listing assets and the unsigned Store-targeted MSIX.
2. Enter and verify listing properties, target markets, the final IARC
   questionnaire, and the `runFullTrust` justification.
3. Complete the independent Windows 11 lifecycle checklist when a suitable
   standard-user environment is available.
4. Complete certification and verify the Microsoft-signed installation.

## Evidence ledger

| Date | Phase | Result | Evidence path or URL |
| --- | --- | --- | --- |
| 2026-07-30 | Baseline | Public source and source-only RC confirmed | <https://github.com/Gabeujin/workspace-widget/releases/tag/v0.1.0-rc.1> |
| 2026-08-26 | Partner Center onboarding | Account verified, product name reserved, identity schema and Git-ignore boundary verified without recording identity values | `../PUBLIC-RELEASE-REVIEW.md` |
| 2026-08-26 | Exact Store candidate | Clean-source Store build, independent 14/14 package verification, WACK overall PASS, and ESET zero detections; exact commit and file hashes remain in the external receipt set | `../PUBLIC-RELEASE-REVIEW.md` |
| 2026-07-30 | Installed RC update | Installed runtime updated to Node.js 24.18.1; state hash unchanged | `../PUBLIC-RELEASE-REVIEW.md#completed-controls` |
| 2026-07-30 | Current-device integration | 48/48 checks passed; one responsive process | `../scripts/Test-WorkspaceWidget.ps1` |
| 2026-07-30 | Screenshots | Neutral native captures and Store exports documented with hashes | `media/screenshots/README.md`, `media/store/README.md` |
| 2026-07-30 | Brand assets | Canonical sources and derived assets documented with hashes | `media/brand/README.md` |
| 2026-07-30 | Product site | Product, privacy, and support pages deployed with lifecycle-qualified privacy copy | <https://github.com/Gabeujin/Gabeujin.github.io/actions/runs/30536510159> |
| 2026-07-30 | Store handoff | Listing copy, upload map, identity template, and independent-device checklist prepared | `STORE-LISTING-KIT.md`, `WINDOWS-11-RELEASE-TEST-CHECKLIST.md` |
| 2026-07-30 | Local Phase 7 verification | Public-source, integration, network, release, MSIX, image, link, browser, and malware checks recorded | `PHASE7-VERIFICATION-RECEIPT.md` |
| 2026-07-30 | GitHub security | Maintainer-verified authenticated API checks; owner-only settings are not independently visible on the public security page | `PHASE7-VERIFICATION-RECEIPT.md` |
| 2026-07-30 | Independent negative review | P0 0, P1 0, P2 0; engineering quality 9.9/10 | `PHASE7-VERIFICATION-RECEIPT.md` |
| 2026-07-30 | Pushed public-source gate | Push and pull-request clean-checkout workflows passed on Phase 7 closeout commit `446d344` | <https://github.com/Gabeujin/workspace-widget/actions/runs/30537886939>, <https://github.com/Gabeujin/workspace-widget/actions/runs/30537891453> |
| 2026-07-30 | Final development artifacts | Evidence set `WW-PHASE7-20260730-201713` passed 17/17 release, 14/14 MSIX, and ESET 0-detection checks from source revision `446d344` | `PHASE7-VERIFICATION-RECEIPT.md` |
| 2026-08-25 | Runtime and state hardening | Package runtime fails closed when missing, Node cache is verified against the pinned official ZIP, future state schema remains byte-preserved, and relative Node targets are rejected | `../SECURITY.md`, `../security/official-security-review.json` |
| 2026-08-26 | Current local product gate | 55/55 integration, 27/27 official security, 11/11 network, 18/18 release, 14/14 Store candidate, WACK overall PASS, ESET zero detections, and prospective public-source scan pass; Partner Center and independent-device gates remain open | `../PUBLIC-RELEASE-REVIEW.md` |
