# Workspace Widget screenshots

These screenshots use an isolated, neutral demo state. They do not contain the
maintainer's real shortcuts, internal service names, private repositories, or
user-state paths.

- Capture date: 2026-07-30
- Application version: 0.1.0 release candidate
- Native host: `WorkspaceWidget.exe`
- Bundled Node.js: 24.18.1
- Theme: Midnight

## Scenario set

| File | Scenario | Dimensions | SHA-256 |
| --- | --- | --- | --- |
| `workspace-widget-overview.png` | Full workspace with web links, local apps, a folder, and one healthy local service | 552 x 760 | `27D8A2BE837FB1E88A496466D2F85778FF555D0129D64B7B97878E6DFC1BBD22` |
| `workspace-widget-settings.jpg` | Settings for hover brightness, visibility, always-on-top, MIN UI, Windows startup, appearance, and desktop layer | 552 x 760 | `4112AD5A8D5D204171E405C8A359FC4761883CEA255C7B84A4FAEF5A9B138594` |
| `workspace-widget-add-service.jpg` | Adding a URL with port, health endpoint, and optional bundled-Node start target | 552 x 760 | `3BA7324D6C462DE9985281B926338F9D47A759881CBE79DD7C0FE033EFF22387` |
| `workspace-widget-context-menu.jpg` | Right-click organization controls and explicit shortcut removal action | 552 x 760 | `01289626DFAA6684F87F97C913B9E9CB6B22E5DE7B0C0386F9DD7852E13FD51A` |
| `workspace-widget-min-ui.png` | Opaque app-only render of the 96 px MIN UI rail | 96 x 760 | `6D0B0FC2B5ED6DDE6D750F6B3814C6551AB0C58798E94140FE437E8E452D00EF` |

## Public-safety review

- The product and repository URLs are already public.
- The local service uses loopback port 43999 and the neutral label
  `Sample Service`.
- The add-service example uses the generic demonstration path
  `C:\WorkspaceWidgetDemo\server.js`.
- The native full-mode and MIN UI images were rendered directly by the app.
- Interactive dialog and context-menu images were captured from the real
  Windows application window.
- Interactive captures retain a few opaque, non-identifying desktop pixels
  inside the rounded window corners; no transparent canvas is present.
- No screenshot contains authentication material, email addresses, private
  project names, workstation-specific repositories, or mutable real user state.

## Intended use

- GitHub README and product page: overview, settings, and MIN UI.
- Microsoft Store listing: overview, add-service, settings, and MIN UI placed on
  appropriately sized Store canvases.
- User guide: context menu and add-service dialog.

The files are product evidence, not certification evidence. Store canvas
exports should retain the original images and record their derived hashes.
