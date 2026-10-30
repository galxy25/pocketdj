state: implemented

- [x] MixEngine and NowPlayingDspEngine sinkFactory use StudioOutputs.create (Oboe on device, AudioTrack on emulator); logs "sink backend=oboe|audiotrack" on the MIX lane
- [x] OboeSink.start resets disconnect/backoff state (park-then-restart after a route change previously kept stale wasDisconnected/nextRebuildAt)
- [x] MixRecovery re-checked: onSinkRouting/restartSink semantics are identical for OboeSink (park=stop, restart=new backend via factory); doc comment updated
- [x] Tests: MixSinkParkTest +2 (Oboe park/restart after disconnect, backend choice). Total JVM tests 5672, all pass; assembleDebug green.

Notes: StudioOutputs actually lives in studio/audio/StudioAudio.kt (added currentBackend() there). No manifest/proguard/build changes, so assembleRelease not run.
