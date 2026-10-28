state: merged

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

## Review

fixes applied

- MAJOR MultitrackPlayer loop change mid-play -> fixed: loop on/off + region are part of BakeSignature, so they restart via the debounced re-prime (iOS restarts); no live setLoop; positionMs uses the primed loop. Tests: loopTurnedOnMidPlay..., loopTurnedOffMidPlay..., cursorUsesPrimedLoop...
- MAJOR LoopRegionOverlay drag -> fixed: origin + accumulated dx, absolute snap, always snap when bpm>0. Test: manySmallDragDeltasMoveAcrossBeatsWhenSnapped.
- MAJOR ledger row -> fixed (PARTIAL; WYSIWYG-vs-bouncer + record-to-master deferred to STU-13; Oboe latency/live FX quality device-only; emulator not run).
- MINOR "Nothing to play" toast -> fixed: playOutcome() tri-state (STARTED/SUPERSEDED/NOTHING_TO_PLAY). Test: playOutcomeDistinguishes...
- MINOR threading -> fixed: publish/teardown under one lock, generation re-checked immediately before sink start (kept scope-agnostic rather than moving to Main).
- MINOR decode memory -> fixed: one decode per file per pass (sameFileDecodedOncePerPass), released after last use, clips retain only their window.
- MINOR rotation stops playback -> fixed: onDispose skips stop when activity isChangingConfigurations.
- MINOR bouncer criterion -> deferred to STU-13 (recorded here and in the ledger): STU-13 must plan through the shared ArrangerBeatMatch/clipWindow helpers and add the offline-vs-ArrangerBouncer cross-path test.
- NIT default loop region -> fixed: 4 beats from 0:00 capped to length (iOS).

Tests: 4028 -> 4034 (+6), 0 failures; assembleDebug OK.
