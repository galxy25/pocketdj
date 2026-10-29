state: reviewed

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

## Review
- MAJOR server-down masks 2/2/3 s cooldown -> fixed: server-down still pauses 60 s for songs that never failed, but an Auto-DJ PROBE (forAuto, song already failed, short cooldown elapsed) is let through; a good response clears server-down. Test: realHttp500ThenAutoProbeRetriesAfterTwoSecondsDespiteServerDown (real HTTP 500).
- MAJOR gates disagree during startAutoMix -> fixed: MixEngine.autoLoading (set by AutoDj.loadAuto) + streamingForAuto; StreamDecks.loadStreaming uses it instead of autoMixing. Tests: AutoDjTest.startAutoMixLoadsAreStreamedWithTheAutoGate..., StreamDecksTest.loadStreamingWhileAutoLoading...
- MINOR MixResolver.streamable -> fixed: loader.streamableInPrinciple ignores transient gates. Test: streamableInPrincipleIgnoresTransientGates.
- MINOR missing forAuto test in loadStreaming -> fixed (canStream asked [true], open got forAuto=true, loads with only the auto gate open).
- NIT stale failure count -> fixed: resets when last failure older than 10 min (staleFailureCountResetsAfterTheWindow).
- Gradle green: 5139 tests (was 5134, +5), 0 failures; assembleDebug OK.

fixes applied
