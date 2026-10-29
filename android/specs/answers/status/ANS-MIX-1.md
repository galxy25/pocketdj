state: implemented

# ANS-MIX-1 Auto-DJ stream failure cooldown (Q38)
- [x] MixStreamLoader.canStream(songId, forAuto): 2s, 2s, 3s after consecutive failures, then 120s default; reset when a stream completes
- [x] MixStreamLoader.open(..., forAuto) gates on the same flavour (else open() would still refuse for 120s)
- [x] StreamDecks: transientlyUnloadable + loadStreaming use forAuto=engine.autoMixing; StreamLoaderPort.open gained forAuto
- [x] MixGraph LoaderAutoSeams canStream passes forAuto=true (1-line touch outside owned files)
- [x] Tests: MixStreamLoaderTest (schedule, margin-tolerant since the test clock ticks per read; reset on success; manual open still refused), StreamDecksTest
- [x] gradle green: 5134 tests, 0 failures (+2 new loader tests, +StreamDecks forAuto test); assembleDebug OK

Server-down cooldown (60 s) unchanged. Manual loads keep 120 s.
Build note: parallel builds OOM'd the Kotlin daemon; used -Pkotlin.compiler.execution.strategy=in-process -Dorg.gradle.jvmargs=-Xmx4g (CLI only, not committed).
Emulator step / device-only network flaps not run.

## Questions for Levi
None.
