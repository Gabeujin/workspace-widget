# Workspace Widget Privacy Policy

Last updated: 2026-08-26

Published copy:
<https://gabeujin.github.io/workspace-widget/privacy/>

This policy covers the Workspace Widget Windows desktop application and its
public product website. Workspace Widget is a local-first launcher. It does not
include a developer-operated account, analytics, advertising, telemetry, or
remote data-collection service.

## Data stored on the device

Workspace Widget stores its data under the signed-in Windows user's directory:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget
```

This directory can contain:

- `state.json` and `state.json.previous`, including layout and appearance
  settings, shortcut targets, launch arguments, working directories, health
  URLs, local-service settings, and media choices;
- `runtime.log` and `host.log`, which can include timestamps, local paths,
  configured URLs, and diagnostic error details;
- `IconCache` and `MediaCache`, including downloaded remote media and images
  that the user explicitly pastes from the clipboard; and
- the `WebView2` profile and cache used by an optional YouTube preview.

Workspace Widget reads an image from the clipboard only after the user chooses
the Paste image action. The selected image is saved as a local PNG in the icon
cache. These files remain on the device unless the user backs up, synchronizes,
shares, overwrites, or deletes them.

Configuration, logs, and managed caches are ordinary local files and are not
encrypted by Workspace Widget. They rely on the Windows account, file-system,
and device protections. Shortcut arguments and URLs are stored as plain text;
users must not put passwords, access tokens, private keys, or other secrets in
them.

## Network requests and third parties

Network requests occur only for features that the user configures or invokes:

- an optional health URL is polled every 30 seconds to show service
  availability;
- an HTTP or HTTPS shortcut opens in the user's selected browser;
- a remote HTTPS image or supported media source is requested from its
  configured host and can be stored in a managed local cache; and
- YouTube preview playback, when enabled, connects to YouTube's
  privacy-enhanced embed service through Microsoft Edge WebView2.

The device connects directly to the selected endpoint, browser destination,
media host, or YouTube/Google service. Those parties can receive ordinary
connection and request information, such as IP address, user agent, requested
URL, and time, and apply their own privacy policies. Workspace Widget does not
proxy these requests through a developer-operated server. WebView2 permission
requests are denied by the app, and downloads and pop-up windows are blocked.

Users control these connections by editing or removing the relevant health,
URL, or media setting, or by not enabling a YouTube preview.

## Local processes

The optional local-service feature starts only a Node.js project or script
selected by the user and runs it with the signed-in user's Windows permissions.
That project is separate software and can have its own network behavior and
privacy practices. Workspace Widget does not upload the project to the
developer and does not install project dependencies automatically.

## Sale, advertising, and developer sharing

The developer does not receive personal information through Workspace Widget,
sell personal information, use it for targeted advertising, or share it with a
developer-operated third party. A configured endpoint, browser destination,
media provider, or YouTube/Google receives request data only when the user
configures or invokes the corresponding feature, as described above.

## User controls, retention, and deletion

Users can inspect and back up the local data directory, edit or remove
registered entries, disable configured network features, and exit the app from
its tray menu. Removing an entry from Workspace Widget does not delete its
original file, folder, application, or project. Removing an entry also does not
automatically delete an already cached icon or media file.

State and recovery data persist until normal use overwrites them or the user
removes them. `runtime.log` stops growing at 4 MB. The managed `IconCache` and
`MediaCache` directories each enforce a 128 MB write budget and are not silently
cleared by the app. Exact update, uninstall, and reinstall retention will be
independently verified when a Store-signed package becomes available. This
policy will be updated before general availability if observed behavior differs.

To remove all Workspace Widget local data, the user must:

1. exit Workspace Widget from its tray menu;
2. back up the directory if the data may be needed later; and
3. delete `%LOCALAPPDATA%\WorkspaceServiceWidget` using Windows.

That separate deletion permanently removes the app's state, recovery data,
logs, managed caches, and WebView2 profile and cannot be undone. Review the
resolved path and its contents before deleting it.

## Product website

The public product website stores only language and theme preferences in the
browser's local storage. It does not use developer-operated analytics,
advertising, or advertising cookies. The site is hosted by GitHub Pages, so
GitHub can process ordinary connection information under the
[GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Children

Workspace Widget is a general productivity utility and is not directed to
children. It does not knowingly collect personal information from children.

## Changes and contact

Material policy changes update the date and are published with the
application's release information. Privacy questions that do not contain
sensitive information can use the public support routes at
<https://gabeujin.github.io/workspace-widget/support/>. Security
vulnerabilities, logs, or other sensitive details must be reported through
GitHub private security advisories:
<https://github.com/Gabeujin/workspace-widget/security/advisories/new>.
