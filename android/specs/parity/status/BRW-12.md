state: merged

# BRW-12 For You UI: History ▸ For You tab, tiles grid, song list, feedback buttons, recs toggle, Settings ▸ For You

- [x] ForYouRoutes.kt (route codec + tab gate), RecFeedbackButtons.kt, CollectionRecsToggle.kt
- [x] ForYouTilesScreen.kt (grid, freshness bar, tile long-press menu, refresh policy, inputs factory)
- [x] ForYouSongListScreen.kt (+ ForYouSongListState pure logic)
- [x] ForYouSection.kt (Settings), registered in BrowseGraph.settingsSections (order 650)
- [x] HistoryScreen For You tab wired; ShellNavigation gets additive onOpenCollection
- [x] 25 new JVM tests (ForYouTileLayoutTest, ForYouSongListStateTest, ForYouRoutesTest, RecFeedbackActionsTest, ForYouSettingsCopyTest); full suite 4018, 0 failures; assembleDebug green

## Deviations / notes
- Tile list is hosted inside HistoryScreen (local state + BackHandler) instead of a NavHost `foryou/{tileId}` route, so MainActivity is untouched. ForYouRoutes still provides the codec for BRW-14/deep links.
- Files touched outside owned set: shell/ShellNavigation.kt (additive onOpenCollection lambda -> playlistRoute/pocketRoute).
- Tab gate: PrefKey "recEngineEnabled" (declared in ForYouRoutes.kt as ForYouGate; the Settings ▸ Recommendations package should reuse the same name) OR any debug build (fixture).
- Not wired (no Android service yet): release feed (New tile shows 0 / empty list, Play/Shuffle disabled; BRW-14 supplies ForYouReleaseSource), cloud zone ranker (cloudZone = null), audio-analysis scheduling after refresh.
- Menu Refresh is an icon button on the For You tab row (History has no tab overflow menu).
- Added BrowseGraph.timbreCatalog lazy.

## Questions for Levi
None.

## Review

fixes applied

- MAJOR refresh in screen scope -> fixed: ForYouInputsFactory.launchRefresh runs in AppGraph.appScope via ForYouSingleFlight (UI only triggers); test refreshOutlivesTheScreenScopeAndIsSingleFlight.
- MAJOR spinner never shown -> fixed: showSpinner(hasResult) only; grid hidden until first build; test uses real ForYouGrid.tiles on empty snapshot.
- MINOR stores spinner on every open -> fixed: BrowseGraph.forYouStoresReady, warm lazies resolve synchronously.
- MINOR open list lost on navigate/rotation -> fixed: HistoryScreen keeps encoded route in rememberSaveable (ForYouRoutes.decode with collection-name lookup).
- MINOR song list stuck empty without catalog -> fixed: loadForYouList returns null when inputs unavailable; data stays unset so the catalog-keyed effect rebuilds.
- MINOR ledger row -> fixed: PARTIAL in docs/ARCHITECTURE-ANDROID.md. Emulator steps NOT run (emulator owned by integrator); still to verify.
- MINOR replayed ON_RESUME double build -> fixed: isRealResume (only after ON_PAUSE) + single-flight; test replayedInitialResumeIsIgnored.
- NIT onOpenSong guard -> fixed (song != null). Per-row play control and New-tile copy left for BRW-14.

Tests: 4018 -> 4021, 0 failures; assembleDebug green.
