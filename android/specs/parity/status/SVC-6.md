state: implemented

# SVC-6 PlayStatsStore + StorageManager prune + StoragePruneWorker + Storage screen sections

- [x] PlayStatsStore (iOS Document shape, 30 s recount, appleCount/preTag migration, revision, reload/clear, peer seam) + PlayStatsRecorder (PlayEventBus starts + advance-away skips)
- [x] StorageSettings (caps 0 = unset, lastStoragePruneAt) + StorageManager (20 h gate, stamp FIRST, LRP via baseId, chunk 25 + yield, protected re-read per chunk)
- [x] BurnStore.planEvictionSweepingOrphans (additive): ONE roots()/listing per prune, orphan aux swept from the same snapshot
- [x] data/transfers/StoragePruneWorker (WorkScheduler's worker subclasses it; WorkSeams.storagePrune now runs pruneIfDue)
- [x] StorageService burn ops (by-artist usage, delete burns/stems by song ids) + StorageScreen: cap fields, Save cap, Prune now + status line, delete by artist / collection / stems by artist
- [x] Tests: PlayStatsStoreTest(10), StorageManagerPlanTest(9), PruneWorkerGateTest(3), StorageServiceBurnOpsTest(2). Suite 2783 green (was 2759).

## Files touched outside owned list (minimal, additive)
- data/burns/BurnStore.kt: planEvictionSweepingOrphans
- work/WorkScheduler.kt: StoragePruneWorker delegates to data.transfers one; storagePrune seam body
- di/AppGraph.kt: one line `burnOps = servicesGraph.burnStorageOps` in storageService

## Notes / deviations
- Final PruneResult usage is arithmetic from the single plan (no end rescan), per the ONE-listing acceptance.
- No tvOS-style auto-manage toggle on Android (cap unset = never delete).
- PlayStatsRecorder is started from ServicesGraph.flushables materialization (appScope IO). Apple-stream tagging uses playbackController.isAppleMusicActive at event time.
- Protected set = current sequencer song + both Mix deck songs (touches mixGraph.mixEngine lazily, inside runCatching).
- Not wired: cloud-sync registration of pocketdj-play-stats.json (belongs to profile sync package).

## Questions for Levi
- None blocking. Delete-by-collection covers pockets + playlists (not setlists).
