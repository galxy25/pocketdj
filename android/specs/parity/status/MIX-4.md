state: implemented

# MIX-4 MixGraph: deck chains, house/cue/limiter, taps, handover + parameter snapshot

- [x] RenderParams.kt: immutable DeckParams/HouseParams/RenderParams, `Routing` gain-split functions, `ParamsComposer` (crossfader path never re-derives trim; `boostWrites` spy)
- [x] Taps.kt: MixTapPulse, TapSink, MixDeckCapture seam, PosStamp seqlock
- [x] Handover.kt: generation-guarded 60 ms LINEAR gain state machine (schedule/settle/advance/abort)
- [x] DeckChain.kt: voices -> inputSum (env tap) -> TimePitch -> 4 slots -> Eq3 -> Trim -> pre VU -> cue/main gains -> post VU; shared deck input clock
- [x] MixGraph.kt: two decks, houseSum -> recording tap/pulse -> housePan -> + cue sends -> Limiter; crossfadeTo/settleHandover; `attach(AudioSink)`
- [x] JVM tests: MixGraphRenderTest (12), CueRoutingTest (6), RenderParamsSnapshotTest (7), HandoverTest (14) + GraphHarness; full suite 1109 tests, 0 failures
- [x] Instrumented smoke (compile-verified only, emulator not used): MixGraphSmokeInstrumentedTest

## Notes / deviations
- Pan semantics: AVAudioMixerNode stereo pan has no exact Android equivalent. `Ramps.pan` folds toward mono by |pan| and attenuates the opposite channel, so pan = +/-1 puts the mono fold on one side (a centered mix keeps its level). Device-verify on a real stereo interface.
- Scheduled starts / handover live on each deck's INPUT clock (frames pushed into TimePitch), which equals the sink render clock at 1x. At speed != 1 they differ; `DeckChain.inputFrameAfter()` and `PosStamp` give the engine coherent values.
- `crossfadeTo(deck, toStems, lead=0.25 s)` seeks the incoming voices to the outgoing side's position at the fade start; the decoder must deliver the first block within the lead. If the incoming side is not aligned when the fade starts, the render thread ABORTS the plan (`handover.abortedGen`, intent flips back, outgoing keeps playing, zero dead air) and the engine (MIX-5) should retry. A handover on a looping deck is not handled here (iOS re-arms the loop instead).
- Zero-allocation test uses reflective ThreadMXBean (android.jar lacks java.lang.management at compile time) and tolerates <=0.1 % of blocks showing JIT noise; steady state is 0 bytes.
- Gain ramps (mainGain, cueGain, stem balance, handover) are linear across a block; first params applied snap (no fade-in from nothing).
- Engine-facing: voices are installed with `setMain` / `setStems`; the engine builds `RenderParams` (or uses `ParamsComposer`) and `setParams`.
- No files touched outside owned set (plus GraphHarness.kt test helper and the androidTest smoke file).

## Questions for Levi
- none
