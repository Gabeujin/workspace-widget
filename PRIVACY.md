# Workspace Widget Privacy Policy

Last updated: 2026-07-30

Published copy:
<https://gabeujin.github.io/workspace-widget/privacy/>

Workspace Widget is a local-first Windows desktop launcher. The application
does not include developer-operated analytics, advertising, telemetry,
accounts, or a remote data-collection service.

## Data stored on the device

Workspace Widget stores the user's layout, appearance settings, registered
shortcut targets, optional launch arguments, optional health URLs, optional
local-service startup configuration, and media selections under the signed-in
user's local application-data directory. These values stay on the device
unless the user backs up, synchronizes, or shares that directory through
another product.

Shortcut arguments and URLs are plain-text local configuration. Users should
not put passwords, access tokens, private keys, or other secrets in them.

## Network requests

Workspace Widget makes network requests only for features the user configures
or invokes:

- an optional health URL is polled to show service availability;
- an HTTP or HTTPS shortcut opens in the user's selected browser;
- remote image or media sources are requested from their configured hosts; and
- YouTube preview playback, when enabled, connects to YouTube's
  privacy-enhanced embed service through Microsoft Edge WebView2.

Those services receive ordinary connection information such as the user's IP
address and request metadata and apply their own privacy policies. Workspace
Widget does not proxy those requests through a developer-operated server.

## Local processes

The optional local-service feature starts only a project or script selected by
the user. It runs with the signed-in user's permissions. Workspace Widget does
not upload the project to the developer and does not install project
dependencies automatically.

## Retention and deletion

The Store release is designed to keep per-user state outside the managed
application package so a later reinstall can restore the user's layout. Exact
update, uninstall, and reinstall behavior will be independently verified on the
Store-signed package before certification. Deleting the state directory
separately permanently removes Workspace Widget's local configuration. The
exact directory and deletion scope should be reviewed before that separate
destructive action.

## Children

Workspace Widget is a general productivity utility and is not directed to
children. It does not knowingly collect personal information from children.

## Changes and contact

Material policy changes will update the date and be published with the
application's release information. Privacy questions that do not contain
sensitive information can use the public support routes at
<https://gabeujin.github.io/workspace-widget/support/>. Security
vulnerabilities, logs, or other sensitive details must be reported through
GitHub private security advisories:
<https://github.com/Gabeujin/workspace-widget/security/advisories/new>.
