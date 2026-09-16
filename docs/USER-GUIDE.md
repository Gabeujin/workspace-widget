# Workspace Widget User Guide

Workspace Widget is a per-user desktop launcher for Windows 11 x64. It opens
local applications, files, folders, and web apps from a movable WPF widget. It
can also monitor optional health endpoints and start a configured local server
before opening its URL.

This guide describes the 0.2.0 candidate and intended Microsoft Store experience and the
feature behavior verified on the current development build. No certified Store
listing is available yet. Packaged startup, update, uninstall, and reinstall
behavior remains subject to the release gates in
[PUBLIC-RELEASE-REVIEW.md](../PUBLIC-RELEASE-REVIEW.md).

## System requirements

- 64-bit Windows 11, build 22000 or later
- Windows PowerShell 5.1, included with supported Windows 11 installations
- A standard Windows user account
- Microsoft Edge WebView2 Evergreen Runtime only if YouTube hover playback is
  required
- No separate Node.js installation is required for configured local services;
  a checksum-pinned Node.js runtime and npm are included in the application
  package

The current package does not install pnpm or the WebView2 Evergreen Runtime.

## Install

After certification, install Workspace Widget from its Microsoft Store listing.
The intended experience is for Windows to install and update the Store-signed
MSIX for the signed-in user. Launch it from Store or Start, then optionally
enable **Start with Windows** in the app. Until certification succeeds, no
supported public package or Store listing is available.

### Unsigned development builds

The repository can produce an unsigned producer MSIX for Partner Center
submission. It is not a sideloadable public build. Only the Store-signed,
certified package is supported for public use.

## First launch

`WorkspaceWidget.exe` displays a short fade-in and fade-out logo, then opens the
widget without a console window. Only one widget instance runs for the current
Windows session. Launching the desktop or Start menu shortcut again asks the
existing instance to show itself.

The widget does not appear as a normal taskbar button. Use its notification-area
icon when the window is hidden.

## Add a shortcut

Select **Add** or **Add shortcut**, then configure:

- **Name**: the label shown in the full layout.
- **URL or local path**: an HTTP/HTTPS URL or an existing application, file,
  folder, `.lnk`, or `.url` file.
- **Shortcut type**: choose an ordinary shortcut or a local server. Ordinary
  shortcuts do not show server controls. Local servers require a start target,
  a stop target, and at least one health check.
- **Health checks**: add or remove rows for the local server's loopback
  HTTP/HTTPS endpoints. The current limit is 16 distinct endpoints per server;
  all must respond successfully for the card to be healthy.
- **Node start target**: a `.js`, `.mjs`, `.cjs`, or `.ps1` entry file, or a
  directory that contains `package.json`. Only configure trusted local code.
- **Start script / arguments**: a package script name for a project directory,
  or arguments for a JavaScript entry file.
- **Stop target / arguments**: a trusted local JavaScript or PowerShell stop
  helper and its arguments. Migrated server entries receive the bundled
  managed-stop helper; it requests shutdown only for verified Widget-owned work.
- **Built-in icon**: choose from 18 bundled semantic icons.
- **Custom icon image**: a local image, a Windows clipboard image selected with
  **Paste image**, or a public HTTPS image URL. Clipboard and HTTPS icons are
  previewed and must be visually confirmed before Save is enabled. Raster and
  clipboard icons are stored as transparent 256 x 256 local card assets so an
  expiring source URL does not later blank the shortcut. Static SVG URLs are
  supported.
- Use **Browse...** beside an image or hover-media path to select a local file
  instead of typing its path.
- **Hover media**: an optional trusted local source or public HTTPS media
  source. Remote raster images are bounded, validated, and cached before
  decoding. See
  [Media Customization](MEDIA-CUSTOMIZATION.md).

You can also drag supported files, folders, shortcuts, and URLs onto the
widget.

