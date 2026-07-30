# Security policy

## Reporting a vulnerability

Use the repository's private security-advisory flow after the public repository
is established. Do not include exploit details, private paths, credentials, or
workstation screenshots in a public issue. A maintainer contact must be added
before the first official release.

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
health endpoint is offline.

Only add trusted local paths, shortcuts, endpoints, media, and Node projects.
A launched program or package script has the same permissions as the current
Windows user. Health checks reveal the user's IP address to a remote endpoint
and may cause application-specific side effects if a badly designed endpoint
mutates state on `GET`.

`.lnk` files are resolved during registration. The saved entry points to the
real target and preserves the shortcut's arguments, working directory, icon,
and requested window style. Review those values before running a shortcut from
an untrusted source.

Remote raster media must resolve only to public HTTPS addresses. Redirects,
response size, content type, and decoded dimensions are checked before a local
cache copy is rendered by Windows imaging components. Direct remote video
streams are rejected because Windows media playback would otherwise perform a
second network request outside that bounded downloader. Local video remains
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
widget invokes them only for a user-configured Node start target.
It does not run `npm install`, resolve missing dependencies, or execute a
package script merely because a project is discovered. Package scripts still
run with the signed-in user's permissions and remain inside the user's trust
boundary.

The build validates the pinned Node archive before extracting a fresh runtime;
it never executes a previously extracted mutable cache to identify a version.
Release verification compares the complete stage and Node runtime with their
hash manifests before running any media probe or bundled executable.

Runtime state is saved atomically under
`%LOCALAPPDATA%\WorkspaceServiceWidget`. The previous valid document is retained
as `state.json.previous` and used for recovery when the current JSON is invalid.

The supported public binary is the Microsoft Store-signed, certified MSIX.
Unsigned producer MSIX files and unpackaged local development artifacts must
not be presented as official downloads or sideloaded by ordinary users. The
legacy Inno Setup path remains development and migration tooling only; any
separately distributed MSI or EXE would require its own publicly trusted,
timestamped publisher signature.

## Supported releases

No version is under public security support until the first Microsoft
Store-certified release.
