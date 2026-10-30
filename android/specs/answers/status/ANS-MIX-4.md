state: reviewed

- [x] MixEngine and NowPlayingDspEngine sinkFactory use StudioOutputs.create (Oboe on device, AudioTrack on emulator); logs "sink backend=oboe|audiotrack" on the MIX lane
- [x] OboeSink.start resets disconnect/backoff state (park-then-restart after a route change previously kept stale wasDisconnected/nextRebuildAt)
- [x] MixRecovery re-checked: onSinkRouting/restartSink semantics are identical for OboeSink (park=stop, restart=new backend via factory); doc comment updated
- [x] Tests: MixSinkParkTest +2 (Oboe park/restart after disconnect, backend choice). Total JVM tests 5672, all pass; assembleDebug green.

Notes: StudioOutputs actually lives in studio/audio/StudioAudio.kt (added currentBackend() there). No manifest/proguard/build changes, so assembleRelease not run.

## Review

fixes applied

- MINOR MixSinkParkTest vacuous: fixed. OboeSink gets a `spawnFeeder` seam; test drives pumpOnce deterministically (failed rebuild leaves wasDisconnected + backoff, stop, restart, second disconnect inside the stale window must report false again and rebuild immediately). Asserts events [false,false,true].
- MINOR unbounded stop() join on main: fixed. Join bounded at 500 ms; generation counter retires a lingering feeder; native close/release handed to the feeder (orphanClose) if still alive. New test stopIsBoundedAndDefersCloseWhileFeederBlockedInOpen.
- MINOR emulator/log verification: not done here (integrator owns the emulator). Checklist: grep logcat for `sink backend=audiotrack` on the MIX lane.
- MINOR Oboe profile: fixed. StudioOutputs.Profile (STUDIO = LowLatency/Exclusive; PLAYBACK = PowerSaving/Shared) plumbed through JNI; both MixGraph factories use createPlayback. Device-only: ducking with nav prompts / Android Auto, battery on long screen-off Mix.
- NIT duplicate backend decision/log: fixed.

Tests: 5673 JVM tests, 0 failures (was 5672). assembleDebug green.
