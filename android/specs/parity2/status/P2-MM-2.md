state: merged

# P2-MM-2 Mix Mode ph1b: expiry sweep, soft-cap eviction order, triggers, SAF picked-folder identity

- [x] TemporarySweep.kt: pure planSweep, soft-cap temp-first order, picked-folder identity, afterRemoval, SweepTicker
- [x] StorageManager.sweepTemporary(now, reason, ignoreExpiry, capOverrideBytes) (stamp first, one ledger scan, chunks of 25 + yield, protected re-read + hold re-validated per chunk, single-flight with prune), sweepTemporaryIfDue, scheduleCapSweepIfNeeded, sweepForDiskGuard
- [x] Soft-cap prune: unprotected temporary holds (soonest expiry) first, then LRP pinned; temp songs go through removeTemporaryAssets (hold-scoped), others removeBurns
- [x] BurnStore.removeTemporaryAssets: deletes only what the hold lists; never analog cuts / pinned stems; picked-folder files deleted only if unchanged (+-2 s mtime) and folder unchanged, else released; unreachable folder keeps the hold; mirror copy deleted too
- [x] Triggers: launch (first foreground, +3 s), every foreground (5 min gate), hourly tick while foreground (SweepTicker, stopped on ON_STOP), StoragePruneWorker (ungated by soft cap, 1 h gate), cap sweep when a hold lands (BurnStore.onTemporaryHoldsChanged), disk guard entry point sweepForDiskGuard (MM-5 binds it), Mix Mode off -> scheduleCapSweepIfNeeded (MM-4 binds it)
- [x] ServicesGraph.sweepProtectedIds: current(base+resolve) + NP window (current+npMixBufferAhead, held restored session included) + decks + Auto upcoming + live streams / stem sets
- [x] Tests (TemporarySweepTest, 25) ; :app:testDebugUnitTest :app:assembleDebug green (5929 tests, 0 failed)

## Summary
Tests: 25 new in TemporarySweepTest (plan, identity, stamp-first, chunking + per-chunk re-read, pinned/extended mid-sweep, single-flight, cap override, due gate, log line, prune order, ticker, real-store file deletion, SAF identity/switch/keep-switch).

## Notes / deviations
- Touched outside owned files (minimal): BurnStore.kt (removeTemporaryAssets + userFolderPath now = SAF treeUri when set, else dir path, so a tree switch is detected; the staging dir path never changed on a switch), TemporaryHolds.kt (+replace), AppLifecycleObserver.kt (+onBackground hooks), PocketDjApplication.kt (triggers), ServicesGraph.kt (protected set, cap-sweep hook, log tag `PocketDJ.storage`), StorageSettings.kt (+3 defaulted port members).
- Log tag changed from PocketDJ "[storage] ..." to tag `PocketDJ.storage` (emulator step greps it).
- SAF identity is the local staging file's mtime (SAF tree has no File); the tree mirror copy is deleted with it. ContentResolverBurnTree / BurnFolder unchanged (no tree-side mtime read needed).
- Not wired (owned by later packages): Mix Mode off call site (MM-4) and DiskGuard (MM-5) call StorageManager.scheduleCapSweepIfNeeded / sweepForDiskGuard.
- assembleRelease not run: no manifest/gradle/proguard/library change.

## Questions for Levi
- none

## Review
- MINOR hourly tick defeated by its own gate -> fixed: tick uses minIntervalMs = INTERVAL_MS - 60 s; test hourlyTickPassesWithAMarginAfterTheForegroundStamp
- MINOR cap sweep dropped when a pass is running -> fixed: retries (2 s later) when sweepTemporary returns null; callers of sweepForDiskGuard (MM-5) must handle a null result
- MINOR removeTemporaryAssets stale snapshot -> fixed: whole primitive runs under the hold-ledger lock (all hold mutations take it) and the final replace applies only when the live hold still equals the snapshot
- NIT Mix Mode off / disk guard call sites -> not wired here by design; owned by P2-MM-4 / P2-MM-5 (entry points exist and are tested)

fixes applied
