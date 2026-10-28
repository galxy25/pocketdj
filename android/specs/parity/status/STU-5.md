state: reviewed

# STU-5 — Sequencer tab + pattern engine (clock, step modes, per-step loop/stretch) + bounce

Summary: the Producer "Sequencer" sub-tab is live. Pure step math (`PatternMath`), a frame-based highlight clock (`PatternClock`), a sample-accurate pull scheduler with a rolling 4-bar horizon + mono choke + loop/span steps (`PatternScheduler`, wrapped by the `PatternEngine` lifecycle), an offline bouncer (`PatternBouncer`), and the UI: pattern list with folders, editor, row cards, step grid.

Tests: +76 new JVM tests (PatternMathTest 23, PatternClockTest 9, PatternEngineTest 27, PatternBouncerTest 17). Full `:app:testDebugUnitTest :app:assembleDebug` green: 2956 tests, 0 failures (count moved by 76).

## Checklist
- [x] PatternMath (stepFrames/stepTime/loopWindow/mappedStep, span coverage, stretch-key dedupe, grid layout, list helpers) + tests
- [x] PatternClock (frame-based, latency-aware, sticky-park rule) + tests
- [x] PatternScheduler/PatternEngine (armSlot horizon, choke, loop steps, span buffers, missing-target skip, zero-content refusal, live row gain, live step/loop mirror, startStep + infinity window shared with the clock, solo) + tests
- [x] PatternBouncer (plan == live rules, finite loop bake trimmed to next trigger, wrap head fill, tail drain, atomic write, StudioStretchKey dedupe) + tests incl. bounce == live pass 2
- [x] SequencerController (prepare/play/solo/bounce, notices, stale-prepare generation guard, compatible-reload rule)
- [x] SequencerScreen (list, folders, rename/duplicate/move/delete), PatternEditor (header, BPM/Length steppers, Live toggle + banner, lanes collapse/zoom, add row, bounce status), PatternRowCard (collapse/label/retarget/gain/solo/mixer deck, progressive grid, long-press loop/span menu)
- [x] Wiring (StudioGraph.patternEngine, ProducerScreen route, one-audible-owner hooks, ON_STOP stop)
- [x] Full suite green at the committed tip

## Deviations / notes
- stepFrames(120 bpm, 44100) = 5513, NOT 5512 as the acceptance line says: 44100*60/120/4 = 5512.5 and iOS (and its pinned test) round half away from zero. Kept iOS-faithful (bar length = 16*5513 on both platforms; the bounce length matches StudioPattern.lengthMs within rounding).
- Android scheduling is pull-based: step N is at frame N*stepFrames from the pattern-start anchor in the scheduler's own render cursor, so there is no host-time start latency; the clock subtracts the sink's `latencyFrames()` so the highlight lands on what is audible. The pull itself arms the horizon (no 10 Hz tick); `armedSlotCount` is the test seam.
- Live step/loop edits also re-arm the edited row's already-armed hits from the next not-yet-rendered slot (iOS only edits the arrays, so changes are heard when the horizon reaches them, up to 4 bars later). Hits already sounding are not altered. BPM / span / retarget edits still apply on next Play (banner says so).
- Loop-bar count for the infinity looper is chosen by LONG-PRESS on the infinity button (iOS: context menu).
- Row-gain chip uses a DropdownMenu slider with the 3 s idle dismiss (iOS popover).
- The "Add to playlist or pocket..." list-row menu item is NOT ported (same follow-up as LoopsScreen).
- Bounce writes to the app-managed sequences root only (`wasUserFolder=false`), like the other STU packages; SAF user-root copy-out not done.
- `StudioRenderException` is not extended: bounce errors use `PatternBounceException` (EMPTY_PATTERN / WRITE_FAILED). The bounce does not take the StudioRender single-permit mutex (pure Kotlin mix + encode); span stretches DO go through `StudioRender.stretchBuffer`.
- Pattern playback stops on ON_STOP (no foreground service for Studio), when leaving the editor (ownership-gated), and when a sample/loop audition starts; starting a pattern pauses Now Playing, the sample audition and the loop audition.
- Files added beyond the owned list: `screens/producer/sequencer/SequencerController.kt`.
- Files touched outside the owned list (minimal/additive): `di/StudioGraph.kt` (lazy `patternEngine`, one-audible-owner hooks in the sample/loop focus lambdas, ON_STOP observer also stops the pattern, explicit `Lazy<T>` types to break an inference cycle), `studio/StudioSettings.kt` (`SEQUENCER_LIVE` pref), `screens/producer/ProducerScreen.kt` (Sequencer tab routes to SequencerScreen). StudioEngine/StudioStore/StudioRender untouched.
- Gradle needs more heap: run with `-Dorg.gradle.jvmargs=-Xmx3g -Pkotlin.daemon.jvmargs=-Xmx3g`.

## Device-only / unverified
- Emulator steps (seed 2 rows -> toggle steps -> Play: logcat `studio.pattern` lines, cursor advances, Stop parks cursor, infinity with 2 bars loops, Bounce writes pattern-<id>.m4a of lengthMs) NOT run (emulator is the integrator's). The UI (Compose) is compile-verified only: grid layout at compact width, long-press menus and the frame-sampled highlight need a visual pass.
- Timing tightness; audible result of `.interrupts`-style choke (no click-free fade on the cut, same as iOS); Oboe latency compensation of the highlight.

## Questions for Levi
- Live-edit latency: is "heard within a step" (re-arm) acceptable, or keep iOS's "next bar" strictness? (re-arm is a one-liner to remove in `PatternScheduler.rearmRowLocked`.)
- Should the pattern keep playing when the app is backgrounded (needs a foreground media service) or stop as now (same question as the loop audition)?
