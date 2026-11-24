state: merged

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

## Review
- MAJOR stale seek closure (pointerInput(Unit)) -> fixed: strip gestures go through `InlinePlayerState.stripSeeker` reading rememberUpdatedState (duration, isLive) on every call; test `stripSeekerReadsLatestDurationNotTheFirstComposition`.
- MINOR panel only on album page -> fixed: InlinePlayerSlot now under song rows in PlaylistDetailScreen and SourcePlaylistDetailScreen (collection/playlist detail). Browse/Setlist lists remain open.
- MINOR isAm unobserved / preview cap -> fixed: isAm re-read keyed on np (every backend swap republishes np); scrubber capped to 30 s for previews (test `previewCapsTheScrubberRange`). Row-keying on AM song is already enforced by `matches` in the slot.
- NIT exit animation -> fixed (last non-null np remembered).
- NIT coverage -> seek logic extracted into a pure testable function; no Compose JVM harness exists.

fixes applied. Tests: 7665, 0 failures (+2).
state: merged
