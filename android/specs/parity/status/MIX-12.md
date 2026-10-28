state: implemented

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
