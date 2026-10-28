state: implemented

# STU-16 Studio hardening + diagnostics + emulator seed + docs sync + single-audio-layer grep guard

Summary: AudioFocusPolicy.gateStart (+ StudioDiag, InterruptionLedger) now guards every Studio start path (sample, loop, pattern,
multitrack [new PlayOutcome.REFUSED], instrument replay) plus PlaybackController.play/resume, logging a reason on refusal.
StudioSeed.kt owns PDJ_SEED_STUDIO + new PDJ_SEED_DEMUX with bundled studio-fixture-tone.m4a. SingleAudioLayerGuardTest, ProducerSmokeTest
(androidTest, compiles; unrun), android/specs/studio.md.

## Checklist
- [x] AudioFocusPolicy gate + StudioDiag + InterruptionLedger; wired into all engines + PlaybackController
- [x] StudioSeed (studio + demux) + asset fixture; StudioGraph delegates
- [x] SingleAudioLayerGuardTest, AudioFocusPolicyTest, StudioSeedTest
- [x] ProducerSmokeTest (7 sub-tabs, per-tab PNG)
- [x] android/specs/studio.md (+ paste-ready Ch.4 section)

## Touched outside owned files
- studio/engine/{AudioFocusPolicy,MultitrackPlayer,InstrumentEngine,StudioEngine,LoopAudition,PatternEngine}.kt, playback/PlaybackController.kt, di/StudioGraph.kt: minimal gate/diag swaps.
- MultitrackPlayer: new enum value PlayOutcome.REFUSED (callers that only test NOTHING_TO_PLAY/STARTED unaffected).

## Deviations
- docs/ARCHITECTURE-ANDROID.md NOT edited (per workflow rule 4); Ch.4 text is at the bottom of android/specs/studio.md for the integrator.
- Engines other than PatternEngine still STOP (not park) on transient loss; InterruptionLedger exists + is tested but only PatternEngine's own parked flag drives resume today.
- Route-change re-prime lives in the sinks (AudioTrackSink/OboeSink), not per engine; device-only verification.
- ProducerSmokeTest asserts seeded rows only on Samples/Loops/Sequencer; other tabs assert selection + render + screenshot. Unrun (no emulator).

## Questions for Levi
- Should Instruments/Multitrack/Loop also park-and-resume on transient focus loss (iOS parity) instead of stopping?