If a web URL includes an explicit port, such as
`http://127.0.0.1:43100/`, the card subtitle displays `Port 43100`.

### What happens when a `.lnk` file is added

Workspace Widget resolves a Windows Shell Link when it is registered. It stores
the link's:

- actual `TargetPath`;
- command-line arguments;
- working directory;
- icon location; and
- requested window style.

The card launches the resolved target rather than launching the `.lnk` file
again. The original `.lnk` path is retained as source metadata, but the link
file is not copied into the application.

This has several consequences:

- Moving or deleting the original `.lnk` does not normally break the registered
  item if the resolved target still exists.
- Moving or deleting the resolved application does break the item.
- Environment variables in the link are expanded when it is registered.
- Shell links that do not expose an existing file-system target cannot be
  registered by the current version.
- Product-specific Shell Link behavior beyond the stored fields is not
  reproduced.

Do not place passwords, tokens, or other secrets in shortcut arguments. The
arguments are stored as plain text in the current user's state file.

### Health checks and local server startup

Local server entries poll their configured health endpoints and show the
combined result on the card. Ordinary shortcuts do not poll health endpoints.

When the user opens an offline item that also has a Node start target, the
widget:

1. resolves a Node.js runtime and a pnpm or npm package runner;
2. starts the configured entry file or package script with the current user's
   permissions;
3. waits for the configured health checks within the startup deadline; and
4. opens the target URL when it becomes healthy.

Every local server card always includes separate **Start** and **Stop** actions.
Start checks the existing instance before launching and does not open its URL.
Stop first verifies ownership, runs the registered stop helper, and checks that
the owned process group and health endpoints stopped. The graceful-stop budget
is 40 seconds. A remaining verified process may be force-stopped only after
confirmation. A missing or foreign process is not permission to terminate it.
Ordinary shortcuts never show these server actions.

Recovery verifies the supervisor and saved launch identity before stopping a
server. A surviving supervisor can be recovered after the Widget reopens. A
foreign listener never grants stop authority. Force-stop requires confirmation
because unsaved server work can be lost. See [Server lifecycle](SERVER-LIFECYCLE.md).

Installed and Store builds enforce their package-local runtime and ignore
development overrides and system `PATH`. An unpackaged source checkout uses:

1. `runtime\node\node.exe`, `runtime\node\npm.cmd`, or
   `runtime\pnpm\pnpm.cmd` inside the project directory;
2. `WORKSPACE_WIDGET_NODE`, `WORKSPACE_WIDGET_PNPM`, or
   `WORKSPACE_WIDGET_NPM` as development-only overrides;
3. `node.exe`, `pnpm.cmd`, or `npm.cmd` on `PATH`.

For a project directory, pnpm is preferred when present and the included npm is
the fallback. Workspace Widget does not install missing project dependencies.

Only configure projects you trust. A package script can perform any action
available to the signed-in Windows user.

## Manage registered items

Right-click a card to use the available management actions:

- **Start** and **Stop** for local servers only
- **Edit**
- **Move earlier**
- **Move later**
- **Hide**
- **Remove shortcut...**

Removal affects only the Workspace Widget registration. It does not delete the
original application, file, folder, URL, `.lnk`, or media file. A confirmation
dialog is shown before removal.

Enable **Settings > Show hidden** to see and restore hidden items.

## Window controls

### Move and resize

Drag the header to move the widget. Resize it from the bottom-right resize
handle. Position, size, layout mode and opacity are saved automatically.
Appearance changes require **Apply**; shortcut edits require **Save**.

Dragging is not constrained to the initial display. **Settings > Snap to screen
edges** controls whether a completed drag near the left or right edge snaps to
that edge. Buttons and other interactive header controls do not start a drag.

Use **Settings > Reset size** if the full layout becomes inconvenient.

The application attempts to recover a saved window that is no longer inside an
active display work area, such as after disconnecting a monitor.

### Opacity and hover brightness

