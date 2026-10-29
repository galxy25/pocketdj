state: reviewed

# ANS-STU-1 — StudioMaterializer for SAF media + MIDI import button

- [x] StudioMaterializer (lease/release idempotent, cacheDir/studio-saf keyed uri+size+mtime, LRU byte cap, pinned leases)
- [x] TakeFiler.useAsSample, StudioAnalyzer.ensureKey, DemuxEnv.studioFile (now suspend), TracksHomeScreen clip baker use it; copyUriToCache removed
- [x] MidiImportButton shared by Takes + Instruments Play section
- [x] Tests: StudioMaterializerTest (6), TakeFilerTest SAF case, DemuxSessionTest SAF case

## Notes / deviations
- Score/LiveStaff button left out (acceptance says optional).
- DemuxEnv.studioFile became `suspend`; the graph holds one lease at a time (previous released on next selection).
- Touched DemuxSession.kt (interface signature only), outside the owned list.
- Cap default 256 MB.

## Questions for Levi
None.

## Verification
- Fixed constructor param order (trailing-lambda binding) in StudioAnalyzer/TakeFiler; StudioGraph + TakeFilerTest call sites updated.
- `./gradlew :app:testDebugUnitTest :app:assembleDebug` green: 5139 tests, 0 failures.

## Review
- Concurrent same-uri copy corruption -> fixed (per-key lock, unique temp file, atomic rename; test)
- DemuxEnv lease out-of-order release -> fixed (new SingleLeaseFiles, generation-based; stale call releases its own lease; test)
- LRU index memory-only -> fixed (seed from disk on first use, delete stray .part, evict to cap; test)
- 32-bit hash key / null mtime -> fixed (SHA-256 key; mtime 0 never reuses cache; tests)
- DemuxSessionTest tests only fake env -> fixed in substance: real logic extracted to SingleLeaseFiles in StudioMaterializer.kt and tested directly (StudioGraph delegates to it)
- MidiImportButton KDoc -> fixed (copy parity left optional)
- TracksHome side-list leases -> rejected (NIT, optional; works, left as is)

fixes applied. Tests 5144, 0 failures (was 5139, +5).
