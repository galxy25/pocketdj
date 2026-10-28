state: reviewed

# MIX-14 Mix screen shell: session header, Auto bars, crate menus, download bar, loader sheet, Settings > Mix, route

- [x] mix/MixSettings.kt: iOS-default keys (names = iOS fields), clamps, push-diff, combined flow
- [x] screens/mix: MixCrateMenu (skippable; entries remembered by collections revision), DownloadBar (only collector of downloader state), TrackLoaderSheet (+TrackLoaderFilter), SessionHeader (+Reset dialog), AutoMixBars (setup bar, banner, glide pills, SkipButton via pointerInput), MixScreen, MixViewModel (+MixAutoStarter, AutoMixPlan, SkipGesture), MixRoutes
- [x] screens/settings/sections/MixSection.kt (order 520), registered through MixGraph.settingsSections
- [x] di/MixGraph.kt: app-scoped `mixViewModel` + engine/download/crate adapters, navEntries, settingsSections
- [x] Tests: MixViewModelTest (17), CrateMenuStateTest (10 incl. DownloadBarModel), TrackLoaderFilterTest (6), MixSettingsTest (6)

## Tests
JVM suite 3167 tests, 0 failures (+39 new); assembleDebug green. Emulator not used.

## Touched outside owned files
- shell/ShellNavigation.kt: Mix tab placeholder replaced by `MixRoute(graph, onOpenSessions = ...)` (minimal).

## Notes / deviations
- MixViewModel is app-scoped (held by MixGraph) so crate picks survive tab switches and rotation; handleMixLeave runs on dispose except for configuration changes.
- Two-crate start logic lives in `MixAutoStarter` (public) so MIX-16's MixFacade can reuse it.
- Sessions route (`mix/sessions`) is registered as a minimal stub list; MIX-15 must replace the body (keep or replace the NavEntry id `mix/sessions` -- ids must stay unique).
- Record button / recording indicator are slots on MixScreen (`recordAction`, `recordingIndicator`) for MIX-12.
- Top-bar Auto/Manual is a FilterChip in an in-content row (Android has no per-screen toolbar host).
- Settings steppers are -/+ buttons; deck-layout and cue channel are chip rows.
- Deck waveform peaks use the whole-file window (lengthMs null) via MixWaveform.peaksForSong.
- Emulator verification pending (integrator): crate menu scroll while download bar ticks, skip single/double, Settings > Mix.

## Questions for Levi
- None.

## Review
Fixes applied.
- MAJOR autoEnabled desync -> fixed: AutoUiState.enabled published by AutoDj (setAutoEnabled now refreshes); MixViewModel mirrors it live (adoptEngineEnabled -> syncDeckSourcesToAuto) and re-reads engine.autoEnabled after materializePendingRestore. Tests: engineEnabledFlipOutsideTheScreen_isMirroredAndSyncsDecks, runAdoptsEngineEnabledAfterMaterializingARestore.
- MINOR crate menu orphan set lists / sort -> fixed: set lists need an existing playlist/pocket; Collator + numeric natural compare. Tests added in CrateMenuStateTest.
- MINOR ledger row -> fixed: MIX-14 row PARTIAL; emulator pass remains device-only/integrator.
- MINOR Sessions route ownership -> fixed: MixRoutes delegates to MixSessionsRoute(onBack) in MixSessionsScreen.kt (MIX-15 owns it; stub body there now).
- MINOR SkipButton a11y -> fixed: Role.Button, onClick action, custom "Fast skip" action.
- MINOR MixAutoStarter contracts -> fixed: MixSourceNotFoundException for missing crate (unnamed set list keeps "Set list"); optional pushSettings sink pushes settings before start. Tests added.
- NIT stepper -> partially fixed: section renders nothing until first DataStore emission (no default overwrite); rapid-tap atomic update not done.

JVM suite 3173 tests, 0 failures (+6); assembleDebug green.
