state: implemented

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
