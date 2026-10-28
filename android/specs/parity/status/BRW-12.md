state: implemented

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
