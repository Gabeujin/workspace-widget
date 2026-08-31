# Changelog

All notable changes to Workspace Widget are documented in this file.

The project follows semantic versioning for release artifacts. The current
0.1.0 build is a development preview and has not passed Microsoft Store
certification.

## Unreleased

### Added

- Eight original MIT-licensed semantic line icons, a keyboard-readable built-in
  icon selector, fail-closed asset validation, and a responsive review gallery.
- Clipboard custom icons with PNG normalization, bounded dimensions, automatic
  preview, and explicit confirmation before Save.
- Public HTTPS custom icons with automatic response, size, decode, and static
  SVG safety checks; local caching; rendered preview; and explicit user
  confirmation before Save.
- Deterministic 256 x 256 transparent card assets for remote raster, rendered
  static SVG, and clipboard icons, preserving aspect ratio in the app-managed
  icon cache.
- Microsoft Store MSIX manifest, exact Partner Center identity template,
  unsigned package builder, package-relative SHA-256 receipt, and Store release
  runbook.
- Read-only MSIX/receipt verifier, privacy policy, strict stage-manifest
  allowlist validation, clean-source binding, and deterministic-toolchain gate.
- Package-aware `windows.startupTask` integration for Store installations.
- Pinned Node.js 24.19.0 LTS Windows x64 runtime and npm in the installer for
  explicitly configured offline local services.
- Exact runtime content manifest and checksum validation for the bundled
  Node.js distribution.
- User guide for installation, shortcut registration, window modes, tray
  lifecycle, autostart, state, upgrade, and troubleshooting.
- Media guide for themes, local and HTTPS media, YouTube behavior, trust,
  privacy, and copyright.
- Enterprise deployment and contribution guidance, including Authenticode
  release requirements.

### Changed

- Official public distribution now targets Microsoft Store MSIX; Inno Setup
  remains local development and migration tooling only.
- Shortcut launches derive an explicit working directory so packaged child
  processes do not inherit the protected package install directory.
- Node restore reuses only a complete cache whose exact path, size, and SHA-256
  manifest is valid, and release probes run only after candidate and runtime
  hash validation.
- Package-directory startup now prefers pnpm when available and falls back to
  the bundled npm runner.
- The responsive toolbar switches to icon-only controls below 500 px, and
  shortcut cards and toolbar controls expose visible keyboard focus.
- Updated the bundled Node.js runtime to 24.19.0 LTS and the pinned WebView2 SDK
  bridge to 1.0.4129.50.
- Moved default build output and dependency caches outside the source checkout
  under `%LOCALAPPDATA%\WorkspaceWidget`.

### Fixed

- The rounded panel now owns the opaque themed surface while the native window
  corners remain transparent, removing the square outer silhouette and doubled
  radius border.
- Expiring `token=exp=...` icon URLs now show their local expiration time and
  keep using an existing verified local card copy after expiry. Retry failures
  preserve that copy instead of blanking the shortcut.
- Remote raster icons are dimension-bounded before decoding into a persistent
  card asset, preventing oversized images from consuming unbounded memory.
- YouTube hover previews now identify the desktop WebView2 client with a
  `Referer`, `origin`, and `widget_referrer`, preventing player error 153 for
  normal `youtu.be` share links.

### Security

- Installed packages now ignore environment and `PATH` Node overrides and use
  only their package-local pinned runtime.
- Added strict absolute URL validation, embedded-credential rejection,
  loopback-only health endpoints for automatic Node startup, and execution-time
  validation of local Node paths and arguments.
- Offline restart now confirms before force-stopping a widget-owned process tree
  and stops descendants together to prevent wrapper orphaning.
- Added state, shortcut, log, local image/GIF, and managed cache resource limits;
  unknown future state schemas fail closed.
- Added a 30-day expiring official-security baseline and CI gate for Node.js,
  WebView2, Store capability, package runtime, and local-path contamination.

- The native host now loads only its executable-adjacent application root and
  rejects a caller-selected external project root.
- Public HTTPS raster media is downloaded through an explicit redirect,
  address, size, content-type, and decoded-dimension boundary before local
  rendering.
- Remote HTTPS assets connect directly to a DNS-validated public IP while TLS
  validates the original host name, preventing a later DNS answer from
  redirecting the request into private address space.
- Special-purpose IPv4 and IPv6 ranges, excessive DNS candidates, ambiguous
  HTTP framing, oversized chunk metadata, and responses that exceed the shared
  ten-second deadline are rejected before remote media is cached.
- Direct remote video streams are rejected because the Windows media pipeline
  would otherwise issue a second request outside the bounded downloader. Local
  video and restricted YouTube hover playback remain supported.
- WebView2 hover playback disables host objects and web messages, denies
  permissions, popups, and downloads, and restricts top-level navigation to the
  privacy-enhanced YouTube embed route.

## 0.1.0 - 2026-07-29

### Added

- Native x64 Windows GUI host that runs the WPF application without a console
  window.
- Per-user Inno Setup installer for Windows 11 x64.
- Movable and resizable shortcut widget with persisted position, size, opacity,
  appearance, and registrations.
- Add, edit, reorder, hide, show, and confirmation-based registration removal.
- Drag-and-drop support for applications, files, folders, `.lnk`, `.url`, and
  HTTP/HTTPS URLs.
- Resolution of `.lnk` registrations to the actual TargetPath while preserving
  arguments, working directory, icon location, window style, and original link
  metadata.
- URL port subtitles and optional 30-second health polling.
- Trusted local Node.js or pnpm service startup followed by health readiness and
  URL launch.
- Windows shell icons for local targets.
- Smooth wheel scrolling and responsive full-layout header behavior.
- MIN UI 96-pixel edge-snapped icon rail.
- Hover brightness and Always on top settings.
- Desktop layer preference with explicit shortcut and tray presentation.
- Header hide-to-tray action, tray restore, and tray Exit.
- Single-instance restore signal and first-render readiness signal.
- Start with Windows control backed by an owned, limited-user scheduled task
  with a 30-second logon delay.
- Theme presets, custom WPF colors, and configurable background-media opacity.
- Local and direct HTTPS image and video support.
- Local animated GIF backgrounds and hover previews.
- YouTube background posters and privacy-enhanced YouTube hover playback through
  WebView2, with poster fallback.
- Pinned and checksum-verified WebView2 SDK dependency restore.
- Atomic state replacement and fallback to `state.json.previous`.
- Startup splash and fade transitions.

### Security

- Clean public default state contains no workstation shortcuts.
- Scheduled-task ownership and drift checks prevent replacement of unrelated
  tasks with the same name.
- Autostart runs interactively at limited privilege from a per-user private
  install root.
- WebView2 hover navigation is restricted to the YouTube privacy-enhanced embed
  path.
- Default WebView2 context menus and developer tools are disabled.
- Registration removal does not delete original files or targets.

### Known limitations

- Windows 11 x64 is the only supported platform.
- Development artifacts built without a certificate are unsigned and can
  trigger SmartScreen warnings.
- The current installer bundles Node.js and npm, but not pnpm or the WebView2
  Evergreen Runtime.
- YouTube backgrounds are posters; only shortcut hover can use embedded
  playback.
- Animated GIF media must be local and uses a fixed frame interval.
- Video codec and HTTPS streaming support depend on Windows media components
  and the remote server.
- Shell links without an existing file-system TargetPath are not supported.
