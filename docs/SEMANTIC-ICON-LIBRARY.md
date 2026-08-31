# Workspace Widget Semantic Icon Library

Workspace Widget Semantic Essentials is an original, product-local icon set for
the Widget's built-in shortcut categories. It preserves the Widget's midnight
surface, soft white line, rounded card, and independent health-dot DNA without
recreating third-party product marks.

## Use

Choose a built-in icon in the Add or Edit shortcut dialog. The resolution order
is deliberately lossless:

1. a verified custom icon;
2. a selected built-in semantic icon;
3. the Windows shell icon for the target;
4. the existing Fluent fallback glyph.

Removing a custom icon reveals the selected built-in icon again. Older state
files remain valid because `iconPreset` is an optional additive field.

## Taxonomy

| ID | Intended meaning | Do not use it to mean |
| --- | --- | --- |
| `launch` | Open an app, file, folder, or URL | Running or healthy |
| `service` | Local or remote service | Upload or download |
| `people` | Users, access, collaboration | Notification count |
| `workspace` | Project or grouped work area | Generic app identity |
| `web` | Web destination | Network health |
| `data` | Data, reporting, analytics | Settings |
| `automation` | Automated or agent workflow | A third-party AI brand |
| `lab` | Experiment or non-production tool | Error or danger |

## Design contract

- 24 by 24 SVG grid with a 2-unit safe inset.
- Transparent background, `currentColor`, no gradient, shadow, bitmap, font, or
  external URL.
- 1.75-unit round-cap and round-join strokes.
- Committed 256 by 256 transparent PNGs provide an alpha mask. WPF recolors that
  mask from the active text token, or the Windows control-text brush in high
  contrast, at 34 and 44 device-independent pixels.
- Health status remains a separate host overlay with text and tooltip support;
  status color is never baked into an icon. Health-enabled cards also announce
  the state through UI Automation, including the compact MIN UI rail.

## Provenance and license

Original work: These Workspace Widget semantic icons were independently
authored for this release. No third-party logo, icon path, bitmap, or
trademark-derived artwork is included. App identities remain user-provided or
system-resolved assets and are not relicensed by this set.

The set is distributed under the repository's MIT license.

## Verification

```powershell
pwsh -NoProfile -File .\scripts\Test-WorkspaceWidgetSemanticIcons.ps1
```

The gate fails closed on missing provenance, duplicate IDs, unsafe SVG content,
wrong geometry, opaque PNG output, or state colors embedded in the artwork.
