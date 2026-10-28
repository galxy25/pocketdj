state: reviewed

# MIX-12 Mix session audio recording

- [x] RecordingTapSink (SPSC FloatRing, whole-block drops counted, isCapturing gate), installed once via MixGraph.recordingTap
- [x] AacAdtsWriter (MediaCodec AAC-LC, own thread, ADTS flush per frame, failure latch + one-shot callback, content clock) + AdtsScan (pure frame counter for orphan duration)
- [x] SessionFolders (filesDir/mix-sessions/<id>/recording-N.aac, bump past on-disk, delete-all keeps live take)
- [x] MixRecorder (file to session at START, writerFailureMessage, checkStall watchdog 5 s / 2 s loop, recoverOrphans idempotent, activeTake never adopted)
- [x] RecordingPlayer (MediaPlayer; pauses the mix via mixEngine.pauseBoth)
- [x] Storage MIX_SESSIONS category (+ StorageScreen copy, AppGraph wiring)
- [x] Tests: TapSinkTest(4) MixRecorderTest(8) SessionFoldersTest(3) AdtsScanTest(2) = 17 new JVM tests; suite 3399, 0 failures. AacAdtsWriterInstrumentedTest written, NOT run (no emulator).

## Files outside owned list (minimal, additive)
- screens/settings/StorageScreen.kt: MIX_SESSIONS copy branch (exhaustive when)
- di/AppGraph.kt: StorageService mixSessionsDir/clearMixSessions args

## Notes
- No UI wiring: record button / Sessions-screen list / launch-time recoverOrphans() and beginWatchdog(scope) calls belong to the Mix/Sessions UI packages. start(scope) also starts the watchdog.
- No user-picked session folder on Android, wasUserFolder always false.

## Questions for Levi
- None.

## Review
fixes applied (suite 3399 -> 3407, 0 failures; assembleDebug green)
- MAJOR watchdog never started via toggle(): FIXED. MixRecorder takes an app-scoped Main scope (supplied by MixGraph); start() always starts the watchdog. Test toggleStartsTheWatchdogWhenScopeIsInjected.
- MAJOR delete-all leaves metadata rows: FIXED. MixRecorder.deleteAllRecordings(): recoverOrphans, unlink all but live/finalizing takes, MixSessionStore.pruneRecordings drops rows of gone files; AppGraph.clearMixSessions points at it. Tests deleteAllRecordingsRecovers..., pruneRecordingsDropsOnlyGoneRows.
- MAJOR recoverOrphans never called: FIXED. AppGraph init launches it on Dispatchers.IO; recordingTap no longer builds the engine (tap installed on first take). Not emulator-verified.
- MINOR writer opened asynchronously: FIXED. AacAdtsWriter.start() opens file + starts codec synchronously and throws; MixRecorder returns false and removes the empty file; a writer dying with 0 frames files no row and deletes the file. Tests startFailureFilesNoRowAndRemovesEmptyFile, writerDeadBeforeAnyFrame....
- MINOR AdtsScan readBytes: FIXED. Streamed via RandomAccessFile; recovery runs on IO. Test fileScanStreamsAndMatchesByteScan.
- MINOR RecordingPlayer incomplete: FIXED. lastError/consumeError, durationMs, currentPositionMs, seekTo; mix paused via autoDj.remotePause() (suspends Auto-DJ, resumable) instead of pauseBoth().
- MINOR recovered startedAt: FIXED (lastModified - duration). Test recoveredStartIsMtimeMinusDuration.
- MINOR stop() blocks main: FIXED. UI state flips at once; drain/join on a finalize thread, take filed on main after; in-flight take protected (liveFiles). Test stopFlipsStateImmediatelyAndFilesAfterAsyncFinalize.
- NIT decode in instrumented test: not done (needs emulator; test remains NOT run).
- NIT clipping: FIXED with a soft knee (linear to 0.9, tanh into +-1) in the writer.
