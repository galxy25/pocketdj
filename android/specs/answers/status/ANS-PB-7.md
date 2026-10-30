state: reviewed

Tests: 5661 total, 0 failed (+6 new: 2 dispatcher, 4 AutoAsync). Debug + release assemble green.

# ANS-PB-7 Playback disk work off Main

- [x] LocalFileRowResolver / BurnedRowResolver ladder rungs resolve via `withContext(io)` (injected dispatcher, default IO; `io` is the FIRST ctor param so trailing-lambda call sites are unchanged)
- [x] BurnStore.isReadyInLedger (in-memory, no disk); PlaybackGraph.wire sets `seq.rowOnDevice` to it before studioGraph.wire chains
- [x] Auto: onGetLibraryRoot returns AutoAsync.STATIC_ROOT immediately (graph built async via autoBg); onGetItem/onGetChildren/onGetSearchResult miss/onSearch computed on Default with SettableFuture (AutoAsync.compute)
- [x] Tests: BurnedRowResolverTest (dispatcher), ResolveLadderTest (dispatcher), AutoAsyncRootTest (4)

## Notes / deviations
- StudioGraph's chained `studioPlayback.isOnDeviceNow` (studio files, `store.localUrlForPlayback`) still stats disk on Main; out of owned files, left as is.
- Profile-audio (SAF) rows are no longer counted by the stall-hop `rowOnDevice` probe (ledger-only per the acceptance).
- No test for BurnStore.isReadyInLedger itself (one-line map read).
- No files touched outside the owned list.

## Questions for Levi
None.
