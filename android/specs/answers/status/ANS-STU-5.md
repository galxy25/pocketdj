state: reviewed

# ANS-STU-5 Tracks paging part B: clip windows as PCM16 page files with read-ahead

- [x] ClipReader.kt: ClipReader interface, ArrayClipReader, MappedPcm16ClipReader (mmap, alloc-free read, prefetch), ClipFeeder
- [x] ClipPageStore.kt: keyed PCM16 page files (atomic write, header validation, invalidateSource, LRU trim, snap/quantize)
- [x] MultitrackRenderContext: Clip(samples | reader); paged read via preallocated scratch; prefetchAhead (loop-wrapping, 6 s); feeder started at load (primes synchronously = seek re-prime), stopped/closed at release
- [x] ArrangerClipPlan.build: optional pager; windows >= 20 s are written as pages and read via mmap, cache hit skips decode; key = file + source stamp + window + warp; unwarped fallback keyed as raw
- [x] MultitrackPlayer: pageStore/shortClipFrames params; MultitrackClipLoader.sourceStamp (default ""), StudioClipLoader = length+mtime
- [x] Tests: ClipPageStoreTest (6, incl. 60 min of clips heap-free), MultitrackPlayerPagingTest (8, paged == in-memory bit-exact on PCM16 grid)
- Full suite: 5357 tests, 0 failures; assembleDebug green. 14 tests added.

## Touched outside owned files
- ArrangerBouncer.kt (ArrangerClipPlan lives there): additive pager params; Bouncer itself still passes no pager (in-memory, float-exact bounce).
- di/StudioGraph.kt: MultitrackPlayer gets `pageStore = ClipPageStore(cacheDir/clip-pages)` (2 GB LRU cap).

## Notes
- Planning still decodes one whole source file as floats at a time (peak during play-start), but nothing is retained after the window is paged.
- Window mmap limited to < 2 GB (~3.3 h); OOM/TOO_LARGE catch retained as a fallback.
- invalidateSource() exists for clip delete/re-record; key stamp already makes edits miss the cache and trim() removes stale pages by LRU.

## Questions for Levi
- None (cache cap 2 GB and 20 s short-clip threshold are defaults).

## Review
- MAJOR main-thread page I/O -> fixed: ArrangerClipPlan.build takes `io` (default Dispatchers.IO); stat/has/open/writeStream/trim all run in withContext(io); MultitrackPlayer runs ctx.load (sync prefetch) on `ioDispatcher`. Test: pagingIoRunsOnTheIoDispatcherNeverTheCallersThread.
- MAJOR OOM/TOO_LARGE reachable on miss -> fixed: miss path streams window -> page via writeStream (no copyOfRange, no toStereo copy); new MultitrackClipLoader.decodeWindow (StudioClipLoader uses decodeRangeBuffer) decodes only the clip window for bounded long clips. Tests: longMissDecodesOnlyItsWindowAndStreamsIntoThePage, playerStartsALongArrangementViaWindowDecodeAndPagesIt (30 min source, outcome STARTED, no whole-file decode). Residual: clips with durationMs<=0 (to end of file) still whole-decode.
- MINOR reader leaks -> fixed: SUPERSEDED after build closes readers; cache-hit readers opened lazily one at a time. Tests: cancelledPlanClosesEveryReaderItOpened, supersededAfterPlanningClosesPagedReaders.
- MINOR orphaned pages -> fixed: ClipPageStore.retainSources(live) swept after each plan (StudioGraph supplies clip files of all arrangements); abandoned-warp fallback key now protected in trim. Test: retainSourcesDropsPagesOfFilesNoArrangementReferences.
- NIT test name overstates -> player test now backed by TrackingStore assertions (readers opened, window-decoded, no whole decode).
- rejected: none.
- Suite: 5363 tests, 0 failures (was 5357, +6); assembleDebug green.

fixes applied
