# Workspace Widget modernization — work in progress

Target: 0.2.0. This file is not a release-success receipt.

## Task graph

1. Native lifecycle contract: explicit stop action, bounded multi-endpoint checks,
   authenticated ownership, compatibility and isolated process tests. Native agent owns this path.
2. WPF experience: explicit registration type, health editor, unified bilingual settings,
   file pickers, header movement, monitor snapping and reduced-motion transitions. Main owns app integration.
3. Independent negative review: WPF helper tests and icon inventory. Reviewer may write only new tests.
4. Integration depends on 1–3: state migration, complete regression checks and actual native interaction.
5. Release depends on 4: source security review, package generation, local install/readback,
   GitHub release and Partner Center identity MSIX.

No concurrent writes to application state, service ports, source integration files or package outputs.
Current source includes earlier unpublished work; preserve it rather than resetting the checkout.

## Product DNA and design decisions

- Preserve the monochrome charcoal/white icon rail and restrained blue focus/accent.
- Keep the desktop launcher independent of AX Store and other server products.
- Explicitly separate a link from a managed local server; health is not proof of ownership.
- Use one settings window that does not inherit the narrow rail's width.
- Preserve spatial continuity with a short interruptible bounds transition; honor Windows animation settings.
- Snap only after dragging ends. Never pull the pointer back while crossing a display boundary.
- Korean labels describe the action and consequence; English remains available.
- Official reference: Toss, “인터랙션, 꼭 넣어야 해요?”, 2023-09-07,
  https://toss.tech/article/interaction (read 2026-09-15). Adapt reusable motion timing and
  action feedback; do not copy branding or decorative motion.

## Verification gates

Exactly three review lenses: architecture/security; native UX/accessibility/language/performance;
reproducibility/package/install. Missing evidence remains HOLD. A static or build pass is not a
native interaction, multi-monitor, clean-install or public release claim.

## Integration checkpoint — 2026-09-16

- Dependency candidate: Node.js 24.21.0 LTS and WebView2 SDK 1.0.4191.47,
  checksum-pinned with a dated official-source security receipt.
- Candidate 05 built successfully with the Roslyn compiler. Its V2 lifecycle
  fixture passed multi-health ownership, explicit stop, npm-root and PowerShell-root
  default stop helpers, force retry, degraded status and repeated start/stop.
- Direct-file and npm-package startup integration both passed with bundled Node
  24.21.0, HTTP 200, fixture-token match and confirmed process exit after stop.
- A real WPF regression reproduced native Height base mutation during animation.
  Retaining the intended bounds across reversal fixed it; 19 motion assertions
  passed. This is not mixed-DPI or physical multi-monitor interaction evidence.
- Eighteen semantic icons passed asset and runtime accessibility checks. Early
  localization calls now preserve English text before state initialization.
- CI now includes explicit V2 lifecycle, registration, language contrast,
  ComboBox, motion, stop feedback and upgrade-process predicate checks.
- The aggregate test is being updated for V5 fail-closed malformed-state behavior
  and an explicit built-runtime stage; it has not yet passed in full.
- The source-stage parity gate correctly refused candidate 05 after subsequent
  source/document changes. A fresh exact-source build remains required.
- Actual state migration, local upgrade, native end-to-end interaction, GitHub
  release, clean release verification and final Store-submission MSIX remain open.
  No installed-state migration or release success is asserted here.

## Installed upgrade checkpoint — 2026-09-16

- Candidate 08 passed development-stage verification and was installed at the
  versioned 0.2.0 location. Desktop and Start menu links were backed up and
  retargeted with readback verification. The previous installation remains intact.
- Actual state was atomically migrated to schema 5 after a byte-preserving backup.
  All 12 registrations and their ordering were retained; LocalDock was hidden
  as explicitly requested. Migration fixtures passed 28 assertions.
- The Windows startup task now points to 0.2.0 and remains disabled, preserving
  the user's existing choice. The installed host reported verified presentation.
- The previously owned deployment-lineage service was stopped gracefully through
  its old lifecycle contract, then restored through V2. The new owner reports
  all health endpoints online. No unrelated process tree was terminated.
- Final installed regression, complete registration checks, native interaction,
  clean-source release/CI, GitHub publication and Store MSIX remain open gates.

### Runtime and repeat-regression follow-up

- The installed aggregate verifier passed with the explicit versioned installation
  root. Its previous autostart failures were caused by the verifier assuming the
  default installation directory; the actual disabled task passed direct checks.
- All seven non-hidden local server registrations started under V2 ownership and
  reported every configured health endpoint online. One migrated server required one
  preserved-state correction: its removed legacy package script was replaced by
  the current `start` script. Unrelated registration fields matched exactly.
- All four ordinary shortcut executable targets exist. This is path validation,
  not proof that each external application's complete user journey was exercised.
- A repeated WPF motion fixture failed its final Height assertion under the
  current workload. Motion and final release remain HOLD until the failure is
  explained, corrected where needed, and repeat-tested.