Open **Settings** to choose a resting window opacity from 35 to 100 percent.
Full and MIN UI modes share this value. On upgrade from separate mode settings,
the last active mode's value is retained; changing layout does not reset it.
When **Settings > Hover brightness** is enabled, moving the pointer over the
widget temporarily raises it to full opacity.

Background-media opacity is a separate setting. It does not change the opacity
of the whole window.

### Theme and background media

Open the **Appearance & media** page within **Settings** to choose a preset,
custom colors, or a background image/video. The page uses the selected Korean
or English language, including preset labels and validation feedback. Theme
identifiers in saved state do not change when switching language.

Choose **Apply** to validate and save the appearance draft. **Cancel** restores
the last applied values. Closing Settings without applying discards this draft;
other settings, such as opacity and language, remain immediate preferences.

### Language and motion

The unified Settings window also contains **Language** (Korean or English) and
**Reduce motion**. Changing language updates the existing widget controls.
Reduced motion suppresses transitions; Windows animation preferences are also
respected. Settings use an opaque, independently sized window in both layouts.

### Always on top

Enable **Settings > Always on top** to keep the window in the Windows topmost
band above ordinary folders, browsers, and applications.

Some secure Windows surfaces, full-screen applications, and system UI can still
appear above it.

### Desktop layer

Enable **Settings > Keep on desktop layer when inactive** to return the widget
behind ordinary application windows after it loses focus. This is useful when
the widget should behave like a desktop accessory rather than a floating
toolbar.

Opening the widget from its shortcut or tray icon temporarily brings it to the
front. It returns to the desktop layer after it loses focus.

**Always on top** takes precedence over the desktop-layer behavior. Turn off
Desktop layer if you always want the widget to remain in the normal application
window band without making it topmost.

The source-checkout launcher also supports a temporary
`-NoDesktopAttach` option. That launch-only override disables the Desktop layer
for the current process and disables its settings checkbox; it does not rewrite
the saved preference.

### MIN UI

Enable **Settings > MIN UI mode** or use the compact-mode header button to
switch to a 96-pixel-wide icon rail.

MIN UI:

- shows shortcuts as icons;
- hides secondary labels and controls;
- uses the same resting opacity as full mode;
- suppresses hover-media previews; and
- supports optional edge snapping when released near a screen edge.

Use the compact-mode button again to restore the saved full layout.

## Hide, restore, and exit

The header close button and `Alt+F4` hide the widget to the notification area.
They do not stop the process.

To restore it:

- launch the desktop or Start menu shortcut again;
- double-click the notification-area icon; or
- right-click the notification-area icon and select **Open Workspace**.

To close the launcher, right-click the notification-area icon and select
**Exit Widget (servers keep running)**. To stop a managed server, use its card's
**Stop** first. Reopening the Widget reconnects to verified supervisors.

## Start with Windows

In the intended Store package, **Settings > Start with Windows** controls the
package-declared Windows startup task:

```text
WorkspaceWidgetStartup
```

The manifest and application bridge for this task pass the current structural
checks. The exact packaged behavior remains an independent Windows 11 release
gate. When certified, the task is intended to start the packaged application
for the signed-in user, while Windows keeps the authoritative setting in
**Settings > Apps > Startup** and Task Manager.

The settings status is designed to report:

- **On**: the startup task is enabled.
- **Off**: the task is disabled.
- **Disabled by user**: Windows preserves a user decision that the app cannot
  override.
- **Managed by policy** or **Unavailable**: organization policy or Windows did
  not allow the setting to be changed.

Turning Start with Windows off is designed to disable the declared task. The
Store package design does not create or repair a Task Scheduler entry.

## State, logs, and upgrades

User state is separate from installed program files:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget\state.json
```

The runtime also uses:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget\state.json.previous
%LOCALAPPDATA%\WorkspaceServiceWidget\runtime.log
%LOCALAPPDATA%\WorkspaceServiceWidget\host.log
%LOCALAPPDATA%\WorkspaceServiceWidget\WebView2\
```

