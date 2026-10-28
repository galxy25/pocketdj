# Studio / Producer (Android) — as shipped

Source of truth for the Producer area after STU-1…STU-16. iOS reference: `apple/PocketDJ` Studio*. Sub-tabs (seven, `StudioSubTab`):
Samples, Loops, Sequencer, Instruments, Cues, Demuxer, Tracks.

## One audible owner
- Every Studio engine (sample audition `StudioEngine`, `LoopAudition`, `PatternEngine`, `MultitrackPlayer`, `InstrumentEngine` replay)
  asks `AudioFocusPolicy.gateStart(owner)` before sounding. It refuses while the mic recorder is capturing
  (`micCaptureActive`) and logs `audio.play.skip owner=studio.<engine> reason=mic-capture-active` through `StudioDiag`
  (a thin facade over `AudioDiag`, same counters/line shape as Mix). `PlaybackController.play/resume` and the Jukebox start path use the same gate.
- Starting a Studio engine requests `AUDIOFOCUS_GAIN` and first pauses Media3 (`app.playbackController.pause()`) and sibling Studio engines
  (see the `focus` lambdas in `StudioGraph`). The reverse direction needs no code: Media3 requesting focus delivers `AUDIOFOCUS_LOSS` to each
  engine's `FocusHandle`, which stops it.
- Interruptions: `shouldPauseOnFocusChange` (LOSS / LOSS_TRANSIENT) parks. `PatternEngine` parks on transient loss and restarts from the top
  on `AUDIOFOCUS_GAIN` only if it was parked (`parkedForInterruption`); `InterruptionLedger` is the engine-agnostic form of that pairing
  (park remembers who was audibly running; user stop calls `forget`; gain `drainForResume()` resumes exactly the parked set).
- Route changes / stream disconnects (headphone unplug, Bluetooth switch) are handled below the engines by the sinks
  (`AudioTrackSink` device callback, `OboeSink` rebuild-with-backoff + re-prime). **Device-only to verify.**

## Single audio layer
Only `audio/core` (+ `audio/dsp`) may create an `AudioTrack`, a `MediaCodec` audio decoder or an `OfflineRenderer`.
`SingleAudioLayerGuardTest` scans `src/main` and fails on a violation (comments and string literals are stripped; encoders and
`AudioRecord` are allowed).

## Debug seed (debuggable builds only)
`adb shell am start -n com.levi.pocketdj/.MainActivity --ez PDJ_SEED_STUDIO true --ez PDJ_SEED_DEMUX true`
- `PDJ_SEED_STUDIO`: "Seed Tone" sample, "Seed Loop", "Seed Pattern", two cues on `sng_1` (fixed ids, idempotent).
- `PDJ_SEED_DEMUX`: imports `assets/studio-fixture-tone.m4a` (1 s, 440 Hz, AAC) as the Demuxer source "Seed Tone" (once).
- `ProducerSmokeTest` (androidTest) launches with both extras, walks all 7 sub-tabs, asserts seeded rows on Samples/Loops/Sequencer and writes
  one PNG per tab to `<externalFilesDir>/producer-smoke/`.

## Deliberate divergences from iOS
- **Loops are `.wav`** (LPCM, 44.1 kHz) on Android, not `.caf`: no CAF writer on the platform. `AudioDecoder` sniffs content, not extension,
  so sync of iOS `.caf` loops is a read-only import concern, not a playback one.
- **LocalAudioCache ladder** (sample from a catalog track): local burn/cut file -> download into app cache (atomic, in-flight-deduped) when the
  burn folder is unreachable -> "Burn" phase -> "Rip first" when the song was never ripped. Phases: `SourcePhase.Ready/NeedsBurn/Burning/Failed/RipFirst`.
- **N/A on Android:** on-device speech transcription (lyrics come from the cloud sidecar only; `DemuxFeatures.lyricsEnabled` stays a dev seam)
  and security-scoped bookmarks (SAF persisted tree-URI grants replace them; app-managed root is the fallback).

## Verification matrix
| Item | JVM | Emulator | Device-only |
|---|---|---|---|
| Mic flag blocks start, reason logged | AudioFocusPolicyTest | | real mic capture + tap play |
| Focus loss parks / gain resumes only parked | AudioFocusPolicyTest, PatternEngine tests | | call / nav prompt interruption |
| Single audio layer | SingleAudioLayerGuardTest | | |
| Seed gating + fixture | StudioSeedTest | ProducerSmokeTest | |
| Route-change re-prime | | | unplug headphones / BT switch per engine |

## Ch.4 Producer section (paste-ready for docs/ARCHITECTURE-ANDROID.md; the integrator owns that file)
**Producer (Studio)** — seven sub-tabs backed by `StudioGraph` (lazy per-engine, one `FocusHandle` each). Engines share one gate
(`AudioFocusPolicy.gateStart`) and one diagnostics facade (`StudioDiag` over `AudioDiag`). Audio creation is confined to `audio/core` (guard test).
Divergences: `.wav` loops, no on-device transcription, SAF grants instead of security-scoped bookmarks; LocalAudioCache ladder
local -> download -> Burn -> Rip first. Status STU-16: DONE for gate/diag/seed/guard; PARTIAL for emulator (ProducerSmokeTest unrun) and
device-only route-change re-prime.
