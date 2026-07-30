# Phase 7 local verification receipt

- Verification date: 2026-07-30 KST
- Scope: work that can be completed before Partner Center identity and
  certification are available
- Platform: current Windows 11 x64 development workstation
- Candidate type: unsigned development validation artifacts only

This receipt records the final local engineering checks. It is not Microsoft
Store certification, an independent-device lifecycle result, a WACK report, or
permission to distribute the unsigned artifacts.

## Verification results

| Gate | Result | Evidence |
| --- | --- | --- |
| Public-source hygiene | Pass | 68 tracked files in the Git index, 10 maintainer-local denylist terms loaded, 0 findings |
| Scanner negative controls | Pass | Automated CI fixtures rejected Git-history enumeration failure and an empty commit set. Additional local fixtures rejected tracked text, VBS content, a binary path, and a non-noreply commit; a GitHub Actions bot noreply fixture was accepted |
| Tracked PowerShell parse | Pass | 15 tracked `.ps1` files, 0 parser errors |
| Current-device integration | Pass | 48/48 checks; one responsive installed process; configured services online |
| Remote network boundary | Pass | 11/11 checks, including mixed-address, framing, size, certificate, and timeout rejection |
| Unpackaged release structure | Pass | 17/17 checks; exact allowlist, hashes, source/stage parity, Node runtime, WebView2 bridge, and sensitive-text checks |
| Development MSIX structure | Pass | 14/14 checks; identity, architecture, StartupTask, capabilities, dependencies, receipt, and payload allowlist |
| Public media inventory | Pass | All 18 tracked screenshot, Store, source-capture, and brand images match their recorded dimensions and SHA-256 values; suspicious image metadata findings: 0 |
| Whitespace and Store canvas | Pass | `git diff --cached --check` exited 0; all four Store PNGs contain zero non-opaque pixels and use `#09162B` at every outer corner |
| Public web | Pass | Product, Privacy, Support, and source URLs returned HTTPS 200; lifecycle-qualified privacy copy was deployed by Pages workflow run `30536510159` |
| Rendered web interaction | Pass with tool limitation | Product content rendered without console warnings/errors; English/Korean locale, light/dark theme, Privacy, and Support navigation responded correctly. The selected browser surface did not expose a screenshot API, so committed native captures remain the visual evidence |
| GitHub repository controls | Maintainer-verified | Authenticated API checks showed dependency alerts, automated security updates, secret scanning, push protection, and private vulnerability reporting enabled; open Dependabot and secret-scanning alerts: 0 |
| Independent negative review | Pass | P0: 0, P1: 0, P2: 0; engineering quality: 9.9/10 |
| Pushed clean-checkout CI | Pass | Push run `30537886939` and pull-request run `30537891453` passed on Phase 7 closeout commit `446d344` |

The public-source scanner has no path-specific self-exemption. Its tracked-text
coverage includes scripts, VBS, web formats, PowerShell data/modules,
Git control files, and known extensionless text files. An ignored local
denylist augments generic credential, path, signed-query, and local-artifact
patterns without publishing private terms. The denylist file itself is
forbidden from tracking.

## Historical public-source note

All three public commits that existed before this change were reviewed. Their
historical blobs contain nine matches for legacy maintainer-local denylist
literals, all in the old `scripts/Test-PublicSource.ps1` pattern definitions.
The matches are project/product names and one public media identifier; no
credential, user-profile path, private endpoint, source data, or personal email
was present. Commit subjects, author names, and emails were also public-safe
GitHub noreply metadata.

The current tree removes those literals and replaces them with the ignored
local denylist. The public Git history and source-only RC tag were not rewritten:
history rewriting is destructive, invalidates existing references, and
requires a separate explicit maintainer decision. Because the historical
strings are not secrets and are already public, this is recorded as accepted
historical metadata rather than a credential-removal incident.

## Development artifact trace

These hashes identify the local validation artifacts. They are deliberately not
published as downloads.

- Evidence set: `WW-PHASE7-20260730-201713`
- Source revision: `446d3441a8dada61ad9bd0913aa975ee6f97f74d`

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `WorkspaceWidget-0.1.0-manifest.json` | 432,920 bytes | `CB7DBF932F687BF89D490E4A3F6BAA23735C41585AC208F4D50430E99BAF257D` |
| `WorkspaceWidget-Setup-0.1.0.exe` | 27,493,364 bytes | `6F79C541D084A01DF472CEC9BEA28EA4DF30FFF97C97461500641A740C62E72B` |
| `WorkspaceWidget-0.1.0-x64.msix` | 41,667,453 bytes | `70BD960E9A84E24BD5DE56D578C2D4FF6F0CFD3C5761FDFF4C5A090696B68471` |
| `store-package-receipt.json` | 434,439 bytes | `08EF251C5703B3D743EDCD5534595C754C20DDB8E526C97C46B28CCB9FD4E59E` |
| Bundled Node.js archive | — | `EC56B84A7551893AB2324EBDFDC4AB974A63B4781162600B68A1293CC3E53765` |

The development MSIX uses the placeholder
`WorkspaceWidget.Development` identity and is unsigned. Its structural verifier
reported `producerPackageUnsigned=true`; the release verifier reported
`publicReady=false` and `signed=false` as expected. Those results are safeguards,
not failures.

## Malware scan

ESET Security command-line scanner 12.0.2058.0, scanner module 33587
(2026-07-30), scanned the fresh unpackaged and development-MSIX output with
cleaning and quarantine disabled:

- 4,028 files;
- 8,061 objects;
- 0 detected files or objects;
- 0 cleaned files or objects;
- exit code 0;
- scan-log SHA-256:
  `AC9EFD9096D53E1FF2826CB8C0588070483E266176633F6E54011248C586620A`.

This scan applies only to the development validation artifacts identified
above. The exact Store-targeted candidate must be scanned again after Partner
Center identity is applied.

## Reproduction commands

Run from a clean checkout on Windows:

```powershell
.\scripts\Test-PublicSource.ps1
.\scripts\Test-PublicSourceNegativeControls.ps1
.\scripts\Test-WorkspaceWidgetNetworkBoundary.ps1
.\scripts\Test-WorkspaceWidget.ps1
.\scripts\Build-WorkspaceWidget.ps1 -Version 0.1.0 -OutputRoot <fresh-output>
.\scripts\Test-WorkspaceWidgetRelease.ps1 `
  -Version 0.1.0 `
  -OutputRoot <fresh-output> `
  -RequireInstaller
.\scripts\Build-WorkspaceWidgetMsix.ps1 `
  -Version 0.1.0 `
  -StageRoot <fresh-output>\staging\WorkspaceWidget `
  -StageManifestPath <fresh-output>\WorkspaceWidget-0.1.0-manifest.json `
  -OutputRoot <fresh-msix-output>
.\scripts\Test-WorkspaceWidgetMsix.ps1 `
  -PackagePath <fresh-msix-output>\WorkspaceWidget-0.1.0-x64.msix `
  -ReceiptPath <fresh-msix-output>\store-package-receipt.json
```

The final pull-request commit must also pass the repository's
`Public source gate` workflow before merge.

## Explicitly deferred Store gates

The following require Partner Center or an independent supported Windows 11
device and are not claimed by this receipt:

1. exact Package Identity Name, Publisher, and PublisherDisplayName;
2. clean `-StoreSubmission` build using that identity;
3. independent standard-user install, update, sign-in startup, tray, state
   migration, uninstall, and reinstall results;
4. WACK result for the exact candidate;
5. final listing properties, markets, IARC receipt, and `runFullTrust`
   submission;
6. Partner Center certification and Microsoft-signed Store installation.
