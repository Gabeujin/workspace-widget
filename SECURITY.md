# Security policy

## Reporting a vulnerability

Use the repository's
[private vulnerability-reporting form](https://github.com/Gabeujin/workspace-widget/security/advisories/new).
Do not include exploit details, private paths, credentials, or workstation
screenshots in a public issue. If the private form is unavailable, open a
public issue containing only a request for a private reporting channel; do not
include technical details in that issue.

Include:

- the affected version or commit;
- the Windows version used for reproduction;
- a minimal reproduction;
- expected and observed behavior;
- whether a configured URL, local path, Node entry file, or package script is
  required to reach the issue.

## Trust boundary

Workspace Widget is a local desktop launcher. It intentionally opens URLs,
files, shortcuts, and folders selected by the current Windows user. It can also
run a user-selected JavaScript entry file or package script when a configured
health endpoint is offline. Automatic Node startup requires that health endpoint
to be loopback. Remote health monitoring remains available only without an
automatic Node start target.

Only add trusted local paths, shortcuts, endpoints, media, and Node projects.
A launched program or package script has the same permissions as the current
Windows user. Health checks reveal the user's IP address to a remote endpoint
and may cause application-specific side effects if a badly designed endpoint
mutates state on `GET`.

`.lnk` files are resolved during registration. The saved entry points to the
real target and preserves the shortcut's arguments, working directory, icon,
and requested window style. Review those values before running a shortcut from
an untrusted source.

Remote raster media must resolve exclusively to public HTTPS addresses. Each
request connects directly to one of those validated addresses while TLS still
authenticates the original hostname, preventing DNS rebinding between
validation and connection. Redirect destinations are resolved and pinned
again. TLS protocol selection follows the Windows policy. Name mismatches,
explicitly revoked certificates, untrusted chains, and other chain errors are
rejected; only an unavailable or offline revocation service is soft-failed
after the remaining name and chain checks pass. Response time, address
candidates, redirects, header and chunk metadata, body size, content type, and
decoded dimensions are bounded before a local cache copy is rendered by
Windows imaging components.

The pinned downloader intentionally bypasses system HTTPS proxies because a
proxy would perform a second DNS resolution outside this boundary. Remote
icons and hover images therefore remain unavailable on networks that require a
mandatory HTTPS proxy; local images continue to work. Direct remote video
streams are rejected because the Windows media pipeline would otherwise
perform another request outside the bounded downloader. Local video remains
supported. YouTube hover previews use WebView2 and `youtube-nocookie.com`;
top-level navigation is restricted to the exact privacy-enhanced embed route,
web messages and host objects are disabled, permissions are denied, and popups
and downloads are cancelled. Media can still contain disturbing, misleading,
or copyrighted material, so only use assets you trust and are allowed to
display.

The Store MSIX declares `WorkspaceWidgetStartup` through
`windows.startupTask`. Settings can request enablement or disable the task, but
cannot override a user or organization policy decision. Windows keeps the
authoritative control in Startup Apps and Task Manager.

The Store package runs `WorkspaceWidget.exe` as a medium-integrity,
full-trust desktop process. It does not register `wscript.exe`, run a developer
checkout, request administrator elevation, or install a service or driver. The
branded native host embeds a Windows PowerShell 5.1 runspace in-process for the
current WPF implementation. The runspace loads only the application script
adjacent to the executable; a supplied project root is accepted only when it
resolves to that executable-owned root. The single-instance protocol requires
UI-ready and window-presented events before a launcher reports success.

The package includes a checksum-pinned official Node.js runtime and npm. The
widget invokes them only for a user-configured Node start target. Installed and
Store builds ignore runtime environment overrides and system `PATH`; those
fallbacks exist only for unpackaged source development.
It does not run `npm install`, resolve missing dependencies, or execute a
package script merely because a project is discovered. Package scripts still
run with the signed-in user's permissions and remain inside the user's trust
boundary. An offline restart never kills a process merely because it owns the
configured port. If the current widget instance still owns a live process tree,
it requires explicit confirmation before force-stopping that tree.

AX Store is a stricter exception to the generic local-server path. The Widget
may stop it only after verifying an ACL-protected, capability-signed ownership
receipt against the exact broker PID and creation time, executable and command
line, broker/launcher/runtime-contract hashes, both listener owners, and both
health contracts. The request travels over a capability-authenticated named
pipe, requires a reason and explicit impact acknowledgement, and invokes AX
Store's graceful shutdown export. Missing, stale, tampered, externally started,
PID-reused, or partially stopped instances fail closed; no `taskkill` fallback
is permitted. PostgreSQL and AX Runtime Agent targets remain out of scope.

The build validates the pinned Node archive before extraction. A previously
extracted dependency cache is reused only after every cached path, size, and
SHA-256 is compared directly with the entries in that already checksum-pinned
official archive. The writable cache manifest is a receipt, never the trust
anchor. An incomplete or mismatched cache fails closed, is not executed, and is
never overwritten automatically.
Release verification compares the complete stage and Node runtime with their
hash manifests before running any media probe or bundled executable.

Runtime state is saved atomically under
`%LOCALAPPDATA%\WorkspaceServiceWidget`. The previous valid document is retained
as `state.json.previous` and used for recovery when the current JSON is invalid.
Unknown future schema versions stop startup without falling back or writing the
state file, so installing an older widget cannot downgrade newer user data.
Malformed current JSON may recover from `state.json.previous`. State over 4 MB
and more than 250 shortcuts are rejected. Local images, GIF frames, managed
media-cache writes, and runtime-log growth also have explicit resource limits.

The repository records the dependency policy in
`security/official-security-baseline.json` and a separate release-day review in
`security/official-security-review.json`. As a conservative project-internal
freshness policy, the release receipt expires after at most three days; this is
not a Microsoft Store or WACK validity rule. CI checks the exact Node.js and WebView2 pins, archive-bound
runtime cache, package capability allowlist, packaged runtime isolation, local
path contamination, startup boundaries, and both expiries. This gate
supplements rather than replaces Windows App Certification Kit, malware
scanning, Partner Center certification, and Store-signed lifecycle testing.

A Node.js security release rated HIGH or CRITICAL, a relevant WebView2 Runtime
security update, or a Microsoft Store policy/restricted-capability change
invalidates the waiting period. Re-review the official baseline, replace the
affected runtime, rebuild, and rerun every release gate immediately.

WebView2 runs with the signed-in standard user's privileges. Remote media and
YouTube content must never be connected to privilege elevation or arbitrary
native host-object access.

The supported public binary is the Microsoft Store-signed, certified MSIX.
Unsigned producer MSIX files and unpackaged local development artifacts must
not be presented as official downloads or sideloaded by ordinary users. The
legacy Inno Setup path remains development and migration tooling only; any
separately distributed MSI or EXE would require its own publicly trusted,
timestamped publisher signature.

## Supported releases

No version is under public security support until the first Microsoft
Store-certified release.