State writes are performed through a temporary file and replace operation. If
an existing primary JSON file is invalid, the application refuses to overwrite
it; restore a verified backup before reopening. Future unknown state
schemas are also rejected instead of silently rewritten. A state document is capped
at 4 MB and 250 shortcuts; `runtime.log` stops growing at 4 MB.

Managed `IconCache` and `MediaCache` directories each enforce a 128 MB write
budget. Workspace Widget does not silently delete cached files. Close the app,
back up the state directory, and review cache contents manually if the limit is
reached.

The Store release is designed to preserve package identity and keep this state
directory outside immutable package files. Registered items and preferences are
therefore expected to remain available across normal upgrades and reinstalls.
Exact update and reinstall behavior will be independently verified on the
Store-signed package before certification.

For a manual backup:

1. exit the widget from its tray menu;
2. copy the entire `%LOCALAPPDATA%\WorkspaceServiceWidget` directory to a
   protected location; and
3. keep the backup with the application version that created it.

Do not edit or synchronize `state.json` while the widget is running.

## Uninstall

Windows Settings or Microsoft Store will be able to uninstall the certified
Workspace Widget package. Package removal is expected to remove the managed
package and its startup-task declaration while leaving the separately stored
per-user state available for a later reinstall. Exact uninstall and reinstall
retention behavior will be independently verified on the Store-signed package
before certification.

Removing the retained state is a separate, destructive action. Review and
approve the exact directory before deleting it.

## Troubleshooting

### The process is running but the widget is not visible

1. Launch the Workspace Widget shortcut again.
2. Use the notification-area icon and select **Open Workspace**.
3. Temporarily turn off **Keep on desktop layer when inactive**.
4. Check whether **Always on top** matches the intended behavior.
5. Review `runtime.log` for visibility, Desktop layer, or state-recovery
   messages.

### A shortcut no longer opens

- Confirm that the stored target still exists.
- For a `.lnk` registration, confirm the resolved executable rather than only
  the original link file.
- Check whether its saved working directory still exists.
- Edit and save the item again if the application was moved.

### YouTube hover playback shows only a poster

Install or repair the Microsoft Edge WebView2 Evergreen Runtime. Workspace
Widget does not install that runtime itself. Poster fallback is expected when
WebView2 is unavailable.

Standard YouTube share links in the form
`https://youtu.be/<11-character-video-id>` can be pasted directly. Workspace
Widget resolves the video identifier and supplies the WebView2
client-identification headers required by the embedded player.

### HTTPS custom icon cannot be saved

Wait for the automatic preview to complete, visually inspect it, then select
**I confirm this preview is the icon I want**. Save remains disabled if the URL
does not resolve to a public HTTPS image, exceeds 2 MB, has an unsupported
content type, cannot decode, or contains active/external SVG content.
An existing verified cache remains editable when its tokenized source expires;
the local card copy remains active even if Retry cannot reach the source.
Select **Retry preview** only when you want to fetch the source again.
For a Flaticon-style `token=exp=...` URL, the preview shows the expiration time.
If no verified local copy exists after that time, copy a fresh address or use
**Paste image** with an image you are licensed to use.

### Clipboard custom icon cannot be pasted

Copy the image itself rather than only its page URL, then select **Paste image**
in the shortcut editor. The input must be at most 8192 pixels per side,
32 megapixels, and 10 MB as a PNG. It is aspect-fit into a transparent
256 x 256 local card asset. After the preview appears, select **I confirm this
preview is the icon I want** to enable Save.

### Start with Windows is disabled by the user or policy

Review **Settings > Apps > Startup** and organization policy. The app cannot
override a user-disabled or policy-controlled startup task.

### Media does not load

See [Media Customization](MEDIA-CUSTOMIZATION.md#troubleshooting-media).