- Native screen capture timed out twice; no stale-coordinate input was issued.
  Automated screenshot verification remains incomplete.

### Motion race resolution

- The failure was not only a fixed-wait test issue: a native Window could commit
  an intermediate Height after animation clock removal. A bounded timer settle
  phase now requires two consecutive exact target matches before saving state.
- Settling is capped at 16 attempts or one second. Timeout restores the target
  without persisting it; cancellation also restores mode-specific size limits.
  It does not depend on compositor rendering events being available.
- Five isolated Windows PowerShell STA repeats and one independent integration
  rerun each passed all 35 assertions, including injected Height corruption,
  reversal, post-completion stability, localization and reduced-motion cleanup.
- Current packaged docs now match the 18-icon, V5, multi-health, separate
  Start/Stop and PowerShell-capable implementation. CI discovers modern Visual
  Studio through vswhere/VS 18 and rejects non-deterministic stages.
- Latest official checkout action 7.0.1 is pinned by immutable commit. Public
  source and network-boundary regressions passed. Final native interaction,
  clean-source packaging, remote CI and publication remain separate gates.

### User-recorded motion regression — release hold

- A user recording supersedes the earlier final-bounds-only evidence: full and
  MIN modes retained different opacity values, and full-size card shells were
  visibly clipped inside the narrow rail during mode changes.
- Source inspection found destination constraints and native bounds were applied
  before the animation started. Intermediate layout and shared-opacity behavior
  were absent from the earlier fixture's assertions.
- Repair scope is shared resting opacity with preservation of the active legacy
  setting, explicit destination bounds, staged content, and cancellation/reversal
  without stale callbacks. First/intermediate frames require separate assertions.
- The previous remote CI also failed the authenticated startup probe after its
  static and motion checks passed. This is a separate unresolved release gate;
  no final public release or Store-submission package is asserted.

### Motion correction and installed readback

- Removed the destination-first resize and the end-of-animation rewind. Bounds
  use explicit targets with HoldEnd until a bounded commit; superseding a
  transition starts at the current presentation without its stale callback.
- Full/MIN opacity now shares one value. First migration preserves the active
  legacy profile, and both retained fields are saved identically thereafter.
- The integration fixture passes 47 assertions, including first-frame geometry,
  staged card/chrome visibility, reversal, deadline persistence and reduced motion.
  A second real-WPF fixture samples effective width/height every 10 ms in both
  directions, rejects reverse movement over 2 px, and tests opacity migration.
  Sample-dependent assertion totals vary by dispatcher scheduling.
- A fresh candidate passed all 19 development-stage release checks, then its
  complete manifest was verified at the new installation location. All 12
  registrations, the disabled startup preference and existing supervisors were
  retained; old installation files were not removed.
- Installed UI buttons completed full-to-MIN-to-full transitions with 96/430 px
  settled widths. The MIN Settings dialog and restored full state both retained
  the original 57% opacity. The settings dialog was closed after verification.
- This proves functional transitions and isolated monotonic bounds, not a measured
  display refresh rate or a post-fix video capture. The remote startup-probe CI
  failure and final public release/Store package remain separate open gates.

### Appearance settings integration regression

- A user screenshot identified a missed requirement: the appearance button still
  opened an older independent English-only window. Dictionary entries and a
  generic locale round trip did not prove that this actual editor was localized.
- Move the editor into the singleton Settings window, with stable preset IDs
  separate from localized display names. Appearance fields remain a draft until
  Apply; invalid input and persistence failure must preserve the previous state.
- Add production-WPF editor tests for Korean/English round trips, preset IDs,
  input preservation, validation, apply/cancel, persistence rollback and layout.
  Installed visual verification and final release gates are recorded separately.
- The new fixture passed 63 assertions, including an owned selected-tab template
  to avoid Windows light-theme overrides. The 47-assertion motion integration,
  shared-opacity fixture and installed-product aggregate also passed.
- Candidate 11 passed 19 development-stage checks and was copied into a fresh
  installation with manifest hash readback. All 12 registrations, six existing
  supervisors, MIN mode, 50% opacity and disabled startup preference were retained.
- Native observation verified the Korean General page and readable dark tabs.
  The automation surface could not target an owned Settings window beyond the
  96-pixel parent rail. The user selected the Appearance tab; a fresh native
  screenshot and accessibility tree then verified the integrated Korean editor,
  localized preset, help, color labels and file-picker action. Apply/cancel and
  locale round trips are covered by the isolated WPF fixture, not claimed as
  user-desktop interaction. The user then closed the owned dialog.
- A final correction synchronizes the selector to Custom after editing preset
  colors. Candidate 12 passed the development-stage gate and replaced the UI in
  another fresh directory with the same preservation checks. A bounded independent
  source review found no P1/P2 defect in the new editor/integration; physical file
  picker interaction and real media-decoder failures remain outside this fixture.
