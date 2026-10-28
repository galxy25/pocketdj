state: merged

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

## Review
fixes applied (suite 640 -> 648, 0 failures, assembleDebug green)
- MAJOR ON_STOP never wired -> fixed: shell/FlushOnStop (blocking runBlocking(IO) registry.flushAll) registered on ProcessLifecycleOwner in MainActivity; FlushOnStopTest drives ON_STOP -> CollectionsStore.flushNow with queued backlog.
- MAJOR activity flushNow skipped salvage -> fixed: flushNow is a no-op unless dirty, and salvages before writing (both stores); tests: untouched no-op, unreadable-launch keeps disk then unions on first edit.
- MINOR CollectionsStore.clear() direct delete -> fixed: writer.delete(++saveVersion); test with queued backlog.
- MINOR stale sequenceId -> fixed (takeIf >= 0 fallback to chapter 0); tests for stale id and self-heal + sequenceId.
- MINOR AppGraph edits -> rejected as code change (the collections/collectionActivity lazies and the single bgWriterExecutor already live in AppGraph, one instance); RECORDED as a declared shared touchpoint: AppGraph.kt (bgWriterExecutor, onActivityBatch wiring) -- plan merge order with MIX-1/PB-4/STU-1.
- MINOR nested prune test / write count / order -> fixed: nested SEQUENCE test, writeCount +1, hooks emitted in caller order.
- MINOR status overstated -> fixed here: NOT fully done. Unmet: "ONE write-back resolution" and membershipRevision (no write-back seam exists), ARCHITECTURE-ANDROID.md ledger row not updated (flag for docs owner), emulator steps (500-song background flush) not run. Baseline test count was 640 (pre-review).
- NIT zero-add heal persists healed Default chapter: kept intentionally (self-heal must persist). Nested dedupe and per-hook collection name: left as is.
