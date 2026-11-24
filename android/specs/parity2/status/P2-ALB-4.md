state: merged

# P2-ALB-4 - Vinyl album run engine: one ExoPlayer item per side, boundaries, glide + retarget in place, in-place skip, lead-in

- [x] `AlbumRun` (pure): `albumRun` detection (verbatim port; repeat ONE / repeatCount>1 break it; baseId compare), `plan` (clip [leadIn?0:songStart, END_OF_SOURCE), boundary = next start), `leadIn`, `boundaryMs` (run next start / own end / null = file end), `glideStep` (tolerance 3 s, seek-then-retarget), `jumpTargetMs`, `isRunContinuation`
- [x] `PlayerPort`: `PlayRequest.albumRun`, `armBoundary`, `albumFileState`, `seekInFile`, `retargetInPlace` (defaults keep every other port unchanged)
- [x] `SetlistSequencer`: `albumTimelines` seam + `albumPlanFor` (plan rides the PlayRequest), `lastTransitionCause`, NextRowPreloader never preloads a run continuation
- [x] `AlbumRunPlayer`: AdvanceInterceptor (glide on NATURAL boundary only; seek BEFORE re-arm; declines with DSP/StemLock/held/AM/live/DJ tail via `declines`) + StartInterceptor (listener/remote ⏭⏮ in place; skip while paused starts playback)
- [x] Service: `AlbumBoundaryArmer` (ExoPlayer.createMessage setPosition + 250 ms poll fallback, self-heals across the retarget replace) over pure `BoundaryGate` (one-shot, token-superseded); History transition of an in-place retarget suppressed (sequencer records the play)
- [x] Controller `Media3Port`: run item load (clip override + EXTRA_ALBUM_RUN + arm), `replaceMediaItem` retarget with CURRENT catalog title (+500 ms re-seek guard if Media3 re-prepared), `replay` refuses run items, disarm on foreign play / stop / AM / url; `RipsRepository.albumTimeline`
- [x] Tests: AlbumRunTest (22), AlbumGlideSequencerTest (19) - 41 new; full suite 6444 tests, 0 failures; `:app:assembleDebug` green. No manifest/gradle/proguard touched (assembleRelease not needed).

## Deviations / files touched outside the owned list (minimal, additive)
- New: `playback/album/BoundaryGate.kt`, `playback/album/AlbumBoundaryArmer.kt` (service-side armer, kept beside AlbumRun*).
- `PlaybackContract.kt` (+EXTRA_ALBUM_RUN), `RunTransportBus.kt` (+albumArmer, albumBoundaryFired), `data/rips/RipsRepository.kt` (+albumTimeline).
- Controller exposes `albumRunDeclines` for the DJ tail deck / Stem Lock to bind later (no Android Stem Lock exists yet; DSP engagement = `exoFronts()`).
- A clean-only-skip neighbour never continues a run (iOS has no such rows).
- ⏮ onto a song BEFORE the loaded item's clip start (album started mid-side) cannot seek in place: it reloads (clip window starts at the song, per the acceptance's `[leadIn ? 0 : songStart, ...)`).
- Song-relative clocks (position/duration/scrubber of a run item are file-relative until P2-ALB-5), `seekAlbumFile`/`cueNextStart`, and removal of the `isUnboundedAnalog` queue truncation / `playAlbumQueue` hack are ALB-5, not done here.
- Not run on a device/emulator (instructions): Media3 metadata-only `replaceMediaItem` never re-preparing, and VBR seek accuracy remain device checks.

## Questions for Levi
None.
