state: merged

# STU-4 — Loops tab + slice editor (performance pads)

Summary: the Producer "Loops" sub-tab is live and the sample editor gains "Slice into pads".
- Loops tab (LoopsScreen): Unfiled + collapsible loop-folder sections, looped audition toggle per row, rename, Move to (Unfiled/folder/New folder...), delete with a dialog that spells out the sequencer rows that go silent, "Source sample removed" note, empty state pointing at the builder, folder create/rename/delete.
- Builder (LoopSliceSheet): sample picker (grid-less samples disabled + "Set BPM in the sample editor to slice loops" CTA), beat chips 1/2..32 (`loop-slice-0.5`..`-32` tags), anchor +/- one beat with label + "From start", exact computed window label (+ frame count), looped Preview, Save (stays open for back-to-back variants).
- LoopAudition: seamless whole-buffer loop of the loop's own file, conformed (trim/zero-pad) to the AUTHORITATIVE frame count; logs `studio.loop play <id> decoded= looped= expected=` for the emulator frame-count check. Self-contained: reads only the loop file, so it plays after parent deletion.
- LoopFactory: preview and Save both run the REAL StudioRender.renderLoop from the RAW sample file (edits baked once), preview file lives in cacheDir outside every family folder; the loop record carries the renderer's frames/lengthMs/bpm.
- SliceEditorSheet: 8 draggable markers on a waveform (commit on release), steppers + Auto-slice (beat-snap with coincident snaps merged / even chop), Detect BPM for grid-less, 2x4 pad grid (tap = one-shot via StudioEngine.playSlice over [start, nextStart) of the RAW file; long-press = rename / nudge +-50 ms / Make sample / Delete), Send pads to sequencer (bakes each pad -> smp_, files ONE pattern).

Tests: +28 new JVM tests (LoopAuditionTest 17, SliceMathTest 11). Full `:app:testDebugUnitTest :app:assembleDebug` green: 2787 tests (2759 before), 0 failures.

## Checklist
- [x] LoopMath (window/length/frames/anchor stepping/copy) + LoopAudition + LoopFactory + tests
- [x] SliceMath + SliceBaker + tests
- [x] LoopsScreen + LoopSliceSheet
- [x] SliceEditorSheet
- [x] Wiring (StudioGraph lazies, ProducerScreen Loops tab, SampleEditorSheet "Slice into pads" button)
- [x] Full suite green at the committed tip

## Deviations / notes
- New files beyond the owned list: `studio/engine/SliceBake.kt` (SliceMath + SliceBaker; kept out of LoopAudition.kt). The roadmap's "LoopMathTest" cases live in LoopAuditionTest (LoopMath is in LoopAudition.kt); slice-window cases in SliceMathTest.
- Files touched outside the owned list (minimal/additive): `di/StudioGraph.kt` (lazy `loopFactory`, `sliceBaker`, `loopAudition`, ON_STOP stop of a running loop audition), `screens/producer/ProducerScreen.kt` (Loops tab routes to LoopsScreen), `screens/producer/samples/SampleEditorSheet.kt` ("Slice into pads" button + sheet host). StudioEngine/StudioStore untouched (loop audition has its own graph/sink; store already had loops/slices/folders APIs).
- Loop-folder collapsed state uses rememberSaveable (survives rotation, not a process restart); iOS persists it in UserDefaults. No AppSettingsStore edit.
- A baked pad's grid is the sample's grid SHIFTED to the pad start (BeatMath.shifted); iOS copies the unshifted grid, which mis-phases the carve.
- Loop audition stops on ON_STOP (backgrounding); iOS keeps auditioning across navigation but Android has no foreground service for Studio.
- Loop audition parks Now Playing and any sample audition via the same one-audible-owner path as StudioEngine; a loop refuses while the mic captures.
- Pads/loops use the RAW sample file (`SampleRenderCache.sourceFile`), never the edit cache.
- Gradle needs more heap here: run with `-Dorg.gradle.jvmargs=-Xmx3g -Pkotlin.daemon.jvmargs=-Xmx3g` (Kotlin daemon hit GC overhead at 2 GB); gradle.properties not edited.

## Device-only / unverified
- Audible seam-click judgement; Oboe latency of the loop sink; emulator steps (seeded sample -> slice 4 beats -> save -> audition, logcat frame count; delete sample -> loop still auditions) NOT run (emulator is the integrator's). Pad drag feel on a real touchscreen.

## Questions for Levi
- Should the loop audition keep playing when the app is backgrounded (needs a foreground media service) or stop as now?

## Review
- MAJOR decode throws crash (StudioGraph/LoopAudition) -> fixed: play() catches decode exceptions (rethrows cancellation) as "unreadable"; StudioGraph lambda also runCatching; test throwingDecoderIsAnUnreadableRefusalNotACrash.
- MINOR audition stopped from onPause flush / off-main race -> fixed: removed the Flushable; stop now from a ProcessLifecycleOwner ON_STOP observer on Main; LoopAudition play/stop are lock-guarded. (Status note above "ON_STOP stop" is now accurate.)
- MINOR no generation/arming -> fixed: generation bumped by play()/stop(), `arming` flow; stale decode dropped; LoopsScreen toggle/delete stop when arming; test stopDuringDecodeCancelsThePendingPlay.
- MINOR bakePad only catches StudioRenderException -> fixed: catches Exception (rethrows cancellation), deletes dest; sendToSequencer in sheet wrapped in try/finally resetting `baking`.
- MINOR start() result unchecked -> fixed: refuses with "output-unavailable" and releases focus if sink not rendering; loop switch swaps the track inside the running sink; tests sinkThatFailsToOpen..., switchingLoopsKeepsTheSinkRunning.
- MINOR .kotlin error logs committed -> fixed: removed from index, `.kotlin/` added to android/.gitignore.
- MINOR ARCHITECTURE-ANDROID ledger row -> fixed: STU-4 row set to Partial (emulator steps + seam click device-only, unrun).
- NIT showBuilder rotation -> showBuilder now rememberSaveable (builder inner inputs and iOS "Add to playlist or pocket" menu item left as follow-ups).
- NIT SliceMath.window duplicates StudioStore.sliceWindow -> not changed (optional; follow-up).

fixes applied. Tests: 2791 run, 0 failures (+4 added).
