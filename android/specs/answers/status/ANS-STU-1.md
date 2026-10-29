state: implemented

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
