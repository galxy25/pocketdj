state: merged

# ANS-PB-3 status

- [x] PlaybackSection (order 460) + PlaybackSectionModel, contributed via PlaybackGraph.settingsSections
- [x] Storage lists: BurnedArtists/BurnedCollections/BurnedStems pushed screens (StorageLists pure logic), Delete all burnt music with confirm
- [x] DeadAirReport + DeadAirSource.current assigned in PlaybackGraph.wire(); Debug panel refreshes every 1 s
- [x] AppleMusicEndMonitor: PollReconcile self-heal + NearEnd event; PlaybackController warms next row on NearEnd
- [x] build + tests green (full suite 5150 tests, 0 failures after reconcile fix; assembleDebug OK; new tests: PlaybackSectionTest, StorageListsTest, DeadAirReportTest, AppleMusicReconcileTest)

## Files touched outside owned list
- shell/ShellNavigation.kt: StorageScreen(onNavigate = { nav.navigate(it) }) (one line)
- playback/PlaybackController.kt: monitor trace hook + AmEvent.NearEnd -> warmNextAfterAppleMusic (additive)
- screens/settings/storage/StorageLists.kt (new, shared by the 3 screens)

## Deviations
- Self-heal only fires when the previous raw poll was also non-PLAYING (avoids misreading a fresh pause that lands between polls); epsilon 0.25 s like iOS.
- The AM near-end "prefetch" on Android warms the next row through the resolve ladder (no mixable-audio-session issue on Android).

## Questions for Levi
- none

## Review

fixes applied

- MAJOR AM self-heal not reaching the card -> fixed: monitor exposes `statusHealed` / `reconcileSnapshot()`; `BackendAppleMusicController.snapshot()` maps PAUSED->PLAYING while healed and pings the change listener on flip, so the adapter/MediaSession reads playWhenReady=true. Test: healedStatus_reachesTheAdapterModel_asPlayWhenReady.
- MAJOR noteSeek dropped lastPollSeconds reset -> fixed (noteSeek re-bases lastPollSeconds; resume-seek path goes through noteSeek). Test: scrubForwardWhilePaused_isNotHealed_andIntentionalPauseSurvives.
- MAJOR Delete-all semantics -> fixed: `StorageService.deleteAllBurns()` -> BurnStore.removeAllBurns() (stops in-flight, whole ledger, orphan stems); button/links enabled on ledger>0 || burn bytes || stem bytes; iOS-style copy. Tests: deleteAllEnabled_*, deleteAllBurns_routesToTheWholeStoreClear (BurnStore orphan-stem sweep already covered by removeAllBurnsSweepsOrphanStemsToo).
- MAJOR near-end prefetch no-op -> fixed: `PlaybackUrlResolver.prefetchNextRow` presigns the next network manifest row into the PresignCache the start path reads (burned/rip-on-demand/AM rows have nothing to warm on Android). Test: nearEndPrefetch_presignsOnlyANetworkManifestHit.
- MINOR polish-gated ShellNavigation edit -> fixed: reverted; Storage lists are now in-screen pages with BackHandler, nav-route entries removed from PlaybackGraph. PlaybackController edit (trace hook + NearEnd dispatch + warm body) remains: no hook exists without touching it; FLAG to integrator as a small additive polish-gate overlap.
- MINOR stale rows / titles / disabled links -> fixed: list reloads after each delete; pages render their own titles (no generic bar title since not routes); nav rows disabled when nothing downloaded.

Tests: 5150 -> 5155, 0 failures; assembleDebug OK.
