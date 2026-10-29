state: reviewed

# ANS-MIX-2 Mix tempo/pitch on C++ Signalsmith (Q6a)

Summary: decks now stretch with Signalsmith (cpp/pdjdsp/stretch_rt.*, JNI nativeRt*) behind a `TimeStretcher` interface
(audio/dsp). `NativeTimePitch` is the default; `TimePitch` (Sonic) is the fallback when libpdjdsp is absent (JVM tests).
Always-on stretcher: per-block ratio via `RatioPlanner` (no drift, no rebuild), fixed algorithm latency.
DeckChain publishes `latencyFrames` / `audibleLagSeconds` / `audibleInputClock` at the stamp. Compensation: `DeckController.trueSeconds`
(audible playhead for loops/mod phase), `MixEngine.syncToLead` + `GlideMachine.phaseAlign` via new `PhaseAlignMath`
(audible-phase delta, per-deck lag; diag line `phase-align ... err=..ms`). Handover/scheduled starts stay in the input-clock domain
by design (gains are applied pre-stretcher so they are delayed uniformly with the audio).

Unit tests: 5211 -> 5222 (+11: 8 in TimePitchTest, 3 in CrossfaderSyncTest). assembleDebug builds libpdjdsp for arm64-v8a + x86_64.
Instrumented (compile-verified only, emulator not used): NativeTimePitchInstrumentedTest, MixGraphSmoke addition.

Files outside the owned list: mix/engine/PhaseAlignMath.kt (new, additive), mix/engine/GlideMachine.kt (phaseAlign call), mix/graph/MixGraph.kt
(audibleLagSeconds/release), specs status file.
Note: ReleaseFeedServiceTest.cachePersistsAcrossRelaunchAndCorruptFileIsHarmless failed once, passed on rerun (unrelated, flaky).
Device-only: audible quality, CPU on mid phone (presetDefault with splitComputation; switch to presetCheaper if CPU is high).

## Questions for Levi
- none

## Review
- MAJOR NP DSP not latency-compensated -> fixed: `currentTimeSec` (and so `disengage()`'s hand-back position) subtracts the stretcher lag while playing; `onAudioStarted` is delayed by the stretcher latency on the render clock; end detection waits for the tail to drain (render-clock, deterministic). Tests: NowPlayingDspEngineTest `reportedPositionIsLagCompensatedNotTheRawVoiceCounter`, `endIsReportedOnlyAfterTheStretcherTailDrains` (via new `TimeStretchers.factoryOverride` seam with a lagging fake kernel).
- MINOR 16 KB alignment -> fixed: main's `-Wl,-z,max-page-size=16384` link options added to pdjdsp CMakeLists (LOAD align verified 0x4000 on built arm64 .so, see below).
- MINOR always-on stretcher on idle chains -> fixed: DeckChain skips the STFT once it has no voices/handover and the tail has drained; latency stays constant; test `idleChainDrainsTheTailThenSkipsTheStretcherWithConstantLatency`.
- MINOR StreamDecks runway used lag-compensated playhead -> fixed: new `DeckController.voiceSeconds` / `MixEngine.voicePlayhead` (uncompensated) used for runway math.
- MINOR vacuous latency instrumented test -> fixed: rewritten to assert the inLat/outLat model at 0.7/1.0/1.3x (KDoc says continuous, not fixed). Compiles (compileDebugAndroidTestKotlin); NOT run on the AVD (emulator owned by the integrator).
- NIT release()/reset race -> not done (graphs are app-scoped; optional).
- Unit tests 5222 -> 5225 (+3), 0 failures; assembleDebug OK.

fixes applied
