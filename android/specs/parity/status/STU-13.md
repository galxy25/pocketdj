state: reviewed

# STU-13 — Bounce (artifact), record-to-master (Clean/Quantized), scissor trim (multi-select), Beat Match + grid analyzer, channel-strip bake

Summary: `ArrangerClipPlan` (the ONE decode/window/warp/beat-snap planner, now shared by the live `MultitrackPlayer` and the
bouncer so bounce == playback by construction), `ArrangerBouncer` (offline pull of the same `MultitrackRenderContext`: per-track
gain/pan + strip FX kernels + master FX/gain, Freeze bypassed, mute/solo ignored, peak-normalized, off-main, atomic dated
`bounce-<ts>.m4a` + `.bounce` artifact only), `MasterRecorder` (post-limiter canonical master tap -> streamed float32 WAV on a
writer thread; nonce bumps ONLY on natural end; restart/re-prime keeps recording and deletes the leftover partial; Quantized
relabels w/o resample) + `MasterRecordingBaker` (-> `live-recording-<ts>.m4a` Recording artifact), `TrimGap`/`TrimSession`
(staged map + undo stack, All-tracks default, selection locked once a cut is staged, Save = `commitTrimmedTrack` per selected
track, Cancel = zero writes), `ArrangerBeatMatch` (own file; + scaledFileStartMs/warpedFrames/needsBake), `ArrangerGridAnalyzer`
(BeatDetect per clip in background -> clip.grid, zero-bpm sentinel, resurrection-safe write-back, in-flight dedupe).
UI: `BounceSheet` (Bounce all / pick tracks), `RecordMenu` (record toggle + Clean/Quantized caret, persisted), `TrimModeOverlay`
(scissor toggle, toolbar, region band + beat-snapped handles that also absorb input over the lanes), Beat Match chip gated on
`beatGridReady` ("Beat grid under construction…"), all wired into ArrangementScreen.

Tests: +51 net new JVM tests (53 in the new/extended classes, 2 moved): ArrangerBeatMatchTest 7, TrimGapTest 8, ArrangerBouncerTest 11,
MasterRecorderTest 14, ArrangerGridAnalyzerTest 8, TrimAndBounceUiMathTest 5. Full `./gradlew :app:testDebugUnitTest :app:assembleDebug`
green: 4218 tests, 0 failures (count moved from 4167).

## Checklist
- [x] ArrangerBeatMatch.kt (moved out of MultitrackRenderContext.kt) + tests
- [x] TrimGap.kt (TrimGap, TrimSession) + tests (multi-track commit, shared-tail dedupe, orphan clean, cancel = zero writes)
- [x] ArrangerClipPlan + ArrangerBouncer + tests (bounce == live player samples, FX baked, mute/solo ignored, gain applied, trimmed gap silent)
- [x] MasterRecorder + player record tap + tests (nonce state machine, restart keeps recording, partial deleted, canonical WAV rate)
- [x] ArrangerGridAnalyzer + tests
- [x] BounceSheet / RecordMenu / TrimModeOverlay + ArrangementScreen wiring + StudioGraph providers
- [x] full suite + assembleDebug green

## Deviations / notes
- Files outside the owned list (minimal/additive): `studio/engine/MultitrackPlayer.kt` (uses ArrangerClipPlan; `recorder` ctor param;
  `playOutcome(..., record, quantized)`; `recordingFinishedNonce`/`consumeRecording`; natural-end auto-stop passes naturalEnd=true),
  `studio/engine/MultitrackRenderContext.kt` (ArrangerBeatMatch object moved to its own file), `screens/producer/tracks/ArrangementScreen.kt`
  (action row, trim/bounce/record wiring, busy overlay), `di/StudioGraph.kt` (arrangerBouncer / masterRecordingBaker / arrangerGridAnalyzer,
  recorder temp dir), tests `MultitrackPlayerTest.kt` (ArrangerBeatMatchTest class moved to its own file).
- `TrimGap.trimGap` delegates to the existing `StudioStore.trimGap` / `commitTrimmedTrack` (already ported + tested in STU-1); STU-13 adds
  the session state machine and staged multi-track flow.
- Quantized record mode: the Android sink always runs at the canonical 44.1 kHz, so Clean and Quantized produce identical audio on this
  backend; the relabel-vs-resample distinction is implemented and tested (48 kHz capture) for a sink that runs at a hardware rate.
- WYSIWYG: the bounce does not run the live PeakLimiter (iOS parity: peak-normalize only when >1.0), so a >1.0 mix is normalized rather than
  limited; below 1.0 the bounce is bit-identical to the live render (tested).
- `fileStartMs scaled`: the live/bounce paths window the SOURCE then warp, so no scaling is needed in the render; `scaledFileStartMs` /
  `warpedFrames` expose the scaled geometry (tested) for UI/length math.
- A recording that is stopped externally (audio-focus loss) is not auto-baked (only Record button, Stop, natural end bake); the UI flag
  resets on screen exit and unconsumed captures are discarded. Needs a device pass.
- Trim mode: add-clip is disabled in the track header, and the region layer absorbs taps so staged clips cannot be moved/removed mid-trim.
- Trim cursor/seed region: iOS "4 bars" is actually 4 beats (60000/bpm*4); ported as-is.

## Emulator steps (not run; integrator-owned)
Bounce all -> artifact appears under Bounces with duration; scissor: select region -> Delete -> Undo -> Delete -> Save -> gap silent;
Record -> stop -> Recordings artifact (also let it play to the natural end); Beat Match chip stays disabled until grids finish.

## Device-only
Record-pitch correctness on a 48 kHz hardware device (assert WAV sample rate equals canonical and duration matches wall clock);
Oboe underruns with the writer thread; audio-focus-loss while recording.

## Questions for Levi
- Should an audio-focus-loss stop during Record bake the partial take (iOS has no equivalent signal), or discard it as now?
