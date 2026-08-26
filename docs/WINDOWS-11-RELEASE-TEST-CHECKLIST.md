# Workspace Widget independent Windows 11 release checklist

- Prepared: 2026-07-30
- Target: app release 0.1.0 / Store package identity 1.0.0.0, x64
- Required environment: an independent supported Windows 11 device

This checklist is intentionally not marked complete on the development
workstation. Docker, Windows containers, and Linux containers cannot validate
WindowsApps deployment, a WPF window, notification-area behavior, StartupTask,
MSIX update/uninstall, or Windows App Certification Kit results.

## Pass criteria

A Store candidate passes this gate only when:

- every required case below is marked Pass with evidence;
- the exact package and receipt hashes match the uploaded candidate;
- Windows App Certification Kit reports no unresolved failure;
- P0 and P1 findings are zero;
- no private workstation state appears in the package, reports, or screenshots;
- uninstall and retained-state behavior match the published privacy policy.

## Test record

| Field | Value |
| --- | --- |
| Tester | `<name>` |
| Test date and timezone | `<ISO date/time>` |
| Device manufacturer/model | `<value>` |
| CPU and RAM | `<value>` |
| Windows edition | `<value>` |
| OS build | `<value>` |
| Display resolution and scale | `<value>` |
| Account type | Standard user / Administrator |
| Microsoft Store account | `<masked identifier or none>` |
| Candidate source commit | `<40-character commit>` |
| Package version | `<four-part MSIX version>` |
| MSIX SHA-256 | `<hash>` |
| Receipt SHA-256 | `<hash>` |
| Node.js version in package | `<version>` |
| WebView2 Runtime version | `<version>` |
| WACK version | `<version>` |

Do not place passwords, tokens, private URLs, personal email addresses, or
unredacted user-profile paths in the archived evidence.

## A. Pre-install package verification

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| A-01 | Verify the source checkout is at the recorded commit and clean | No tracked or untracked release input is missing | `<Pass/Fail + evidence>` |
| A-02 | Run `Test-WorkspaceWidgetMsix.ps1 -StoreCandidate` against the exact MSIX, receipt, identity, and stage manifest | All package, identity, hash, provenance, startup, and capability checks pass | `<Pass/Fail + log>` |
| A-03 | Compare package SHA-256 with the upload record | Hashes are byte-identical | `<Pass/Fail + hash>` |
| A-04 | Inspect package contents for state, logs, private shortcuts, source-only tests, installers, and diagnostics | None are present | `<Pass/Fail + inventory>` |
| A-05 | Verify `Package/Identity/Name`, Publisher, and PublisherDisplayName | Exact Partner Center values | `<Pass/Fail + redacted manifest excerpt>` |
| A-06 | Verify package version, architecture, and OS target | package 1.0.0.0; x64; Windows.Desktop minimum 10.0.22000.0 | `<Pass/Fail>` |
| A-07 | Verify capabilities and extensions | Only expected `runFullTrust` and one disabled `windows.startupTask` | `<Pass/Fail>` |

## B. Clean install and first launch

For pre-Store rehearsal, use a development-signed package whose certificate is
trusted only on the test device. For the final acceptance pass, install through
the certified Microsoft Store listing.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| B-01 | Confirm Workspace Widget is not installed before the test | No existing package family or unpackaged process | `<Pass/Fail>` |
| B-02 | Install the package as the signed-in user | Installation completes without a custom installer, console, service, or elevation prompt beyond the chosen test method | `<Pass/Fail + deployment log>` |
| B-03 | Launch from Start | One visible Workspace Widget window and one primary process; no console window | `<Pass/Fail + screenshot/process list>` |
| B-04 | Inspect the first-run workspace | Public clean defaults only; no developer-machine shortcut or state | `<Pass/Fail + screenshot>` |
| B-05 | Close and relaunch | Window position and supported settings persist | `<Pass/Fail>` |
| B-06 | Move the window partly off-screen, exit, change display geometry, and relaunch | Window recovers into a visible work area | `<Pass/Fail>` |

## C. Shortcut and launcher behavior

Use disposable public-safe fixtures. Do not test with confidential files or
production systems.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| C-01 | Add an EXE, file, folder, `.url`, HTTPS URL, and loopback HTTP URL | Each card has the correct type and opens the selected target | `<Pass/Fail>` |
| C-02 | Drop the same supported target onto the widget | The add flow succeeds without duplicating hidden state unexpectedly | `<Pass/Fail>` |
| C-03 | Add a `.lnk` with arguments, working directory, icon resource, and window style | The stored card targets the resolved executable and preserves metadata | `<Pass/Fail + sanitized state excerpt>` |
| C-04 | Add a URL with an explicit port | Card displays `Port ####` | `<Pass/Fail>` |
| C-05 | Edit, move earlier/later, hide, show hidden, restore, and remove a card | Ordering and visibility persist; remove deletes only the widget entry, never the target | `<Pass/Fail>` |
| C-06 | Restart after changes | All intended cards and ordering return | `<Pass/Fail>` |

