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

## Review
- userBurnActive counted background transfers -> fixed: BurnStore.loopActive (run lock held) now drives it.
- memberIds skipped cleanOnly -> fixed: MixResolverSources.cleanOnly/songsById, CleanOnly.ripIds applied; MixResolverTest case added.
- declaredMemberCount unwired -> fixed: ported in MixGraph and assigned.
- RipsMixRips.hasServer stale -> fixed: MixDownloadRips.prepare() refreshed before ripAndPoll reads it; test added.
- EngineAutoMixHost hooks unassigned -> acknowledged, PARTIAL: cross-package touchpoint. MIX-9/MIX-14 must assign insertHook/startHook/labelProvider/upcomingProvider and call noteAutoStarted; acceptance for late-arrival append / re-arm / zero-start is PARTIAL until then.
- NIT CatalogResolverSources rebuild per call -> not done (optional).

fixes applied
Tests: 1946, 0 failures (was 1944).
