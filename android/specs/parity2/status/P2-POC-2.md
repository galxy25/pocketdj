state: reviewed

# P2-POC-2 Play attribution phase 0

- [x] ShellActions.playSongIds(originId) -> playNow; AppAutoServices SOURCE passes ref.id (other callers audited: For You, Rewind, listening-pocket detail have no collection id, as iOS)
- [x] AutoMixItem.originCollectionId per row (MixSource.collectionId; AutoMixPlan; CollectionMixDownloader; AutoDj snapshot/restore; AutoRow persisted)
- [x] MixPlayOutcomeBridge originOf -> PlayStarted.originCollectionId; PlayHistoryStore stamps origin for Mix plays too
- [x] CollectionsStore.historyContext/originCollection resolve pl_ and fav_songs
- [x] ListeningPocketsCollections.context rules + rawContextId; service wire uses it
- [x] PlayAttributionTest

## Files touched outside owned list (minimal, additive)
MixViewModel.kt (AutoMixPlan origin params), AutoDj.kt (originCollectionIdFor, snapshot), MixDeckSessionStore.kt (AutoRow field), PlayHistoryStore.kt (origin gate now also SOURCE_MIX), MixGraph.kt (originOf wiring, shared touchpoint).

## Notes
- PlayEvent.pocketRun does not exist yet (P2-POC-1): wire event passes null for rowCollectionId via rawContextId; POC-1 should pass e.pocketRun?.rowCollectionId at ListeningPocketsService.wireEvent.
- Repeat-one rebuilt-from-deck item has no origin (same as iOS rebuilt item).

## Questions for Levi
None.

## Result
Tests: 5791 total, 0 failed (was 5790 before; PlayAttributionTest adds 11). testDebugUnitTest + assembleDebug green. assembleRelease not run: no manifest/gradle/proguard/library change.
Build note: the machine sat at ~6 GB free for hours, so one-at-a-time's 8 GB gate never opened; the final build ran with FIN_MIN_FREE_GB=5 (the wrapper's documented knob, still serialized).

## Review
- AppAutoServices SOURCE originId collision (MINOR) -> rejected: catalog playlist ids are resolved by id alone app-wide (CollectionsStore, iOS identical); documented in a code comment.
- ListeningPocketsService.wireEvent null rowCollection (MINOR) -> fixed: explicit TODO(P2-POC-1) at the call site; integration test awaits PlayEvent.pocketRun.
- AutoDj originCollectionIdIn tie (NIT) -> fixed: ties break backward; test originLookupTieGoesToTheRowOnAirNotTheNextCopy added.
Tests: 5792 total, 0 failed (was 5791). assembleDebug green.

fixes applied
