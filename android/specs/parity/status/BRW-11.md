state: implemented

# BRW-11 For You feed store, feedback store, refresh schedule, tiles/grid, collection recs

- [x] ForYouRefreshSchedule.kt: cadence enum, lastFire/nextFire/isDue (java.time, injectable zone; 1 = Sunday weekday numbering)
- [x] ForYouSettings.kt: PrefKeys forYouRefreshCadence/Minutes/Weekday + normalize/load/save
- [x] ForYouTiles.kt / ForYouGrid.kt: tile derivation; ForYouCollections + ForYouReleaseSource seams
- [x] RecFeedbackStore.kt: decisions doc (iOS wire shape), read-time tombstones, partition/rankedIds/visibleCount, PlayingScope, cloud merge
- [x] ForYouFeed.kt / ForYouFeedStore.kt: snapshot (v3, lenient), builder, applyingCloudZone, audioShortlist, durable store
- [x] CollectionsRecs.kt: extension helpers on CollectionsStore (+ memoized recMembership)
- [x] BrowseGraph: forYouFeedStore, recFeedbackStore lazies
- [x] Tests: ForYouFeedTest, ForYouGridTest, ForYouRefreshScheduleTest, ForYouTilesTest, RecFeedbackStoreTest, CollectionsRecsTest

## Notes / deviations
- Only owned files touched. CollectionsStore.kt is untouched: the iOS helpers are Kotlin extensions in CollectionsRecs.kt (recMembership memo keyed on state.revision, WeakHashMap).
- ForYouGrid.tiles takes `ForYouCollections` (adapter `CollectionsStore.asForYouCollections()`) and `ForYouReleaseSource?` (BRW-14 implements) instead of the concrete stores, so it is JVM-testable.
- Tile tint is a `Long` 0xRRGGBB and `symbol` the iOS SF symbol name; the REC-5 renderer maps both.
- RecFeedbackStore install id lives in a device-local file (`pocketdj-rec-feedback-install-id`) instead of UserDefaults; same semantics (a pulled document cannot move it; playing scope adopted only from our own document).
- RecFeedbackWire / `recFeedbackEvents` (telemetry upload wire) not ported: no Android wire type exists yet; `decisionsSince` is the seam.
- ForYouFeedStore.refresh takes the cloud zone as `suspend () -> List<ForYouCloudZoneRow>`; the caller (REC-5) wires the Lambda.
- Test file names: roadmap lists ForYouFeedStoreTest; the content lives in ForYouFeedTest (matches the unit_tests list), plus ForYouTilesTest.

## Questions for Levi
None.

## Result
79 new JVM tests (ForYouFeed 23, ForYouGrid 10, ForYouRefreshSchedule 12, ForYouTiles 6, RecFeedbackStore 21, CollectionsRecs 7). Full suite 3760 tests, 0 failures; assembleDebug green. Emulator: n/a (REC-5 renders).
