# UI polish pass (feat/android-ui-polish)

Source review: 2026-10-28 capture (71 shots, android-shots/INDEX.md). Re-capture: android-shots-v2/.

## Theme decision
iOS pins `.preferredColorScheme(.dark)` at the app root (PocketDJApp.swift), so Android is
**dark-only** too: the system bars always use light icons (`SystemBarStyle.dark`), whatever the
system light/dark setting is.

## Done
- [1] Status/nav bar: `enableEdgeToEdge(SystemBarStyle.dark(transparent))` → light icons in system light mode.
- [2] Onboarding: root `LocalContentColor = onBackground` (wordmark/footer no longer black); outline token brightened (0x283250 → 0x3A4872) so outlined buttons are visible.
- [9] Off-palette greys: every M3 surfaceContainer*/container token mapped to the navy ramp (cards, dialogs, sheets, menus).
- [3] Piano: white keys light / black keys dark (iOS: Theme.fg / Theme.bgOverlay).

## Remaining

## Skipped (with reason)
