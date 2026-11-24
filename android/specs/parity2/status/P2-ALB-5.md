state: implemented

# P2-ALB-5 - Album run clocks (song-relative everywhere), album play through the sequencer, seekAlbumFile/cueNextStart

- [x] `AlbumSeek` (pure): relativePosition / relativeDuration / toItemPosition (clamped), nearestOccurrence (forward tie), `StartCue` (one-shot, 30 s TTL); `RunClock` / `RunClockSource`
- [x] `SequencerForwardingPlayer`: currentPosition / contentPosition / buffered / duration are song-relative (clamped >= 0, lead-in shows 0:00); remote `seekTo` (both overloads) maps back to item ms and clamps to the song; `notifyClockChanged()` fires a discontinuity after in-place song changes; `rekick` uses the RAW position
- [x] Controller: `armRun` arms the boundary AND publishes the song clock (`RunTransportBus.runClock`); engine-internal reads/seeks (albumFileState, seekInFile, retarget `before`, retarget guard, handOffPlaying) use the raw ExoPlayer (`RunTransportBus.rawPlayer`) because the session controller is now song-relative. Skip tracker high-water, listenedFraction, snapshot positionMs, health probe and widget all read the controller, so they get song-relative values with no further change
- [x] `SetlistSequencer.seekAlbumFile(fileMs)`: same song => plain seek; other song => nearestOccurrence, noteAdvanceAway + noteUserTransport, index move, publish (session writer persists song-relative), then a fresh start carrying a one-shot scrub target; `AlbumRunPlayer.tryClaim` claims it (disarm, seek FIRST, re-arm, retarget in place); when it declines (DSP/StemLock/held/AM...) the normal load starts the song at `fileMs - seg.start`. `cueNextStart(songId, atMs)` one-shot, consumed by the next fresh start, 30 s expiry
- [x] Album Play: `collections.playNow(songIds, name, shuffle=false, SOURCE_ALBUM, originId)` like Shuffle, opens Now Playing; `playAlbumQueue` truncation hack removed
- [x] Tests: `SongRelativeClockTest` (17): lead-in clamp, remote seek mapping, round trip, session player clocks, rekick raw, seekAlbumFile (same song / other song ordering / engine-declines load fallback / nothing loaded), cueNextStart (one-shot, mismatch)
- [x] `:app:testDebugUnitTest :app:assembleDebug` green: 6665 tests, 0 failures (my file adds 17). No manifest/gradle/proguard/library change, so assembleRelease not run.

## Deviations / files touched outside the owned list (minimal, additive)
- `SetlistSequencer.kt` (shared touchpoint): startCue + seekAlbumFile + cueNextStart + takeAlbumScrub.
- Also touched: `playback/album/AlbumRunPlayer.kt` (scrub claim), `playback/PlaybackService.kt` (+rawPlayer/clockChanged wiring, 4 lines), `playback/RunTransportBus.kt` (+runClock/rawPlayer/clockChanged), test support `SessionTestSupport.kt` (FakePlayerState +position/duration/seeks, additive).
- The scrub's session persist is the normal `publish()` (SessionWriter), not an explicit `persist(positionMs)` call.
- Mp3 index seeking NOT enabled: I could not inspect a real side's header here (no rip access in this sandbox) and `FLAG_ENABLE_INDEX_SEEKING` forces a full-file scan on progressive http, so it is only worth turning on if device seeking proves inaccurate. Device check: seek mid-side from the lock screen / waveform; if it lands noticeably off, enable `DefaultExtractorsFactory().setMp3ExtractorFlags(Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING)` for analog keys in `PlaybackService` (ExoPlayer.Builder media source factory).
- `rekick` through the in-app MediaController (`engineProbe.rekick`) goes via song-relative seekTo: inside a lead-in it would land at the song start instead of the raw spot (cosmetic, rare).
- The Android UI has no waveform editor yet (P2-ALB-6), so `seekAlbumFile`/`cueNextStart` are exposed on the sequencer only; ALB-6 should call them (via `graph.sequencer`).
- Not run on emulator/device (instructions): lock-screen position at lead-in / reset at glide, `adb shell cmd media_session` seek mapping, and that Media3's metadata-only replaceMediaItem fires the session update that resets the platform position (`notifyClockChanged` is the belt-and-braces).

## Questions for Levi
None.
