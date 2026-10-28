state: implemented

COL-2 Store batch choke points + shared VersionedJsonWriter.
- [x] data/store/VersionedJsonWriter.kt (version-ordered, executor-based, flushNow, invalidate(through), delete)
- [x] CollectionsStore: save() via writer, flushNow(), addSongs(ids,target,BatchDedupe), removeSongsFromPocket/Playlist, onActivityBatch
- [x] CollectionActivityStore: writer, recordAll, flushNow, clear via ordered delete
- [x] CollectionsGraph: flushables (ON_STOP) ; AppGraph wiring (background executor, onActivityBatch -> recordAll)
- [x] Tests: VersionedJsonWriterTest (5), CollectionsBatchTest (10); suite 640, 0 failures; assembleDebug green

Deviations:
- Test class named VersionedJsonWriterTest (roadmap's CollectionsDocumentWriterTest names: versionOrderDropsStale, flushNowBeatsStraggler, deleteIsVersionOrdered all present there).
- Default writer executor is DIRECT (synchronous) so existing tests stay deterministic; AppGraph passes the background executor in production.
- Touched outside owned files (minimal): di/AppGraph.kt (executor + onActivityBatch wiring). Write-back resolution / membershipRevision not in scope (no write-back seam exists yet).
- Emulator steps (500-song background flush, jank) not run.
