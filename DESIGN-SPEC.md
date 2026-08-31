# Workspace Widget Design Spec

## Visual target

- Runtime: native Windows PowerShell 5.1 WPF
- Default bounds: `552 × 640`
- Minimum bounds: `430 × 500`
- Default position: a visible location on the primary monitor; **Reset size**
  places the widget near the right work-area edge
- Layout: responsive three-column wrap grid with hidden scrollbars
- MIN UI: fixed `96 px` edge rail with a compact wrapped toolbar and one-column
  icon-only launcher cards
- Surface: dark navy acrylic-like panel with subtle blue borders

## Information hierarchy

1. Responsive product identity, aggregate health, and compact toolbar.
2. Optional opacity or settings panel.
3. Launcher-card grid with verified custom icons, original semantic icons, real
   shell icons, or Fluent fallback icons.
4. Add/drop affordance.
5. Refresh action, feedback toast, timestamp, and resize handle.

## Design tokens

| Token | Value |
| --- | --- |
| Panel | `#EE09162B` |
| Card | `#E80F203B` |
| Card hover | `#F2162F56` |
| Primary text | `#FFF6F9FF` |
| Secondary text | `#FFA9B9D1` |
| Border | `#665C8AC6` |
| Accent | `#FF3E8BFF` |
| Online | `#FF35DE8F` |
| Offline | `#FFFF697D` |
| Outer radius | `18` |
| Card radius | `14` |
| Font | `Segoe UI Variable Text`, fallback `Segoe UI` |
| Icon font | `Segoe Fluent Icons` |

## Semantic icon DNA

- Built-in icons are product-local meanings, not substitutes for third-party app
  identities: Launch, Service, People, Workspace, Web, Data, Automation, and Lab.
- SVG masters use a `24 × 24` grid, 2-unit safe inset, transparent background,
  `currentColor`, and a 1.75-unit round-cap/round-join stroke.
- WPF cards use committed `256 × 256` transparent PNG renders as alpha masks,
  recolored from the active text token (or the Windows high-contrast text
  brush), then scaled to 34 px in MIN UI and 44 px in the standard grid.
- Custom media remains highest priority. Semantic presets are followed by shell
  resolution and the existing Fluent fallback, so older entries do not change.
- Health is an independent overlay and accessible text state. Online, offline,
  checking, and attention colors are never embedded in the semantic artwork.
- A category with no truthful semantic match keeps Automatic; decorative or
  brand-derived icon invention is not permitted.

## Product icon

- Palette: charcoal gray, soft white/silver, and cobalt blue.
- Background: transparent.
- Release formats: 1024px PNG and 32-bit ICO frames at 16, 20, 24, 32, 40,
  48, 64, 96, 128, and 256px.
- The shortcut-arrow and cloud-sync overlays are Windows shell affordances, not
  part of the product icon.

## Interaction

- The entire card is a pointer and keyboard hit target.
- `Enter` and `Space` open the focused card.
- Hover raises card contrast and border brightness.
- A URL with an explicit port displays `Port ####`.
- A health dot is supplemented by aggregate online text and a tooltip.
- When an offline card has a Node start target, click starts the server, waits
  for health, then opens the configured URL.
- Right-click offers start/open when applicable, edit, move, visibility, and
  confirmed removal from Workspace without deleting the original target.
- Menu templates deliberately omit the default icon gutter.
- Drag movement, bottom-right resize, wheel paging, base opacity, and hover
  brightness persist.
- Opening the opacity editor previews the selected base opacity immediately;
  hover brightness resumes after the editor closes.
- The header close button and `Alt+F4` hide the window to the notification
  area. Tray double-click or **Open Workspace** restores it; tray **Exit**
  performs the explicit process shutdown.
- Settings → **Always on top** applies Windows' native topmost behavior
  immediately and persists the choice across restarts.
- At widths below `500 px`, the header replaces the text title with the
  `24 px` product icon so the toolbar never clips the identity. The title
  returns at `500 px`; aggregate health returns at `680 px`.
- Settings → **Start with Windows** uses a real Task Scheduler state machine:
  `Enabled`, `Disabled`, `Missing`, `Drifted`, or `PermissionDenied`. The
  checkbox updates only after the OS operation succeeds. Turning it off
  disables the task without deleting it, while drifted definitions are blocked
  for installer repair instead of being overwritten.
- The header mode control and Settings → **MIN UI mode** collapse the widget to
  a `96 px` rail. Entering MIN UI snaps to the nearest work-area edge, preserves
  the full layout bounds, uses a separate `35%` resting opacity, and restores
  the saved full layout when expanded.
- MIN UI cards retain the same click, keyboard, health, tooltip, and context
  menu behavior while hiding title and subtitle text.

## Motion

- Startup logo: 360ms fade in, 520ms hold, 320ms fade out.
- Widget entry: 260ms fade in.
- Wheel motion: time-based smootherstep interpolation on WPF's
  `CompositionTarget.Rendering`, synchronized to the monitor's render cadence
  (including 90Hz and higher displays).
- Motion is functional and brief; no decorative looping animation is used.

## Accessibility

- Primary text and controls maintain strong contrast on the navy surface.
- Button hover, pressed, keyboard-focus, and disabled states use explicit dark
  surfaces and white text instead of Windows' low-contrast default styling.
- Status is not color-only: aggregate count and tooltips provide text.
- Health-enabled cards expose Checking, Online, Offline, or Unavailable in their
  automation name, help text, and polite live-region update, including MIN UI.
- The compact header icon exposes the Workspace Widget name and health summary
  to UI Automation even when the visible title is hidden.
- Cards are focusable and support `Enter` / `Space`.
- Tooltips expose name, target, and offline Node behavior.
- The custom context menu keeps clear spacing without the default icon gutter.
