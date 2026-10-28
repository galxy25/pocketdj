state: merged

# SVC-4 — Burned-first resolver + PlaybackMode toggle + collection Rip/Burn bar

- [x] PlayResolver.resolveBurnedFirst (+isLocalUrl); PlaybackController.play / playAlbumQueue use it via the localFiles seam
- [x] BurnedRowResolver (LocalFileResolver + RowSourceResolver), DeviceQueuePlan; ServicesGraph.burnedFirst feeds the LOCAL_FILE rung
- [x] BurnSettings, CollectionBurnBar (reducer + controller + composable + single progress pill), PlaybackModeToggle
- [x] Bar wired into Playlist / Pocket / Setlist detail; playlist rows show "not ripped — Rip first" / live rip phase
- [x] Tests: PlayResolverBurnedFirstTest, BurnedRowResolverTest, CollectionBurnBarStateTest (25 new); full suite 1645 tests, 0 failures; assembleDebug green

## Files touched outside owned set (minimal, additive)
- playback/PlaybackController.kt (burned-first in play/playAlbumQueue), playback/PlaybackUrlResolver.kt (never presign file: urls)
- di/PlaybackGraph.kt (localFiles = servicesGraph.burnedFirst), PocketDetailScreen.kt, SetlistDetailScreen.kt (bar item)

## Notes
- Device-mode skipping and the one-shot banner were already in the sequencer/registry (PB-1); DeviceQueuePlan is the pure mirror, tested.
- Stemify from the iOS bar is not ported (out of acceptance).
- Burn runs on appScope so it outlives the screen.

## Questions for Levi
- None.

## Review
fixes applied

- MAJOR refreshAhead swaps burned items to network → fixed (skips file: items via PlaybackUrlResolver.isLocalItemUrl; test added)
- MAJOR Stop cancels burn job, no summary → fixed (no hard cancel; store returns stopped result, summary shows "stopped"; state reset in finally; test rewritten + cancel-reset test)
- MAJOR ARCHITECTURE-ANDROID ledger row → fixed (PARTIAL, notes unverified-on-emulator and Stemify dropped)
- MINOR stale "not ripped" row note / raw phase → fixed (manifestHit suppresses; phaseLabel mapping)
- MINOR row notes only in Playlist → fixed (Pocket and Setlist rows use rememberRowNote)
- MINOR main-thread disk IO → fixed (burnedFile runs on Dispatchers.IO)
- MINOR DeviceQueuePlan unused mirror → fixed (removed with its tests; real path covered by SetlistSequencer/ResolveLadder/ReviewFixes tests)
- MINOR wide recomposition → fixed (per-row rememberRowNote flows; hasSongs via derivedStateOf)
- NIT controller key → fixed (keyed on collection id); app-scoped summary persistence not done.