## D. Health check and bundled Node.js

Use a small local fixture bound only to `127.0.0.1`. Record its source and hash
with the evidence.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| D-01 | Register a loopback URL and `/health` endpoint while the fixture is online | Green online indicator appears and the explicit port is shown | `<Pass/Fail>` |
| D-02 | Stop the fixture and refresh | Card becomes offline without freezing the UI | `<Pass/Fail>` |
| D-03 | Configure a trusted `.js`, `.mjs`, or `.cjs` Node target and click while offline | Packaged Node.js starts the target; app waits for health and then opens the URL | `<Pass/Fail + process/log>` |
| D-04 | Configure a package directory with an existing dependency set | Configured package script starts; the app does not install dependencies | `<Pass/Fail>` |
| D-05 | Configure an invalid target or a health endpoint that never becomes ready | User-visible failure occurs within the bounded timeout; no orphan launcher process remains | `<Pass/Fail>` |
| D-06 | Attempt a non-loopback private-network health target unless explicitly allowed by product policy | Request is rejected or handled exactly as the documented network boundary requires | `<Pass/Fail>` |

## E. Appearance, media, and input safety

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| E-01 | Change theme, custom colors, opacity, and hover brightness | Values apply immediately, remain readable, and persist | `<Pass/Fail>` |
| E-02 | Set a local image, GIF, and local video where supported | Media renders with expected mute and fallback behavior | `<Pass/Fail>` |
| E-03 | Add a bounded public HTTPS raster icon whose URL has an expiring query token | Preview must succeed before save; a local cached copy remains after the URL expires | `<Pass/Fail + cache metadata>` |
| E-04 | Paste an image from the clipboard | Preview and save work without exposing clipboard data elsewhere | `<Pass/Fail>` |
| E-05 | Add a valid YouTube URL | Validated poster appears; hover playback uses the privacy-enhanced embed when WebView2 is available | `<Pass/Fail>` |
| E-06 | Try malformed URLs, private-address redirects, oversized responses, invalid MIME types, SVG/script payloads, and direct remote video | Each unsafe input is rejected without code execution, credential access, or unbounded download | `<Pass/Fail + cases>` |
| E-07 | Exercise WebView2 permission, popup, download, message, and host-object attempts | All are denied by the documented boundary | `<Pass/Fail>` |

## F. Window modes, tray, and startup

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| F-01 | Enable Always on top and focus several ordinary applications | Widget remains above ordinary non-elevated windows | `<Pass/Fail>` |
| F-02 | Disable Always on top | Other applications can cover the widget | `<Pass/Fail>` |
| F-03 | Enable MIN UI on the left and right edges | Width becomes 96 px, icon rail is usable, and the widget snaps to the nearest edge | `<Pass/Fail + screenshots>` |
| F-04 | Resize and scroll the normal widget at 100%, 125%, and 150% display scale | No clipped controls, scroll trap, severe stutter, or unreadable hover state | `<Pass/Fail>` |
| F-05 | Select the close button | Window hides to the notification area; process remains running | `<Pass/Fail>` |
| F-06 | Restore from the tray | Existing window returns to a visible position and foreground | `<Pass/Fail>` |
| F-07 | Select tray right-click > Exit | Window and primary process exit completely | `<Pass/Fail>` |
| F-08 | Confirm Start with Windows is disabled on first install | StartupTask state is Disabled | `<Pass/Fail>` |
| F-09 | Enable Start with Windows, sign out, and sign back in | One widget instance starts through the package StartupTask | `<Pass/Fail + startup evidence>` |
| F-10 | Disable the startup entry in Windows Settings and sign in again | App respects the user decision and does not re-enable itself | `<Pass/Fail>` |
| F-11 | Apply an organization policy that disables startup, if an appropriate test device exists | App reports the policy-controlled state and does not bypass it | `<Pass/Fail/Not applicable>` |

## G. Update and state migration

Prepare two clean packages with the same Partner Center identity and increasing
versions. Never reuse a package version for different bits.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| G-01 | Install version A and create public-safe custom state | State file and `.previous` recovery copy are valid | `<Pass/Fail + hashes>` |
| G-02 | Update to version B through the supported package path | Update succeeds and binaries match version B | `<Pass/Fail>` |
| G-03 | Launch version B | State, layout, shortcut metadata, settings, and cached supported media migrate without loss | `<Pass/Fail + before/after hashes>` |
| G-04 | Interrupt or corrupt one state write in a controlled fixture | Atomic write or `.previous` recovery prevents an unrecoverable blank state | `<Pass/Fail>` |
| G-05 | Re-run core shortcut, Node, media, tray, and startup cases on version B | No update regression | `<Pass/Fail>` |

