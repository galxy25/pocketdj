state: implemented

# MIX-7 MixResolver + CollectionMixDownloader + AutoMixHost
- [x] MixResolver (+ MixResolverSources seam, memberIds)
- [x] AutoMixHost interface (+ AutoPlacement)
- [x] CollectionMixDownloader (seams MixDownloadBurns / MixDownloadRips; StateFlow MixDownloadState)
- [x] MixGraph wiring: mixResolver, autoMixHost (EngineAutoMixHost), collectionMixDownloader + adapters (CatalogResolverSources, BurnStoreMixBurns, RipsMixRips)
- [x] Tests: MixResolverTest (6) + CollectionMixDownloaderTest (32) = 38 new. Full suite 1944 tests, 0 failures; assembleDebug green.

## Deviations / notes
- Adapters live in MixGraph.kt (owned file); no files touched outside the owned list.
- EngineAutoMixHost: engine facts (autoMixing, autoEndedExhausted, isRunning, deckGestureGeneration, streaming) are live; the Auto-DJ queue ops (startAutoMix, autoQueueInsert, autoSourceLabel, autoUpcomingSongIds) are hook vars (insertHook/startHook/labelProvider/upcomingProvider) the Auto-DJ package must assign. Until then the downloader fetches + reports progress but never appends to a mix.
- Improvement over iOS: each run has a runId so a cancelled run's tail cannot clobber the next run; a background burn still DOWNLOADING/QUEUED after burn() returns is not counted as a miss (iOS logged it as one).
- Studio/profile branches are N/A (no such sources on Android).
- Emulator step (bottom bar text, logcat "mixdl begin") is UI-2's; JVM-verified only here.

## Questions for Levi
- none
