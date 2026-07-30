# Installing Workspace Widget

Workspace Widget supports 64-bit Windows 11 build 22000 or newer only.

No certified Microsoft Store listing is available yet. After certification,
the supported public installation will be the Microsoft Store listing. Windows
will install and service the Store-signed MSIX under its managed package
location. No administrator permission is expected for a normal Store install.

The application package includes a pinned Node.js runtime and npm for local
services that the user explicitly configures. It does not install Node.js
machine-wide or automatically install project dependencies.

Runtime settings and shortcuts are kept separately:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget
```

Store updates are designed to preserve this folder. Uninstall is expected to
remove the package and its startup-task registration while intentionally
leaving user settings in place. These lifecycle behaviors remain subject to
the independent-device and Store-certification gates.

## Install after Store certification

When the certified listing becomes available:

1. Open the certified Workspace Widget listing in Microsoft Store.
2. Verify the publisher shown in the listing.
3. Choose **Install**, then launch Workspace Widget from Store or Start.
4. Turn on **Settings > Start with Windows** only if desired. Windows may
   preserve a prior user or organization policy decision.

The app should show the Workspace logo, fade into the main window, and appear
as `WorkspaceWidget.exe` in Task Manager. It does not open a console window.

## Upgrade after Store certification

Microsoft Store will service newer package versions. The release checklist
requires proving that a package update replaces immutable application files
without replacing `state.json`, registered shortcuts, window geometry, theme,
or media settings.

## Uninstall after Store certification

Use Windows Settings → Apps → Installed apps → Workspace Widget → Uninstall.
The release checklist requires proving that user state remains under
`%LOCALAPPDATA%\WorkspaceServiceWidget` for a future reinstall. Removing that
retained state is a separate manual data-deletion decision.

## Development and migration builds

The repository retains an unpackaged/Inno path for developer testing and
migration rehearsals. Those artifacts are not the supported public
distribution and must not be linked as official downloads. See
`MICROSOFT-STORE-RELEASE.md` for the Store build and certification gates.

## Troubleshooting

- If the process is running but the window is behind other apps, launch the
  desktop shortcut again or choose **Open Workspace** from the tray. Explicit
  open waits for a window-presented acknowledgement.
- Toggle **Keep on desktop layer when inactive** when normal window behavior is
  preferred.
- Settings → **Start with Windows** reports whether the package startup task is
  enabled, disabled, disabled by the user, or controlled by policy.
- Runtime diagnostics are written under
  `%LOCALAPPDATA%\WorkspaceServiceWidget`.

Only the Microsoft Store-signed certified package is the supported public
binary. An unsigned local MSIX is a producer artifact for submission and must
not be sideloaded or presented as an official release.
