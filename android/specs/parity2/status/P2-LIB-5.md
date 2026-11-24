state: implemented

# P2-LIB-5: Inline slide-out player under the playing row (album detail)

## Summary
- `InlinePlayerPanel.kt`: pure `InlinePlayerState` (body mapping LIVE/APPLE_MUSIC/WAVEFORM/SCRUBBER, row keying on the
  sequencer's current song then audible, `analogCrop`, seek-from-x, scrubber duration, clock, "via Apple Music") plus
  `InlinePlayerSlot` composable: play/pause, title/artist, live badge / via label, collapse chevron, close (stops),
  waveform strip (album PNG cropped to the song's window for analog, tap/drag seek, playhead) and slider with 4 Hz polling.
- `AlbumDetailScreen.kt`: each track row is now a Column of `AlbumTrackRow` + `InlinePlayerSlot` (animated expand/collapse).

## Tests
8 new JVM tests (InlinePlayerStateTest). Full `:app:testDebugUnitTest :app:assembleDebug` green: 7663 tests, 0 failures.

## Deviations
- `analogCrop` lives in `InlinePlayerState` (owned file), not `CueSeek`, to avoid touching a non-owned file.
- `AlbumTrackRow.kt` not modified (slot is placed by AlbumDetailScreen). Not wired into other lists (Browse/playlists) - roadmap scope is album/collection detail only.
- assembleRelease not run (no manifest/gradle/proguard/library change).

## Questions for Levi
None.
