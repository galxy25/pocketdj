state: in-progress

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
