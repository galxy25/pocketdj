state: merged

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

## Review
fixes applied

- MAJOR protected set missing resolveId -> fixed (`protectedIds(current, decks)` adds id + resolveId; tests: protectedIdsCover..., aPlayingCleanVariantBurnIsNotEvicted)
- MAJOR prune on caller dispatcher -> fixed (`io` context; begin() and each removeBurns chunk under withContext; test diskWorkNeverRunsOnTheCallingDispatcher)
- MAJOR Mix plays never reach PlayStatsStore -> fixed (MixRecordingHooks.onPlayStat + PlayStatsRecorder.attachMix wired in MixGraph; test mixDeckPlayUpdatesLastPlayedAtUnderTheBaseId)
- MAJOR ledger row Planned -> fixed (DONE, device-only + open points listed)
- MINOR skip re-derivation / appleCounted at collect time -> fixed (SkipTracker noteSkip sink feeds the store, recorder's isSkip removed; PlayStarted.appleCounted tagged at emit in AppleMusicBackend)
- MINOR PruneResult arithmetic -> fixed (EvictionPlan.sweptBytes + freedById; freed uses pre-sweep usage, spared songs keep full footprint, evicted = actually dropped from ledger)
- MINOR PruneWorkerGate dead code -> fixed (deleted with its test)
- MINOR prune only from periodic worker -> fixed (foreground hook, deferred 15 s, IO, self-gated; no 15 min tick)
- NIT Prune now messaging / unparseable cap -> fixed (distinct "already running" message; invalid GB refused, blank still clears)
- NIT recorder started from flushables getter -> fixed (started from AppGraph init on IO)

Suite 2787 green, 0 failures; assembleDebug OK.
