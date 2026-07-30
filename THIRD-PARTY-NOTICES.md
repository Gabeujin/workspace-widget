# Third-party notices

Workspace Widget is built for Microsoft Windows and uses operating-system
components that are already present on supported Windows installations,
including Windows Presentation Foundation and Windows PowerShell 5.1.

## Inno Setup

The legacy development/migration installer is produced with Inno Setup. Inno
Setup is not included as a source dependency in this repository, but its
runtime is embedded in a generated setup executable. That executable is not the
supported Microsoft Store public distribution.

- Project: https://jrsoftware.org/isinfo.php
- License: https://jrsoftware.org/files/is/license.txt
- Copyright: Jordan Russell and Martijn Laan

## Microsoft Edge WebView2

Optional YouTube previews use Microsoft Edge WebView2 when the Evergreen
WebView2 Runtime is installed. The release package may include the managed
WebView2 SDK assemblies and native loader from the `Microsoft.Web.WebView2`
NuGet package.

- Project: https://developer.microsoft.com/microsoft-edge/webview2/
- Package: https://www.nuget.org/packages/Microsoft.Web.WebView2
- License: https://licenses.nuget.org/BSD-3-Clause

The Evergreen WebView2 Runtime itself is supplied and serviced by Microsoft.
Workspace Widget does not download or silently install it.

## Node.js

The application package includes the official Node.js 24.18.0 LTS Windows x64
binary distribution so an explicitly configured local JavaScript service can
start without a separate machine-wide Node.js installation. npm is included
as part of that official distribution. Workspace Widget does not automatically
install project packages.

- Project: https://nodejs.org/
- Distribution:
  https://nodejs.org/download/release/v24.18.0/node-v24.18.0-win-x64.zip
- SHA-256:
  `0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821`
- License: `runtime\node\LICENSE` in the installed package

Node.js includes software under additional compatible licenses. The complete
official distribution and its license files are retained in
`runtime\node`.

## User-provided media

Workspace Widget does not ship third-party logos, character artwork, game
footage, advertising assets, or YouTube videos. Users and distributors are
responsible for ensuring that media they configure can legally be displayed,
streamed, or redistributed.