## H. Uninstall and reinstall

Uninstall does not authorize permanent deletion of the retained user-state
directory.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| H-01 | Uninstall from Windows Settings or the Store | Package, Start entry, package startup task, and running process are removed | `<Pass/Fail>` |
| H-02 | Inspect the documented per-user state directory without deleting it | State remains, matching the published privacy policy | `<Pass/Fail + hash>` |
| H-03 | Reinstall the same or newer certified package | Existing layout is restored and the app remains functional | `<Pass/Fail>` |
| H-04 | If a separate clean-state test is required, obtain explicit deletion approval for the exact state path before removal | No deletion occurs without recorded approval | `<Pass/Fail/Not run>` |

## I. Windows App Certification Kit

Use the current Windows SDK and run WACK in an active signed-in user session.
The standard command-line pattern for an installed package is:

```powershell
& 'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe' reset
& 'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe' `
  test `
  -packagefullname '<exact package full name>' `
  -reportoutputpath 'C:\WorkspaceWidgetReleaseEvidence\WACK-report.xml'
```

For an uninstalled package rehearsal, use `-appxpackagepath` with the exact
package path. Archive both XML and HTML output when the UI produces them.

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| I-01 | Run WACK against the exact candidate | Test completes in an active user session | `<Pass/Fail + kit version>` |
| I-02 | Review deployment, launch, manifest, supported API, binary, and performance results | No unresolved failure | `<Pass/Fail + report>` |
| I-03 | Rebuild after any correction and rerun the full applicable suite | Final report matches the final MSIX hash | `<Pass/Fail>` |

## J. Security and release evidence

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| J-01 | Run public-source and secret scans from the exact clean commit | No reportable secret or private path | `<Pass/Fail + CI URL>` |
| J-02 | Run dependency and network-boundary checks | No unresolved reportable finding | `<Pass/Fail + log>` |
| J-03 | Scan the exact MSIX with Microsoft Defender | Zero detections | `<Pass/Fail + report>` |
| J-04 | Scan the exact MSIX with one additional reputable scanner | Zero detections | `<Pass/Fail + report>` |
| J-05 | Confirm Privacy and Support URLs over HTTPS | HTTP 200, correct content, no redirect to an unrelated page | `<Pass/Fail>` |
| J-06 | Verify all four Store screenshots and listing text contain no private data or unsupported certification claim | Public-safe | `<Pass/Fail>` |
| J-07 | Compare the uploaded Partner Center package hash with the approved local record | Exact match | `<Pass/Fail>` |

## K. Post-certification acceptance

| ID | Test | Expected result | Result/evidence |
| --- | --- | --- | --- |
| K-01 | Verify Partner Center certification status and package version | Submission is certified for the intended markets | `<Pass/Fail + submission ID>` |
| K-02 | Install from the public or private-audience Store listing on the independent device | Store-signed package installs without certificate setup | `<Pass/Fail>` |
| K-03 | Verify package identity and signature | Exact Partner Center identity; signature trusted as delivered by Microsoft Store | `<Pass/Fail>` |
| K-04 | Repeat first launch, core shortcut, startup, tray, Node, media, update, and uninstall smoke tests | No Store-delivery regression | `<Pass/Fail>` |
| K-05 | Verify product, privacy, support, screenshots, category, age rating, and support information in the live listing | Listing matches the approved submission | `<Pass/Fail>` |

## Evidence index

Create one immutable release-evidence directory outside the source checkout:

```text
WorkspaceWidget-0.1.0-evidence/
  candidate/
  receipts/
  install/
  runtime/
  update/
  uninstall/
  wack/
  security/
  partner-center/
  index.json
```

`index.json` should record the test ID, timestamp, tester, source commit,
package version, source file, evidence file, size, modified time, and SHA-256.
Do not copy private state into that archive.

## Official references

- [Run, debug, and test an MSIX package](https://learn.microsoft.com/windows/msix/desktop/desktop-to-uwp-debug)
- [Windows App Certification Kit](https://learn.microsoft.com/windows/uwp/debug-test-perf/windows-app-certification-kit)
- [Windows App Certification Kit tests](https://learn.microsoft.com/windows/uwp/debug-test-perf/windows-app-certification-kit-tests)
- [MSIX troubleshooting guide](https://learn.microsoft.com/windows/msix/msix-troubleshooting-guide)
