state: implemented

# STU-12 — MultitrackPlayer, render context, clock, master FX grid, looper, transport

Summary: `MultitrackRenderContext` (BlockRenderer: clip sum by frame cursor, per-track gain/centre-unity pan, per-track
TrackFX only when active, MasterFX with freeze never allowed, peak limiter, loop wrap, seek head-trim, renderedTotal
starts at the seek cursor), `MultitrackPlayer` (decode + pre-bake via StudioRender.transformBuffer, fileStartMs window,
Beat Match rate/snap via `ArrangerBeatMatch`, playGeneration token across decode awaits, applyMix by track id, applyMasterFX,
debounced 350 ms re-prime on bake-affecting edits, auto-stop), `MultitrackClock` (non-observable, latency-aware, loop-wrapped
position math), TransportBar / MasterFxGrid / LoopRegionOverlay (handles in timeline dp space, beat snap), wired into
ArrangementScreen (play/stop, ruler seek restarts, live cursor via frame loop, master FX panel, loop band).

Tests: +43 new JVM tests (MultitrackClockTest 6, MultitrackRenderTest 13, MultitrackPlayerTest 10, ArrangerBeatMatchTest 2,
LoopRegionMathTest 5 + shared). Full `:app:testDebugUnitTest :app:assembleDebug` green: 4028 tests, 0 failures.

## Checklist
- [x] MultitrackClock / MultitrackRenderContext (+ ArrangerBeatMatch, kernel-param mappers)
- [x] MultitrackPlayer (+ MultitrackClipLoader seam, StudioClipLoader)
- [x] TransportBar, MasterFxGrid, LoopRegionOverlay
- [x] ArrangementScreen + StudioGraph wiring
- [x] tests green

## Deviations / notes
- NO `multitrack.cpp`: the render context is pure Kotlin (roadmap allows the pure-Kotlin path). Per-track/master FX still use
  `NativeDsp.trackFx/masterFx` (native when loaded). Moving the sum loop native is a device-perf follow-up if Oboe underruns appear.
- Files outside owned list (minimal/additive): `screens/producer/tracks/ArrangementScreen.kt` (player param, play/loop/FX UI, live cursor),
  `di/StudioGraph.kt` (lazy `multitrackPlayer`), tests `screens/producer/tracks/LoopRegionMathTest.kt`.
- `ArrangerBeatMatch` lives in MultitrackRenderContext.kt; TRK-3's bouncer (STU-13) should reuse it for WYSIWYG.
- Record-to-master tap not included (STU-13 owns recording/bounce); the context exposes `renderOffline` for the WYSIWYG test.
- Brazilian-bass test compares after the sub low-pass settles (cold LP on a seek is expected, as on iOS).
- Master FX grid has no Freeze control by design.

## Emulator steps (not run; integrator-owned)
Play 2-lane arrangement; toggle mute/solo/gain live (logcat tag MultitrackPlayer applyMix); enable Drive; loop 2 bars wraps.

## Questions for Levi
- none
