state: reviewed

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

## Review
fixes applied. 4899 JVM tests, 0 failures (11 added); assembleDebug green.

- MAJOR engine start/stop reasons: FIXED. StudioDiag.play/stop now emitted in StudioEngine (play/slice/pause/stop/natural-end), LoopAudition, PatternEngine, MultitrackPlayer (incl. natural-end/restart/reprime), InstrumentEngine replay, both StemPlayers (demux) and ArtifactAuditionPlayer. StudioGraph focus-loss lambdas pass reason=focus-loss; cross-owner pre-empts pass reason=superseded. One engine-level test per engine asserts the line.
- MAJOR Media3 session path ungated: FIXED. SequencerForwardingPlayer.play() consults AudioFocusPolicy.gateStartRaw("playback.remote") first and emits new verdict refused-mic-capture; JVM test with injected gate asserts neither base player nor control is reached.
- MAJOR Demux + artifact players ungated: FIXED. gateStart("demux") in both StemPlayer start paths (togglePlayPause, solo), gateStart("artifact") in ArtifactAuditionPlayer.toggle. SingleAudioLayerGuardTest now has a MediaPlayer allowlist + asserts the Studio sites call the gate.
- MINOR InterruptionLedger dead: FIXED for sample + pattern. New InterruptionCoordinator (ledger-backed) is wired in StudioGraph; sample park-on-transient-loss / resume-on-gain, user transport calls forget. Pattern keeps its own proven park flag. Loop, Multitrack, Instrument replay and Demux still STOP on transient loss (resume needs the caller's file/events/arrangement) - PARTIAL, open question to Levi stays. Tests drive the coordinator via fake callbacks.
- MINOR owner prefix: FIXED. gateStartRaw(owner) added; PlaybackController logs owner=nowplaying / nowplaying.resume, JukeboxRepository now uses gateStartRaw("jukebox") (so it logs).
- MINOR ProducerSmokeTest unrun: NOT FIXED - requires the shared emulator the integrator owns. Item remains PARTIAL: run on the pocketdj AVD, add seeded-cue / demux-source assertions and tag-based nav then.
- MINOR ARCHITECTURE doc: NOT FIXED by design (workflow rule 4); paste-ready Ch.4 block remains in android/specs/studio.md; ledger row for STU-16 is PARTIAL until the integrator applies it and runs the smoke test.
- NIT guard wildcard import: FIXED (import android.media.* counts as AudioTrack import); MediaPlayer allowlist added.
