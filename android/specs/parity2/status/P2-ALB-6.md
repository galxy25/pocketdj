state: implemented

# P2-ALB-6 - Album waveform editor

- [x] `AlbumBoundaryEdits.kt`: pure model (starts/total/ends via AlbumFileTimeline, handle hit-test, minGap clamp, vertical-pan rule, saveBoundary delta rebuild, rename delta, readout/nudge strings)
- [x] `AlbumWaveformEditor.kt`: Coil PNG + placeholders, key-tinted regions (0.26 alpha + 3 dp edge, end at playback end), titles, 4 Hz playhead, handles (22 dp band over 96 dp), nudge bar, rename dialog, custom pointer gesture (direction decided before consuming; vertical pan left to the LazyColumn; deferred single tap so double-tap = rename)
- [x] Mounted in `AlbumDetailScreen` after the header (self-hides when any start is unknown)
- [x] `AlbumBoundaryEditsTest`: 17 tests. Full suite 6842 tests, 0 failures; assembleDebug green. No manifest/gradle/proguard/library change (Coil already present), so assembleRelease not run.

## Deviations / files touched outside owned set
- `SetlistSequencer.kt`: +`albumFileState()` / `albumFilePositionMs()` (additive, ~6 lines) for the playhead and "loaded" check.
- `CatalogRepository.kt`: +`rawAlbum(id)` / `rawSong(id)` backed by the pre-overlay merge kept in `buildCatalog` (needed for raw-segment deltas and raw-name rename; the ALB-8 package may want the same accessor - merge by keeping one).
- Total length uses `audioDurationSec` / segments only: Android has no side-file duration from the engine (iOS uses the player's real duration when loaded).
- Not-playing tap: `playFrom(i, into)` starts the album from track i via `collections.playNow(tracks.drop(i))` + `cueNextStart`, so earlier tracks are not in that queue.
- Moving a boundary back to its raw start on a gapped side leaves the previous song's end at that start (iOS compares the end with ITS raw end); covered by a test as iOS parity.
- No emulator run (instructions): tap/seek and drag-handle steps are unverified on device.

## Questions for Levi
None.
