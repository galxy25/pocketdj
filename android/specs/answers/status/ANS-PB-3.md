state: implemented

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
