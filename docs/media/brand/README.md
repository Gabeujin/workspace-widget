# Workspace Widget Brand Assets

The canonical product mark is:

- `../../../assets/workspace-widget-logo.png` — 1024 × 1024 transparent PNG
- `../../../assets/workspace-widget.ico` — multi-frame Windows application icon

The mark uses the approved gray–white–blue palette on a dark navy tile. Public
derivatives in this directory are deterministic resizes or centered
compositions of that canonical PNG; they do not change the logo geometry.

## Public derivatives

| File | Dimensions | Intended use | SHA-256 |
| --- | --- | --- | --- |
| `workspace-widget-icon-64.png` | 64 × 64 | Browser favicon and compact navigation | `94FC546260A3C418E70422C6C81626524C9B63843BAC80CA5AAA8F40BB2277BA` |
| `workspace-widget-icon-256.png` | 256 × 256 | Product page and app catalog | `F0171E087CBDEE95F2183F87F8603EE66B183708B57A994F433D326D8CCA01DC` |
| `workspace-widget-store-icon-300.png` | 300 × 300 | Store listing icon source | `E7F87F3163439D9CF57724371E075FD8801DC718D6585CE33DCCE48A82346E77` |
| `workspace-widget-icon-512.png` | 512 × 512 | High-resolution web and documentation use | `D00B39080AA76C7D561AD6DEE36516B70F71F4D25D7946F1090088DDD4096468` |
| `workspace-widget-product-card.png` | 640 × 360 | `gabeujin.github.io` product card | `38D784D410941BE60F2E028253ABF2630F605CAC31E625EBB8D652436AD619C3` |
| `workspace-widget-social-preview.png` | 1280 × 640 | GitHub repository social preview | `2404296B0DB2EFC5CD1B2A2CDB3EB048B387C0648F055EB78D756BC14F1D2DB2` |

## Packaging assets

`scripts/Build-WorkspaceWidgetMsix.ps1` generates the MSIX package logos and
tiles from the canonical PNG. Those generated assets belong to the clean build
output and should not be copied back into source control.

The following package asset families are produced during an MSIX build:

- Store logo
- Square 44 × 44 logo
- Square 150 × 150 logo
- Wide 310 × 150 logo

## Draft handling

The ignored `assets/workspace-widget-logo-v2-*` and
`assets/workspace-widget-logo-v3-*` files are historical working drafts. They
are not canonical, are not packaged, and are intentionally excluded from the
public source tree. They remain on disk because permanent deletion requires
separate approval.
