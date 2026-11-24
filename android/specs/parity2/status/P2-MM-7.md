state: merged

# P2-MM-7: Mix Mode ph3a (shared GrowingFileSchedule, NP DSP engageStreaming, loader multi-listener + failed marking)

- [x] `mix/stream/GrowingFileSchedule.kt`: pure schedule lifted from StreamDecks/MixMath plus the iOS length-claim sniffer (Xing/Info/VBRI/TLEN/headerless/undetermined), window, coveredFileSeconds.
- [x] `StreamDecks` / `StreamRules` call it (runways, canResume, appendChunk, shouldHold, frontier, shouldAppend). Mix attach now also refuses a headerless / undecided partial (iOS 76dc87ed / b4d679e9); `StreamSourceFactory.lengthClaim` defaults to Container so fakes are unchanged, `Mp3StreamSourceFactory` sniffs the file.
- [x] `NowPlayingDspEngine.engageStreaming(file, expectedBytes, atSeconds, play, startMs, lengthMs, ...)` + `streamProgressed(bytes, complete, failed, finalFile)`; holds freeze the playhead and keep intent; `isBuffering`, `isStreaming`, `onStreamFailed`; stems hand over only after the download completes.
- [x] `NowPlayingDspSessionPlayer`: `NowPlayingDspPort.isBuffering` -> held card -> STATE_BUFFERING, frozen position.
- [x] `MixStreamLoader`: `addProgressListener/removeProgressListener` fan-out; cancel()/eviction mark the stream `failed` and notify (no cooldown).
- [x] Tests: GrowingFileScheduleTest (13), EngageStreamingTest (13), 3 loader tests in MixStreamLoaderTest. Suite: 5933 tests, 0 failures; `:app:testDebugUnitTest :app:assembleDebug` green. No manifest/gradle/proguard change, so no assembleRelease.

## Files touched outside the owned list (minimal, additive)
- `di/MixGraph.kt`: one line, `override val isBuffering get() = engine.isBuffering` on the NP session port.
- `test/.../MixStreamLoaderTest.kt`: three added tests (it owns the loader rig).

## Deviations
- `engageStreaming` takes (file, expectedBytes, atSeconds, play, + window/progress params) and is fed by `streamProgressed` rather than a loader Stream object; the host (P2-MM-8 GrowingStart) wires `MixStreamLoader.addProgressListener` to it.
- Mix `StreamDecks` frontier still adds `start` to the decoder's availableFrames cap (pre-existing, only matters for analog side slices); the NP engine uses plain availableFrames.
- Stem handover during a growing engage is deferred until the stream completes (iOS hands over onto the growing song).

## Questions for Levi
- None.

## Review
- MAJOR streamFailed on attached-but-nothing-scheduled stream -> fixed (hands the row back via onStreamFailed when `!everStarted && voiceEnd <= windowStart`; test anAttachedStreamThatDiesBeforeAnyAudioHandsTheRowBack).
- MINOR repeated length sniff / Voice probe per progress event -> fixed (Undetermined / implausible verdict cached by bytes received, re-probed only after SNIFF_REPROBE_BYTES = 16 KB of growth; test anUndeterminedClaimIsNotReSniffedOnEveryProgressEvent). Mix StreamDecks.attach left unchanged.
- NIT complete-while-paused-holding never finishes the stream -> not fixed (optional; stem handover resumes on next play).

Suite: 5935 tests (+2), 0 failures; `:app:testDebugUnitTest :app:assembleDebug` green.

fixes applied
