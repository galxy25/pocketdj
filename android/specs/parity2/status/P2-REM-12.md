state: implemented

# P2-REM-12 MixEngine sync seams for Mix Together

Summary: the Mix engine can be driven by remote events precisely and reports local gestures; solo Mix is unchanged.
- `MixSyncEngine.kt` (new): `Gesture` (+Cause user/system/engine), the `MixSyncEngine` interface, `SyncExtras` (loop/stem handle installed by `MixDeckExtras`), and pure helpers `MixSyncMath` (lead clamp 60 ms..2 s, early-fire by output latency, cue forward-shift, loop fold, nudge clamp 0.99..1.01, exact window), `SyncBoardFold` (whole-board fold over factory defaults) and `SyncSeed` (deck snapshot -> `MixSyncEvent`s).
- `MixRecordingHooks`: `gestureTap` beside `emit`/`emitLoad`, `applyingRemote` depth guard (no tap, no session-log record; `notePlayed` still counts, as iOS), `caused` (outermost non-user wins), `muted` (compound gestures tap once), restore guard.
- `MixEngine`: `syncPlay(deck, fromMs, atLocalMs)` (input-clock scheduled start = shared render clock, fired early by sink latency, floor 60 ms/cap 2 s, cue moved forward by gap x rate, loop cue folded into the existing window, fallback to start-now for stream-held / sink-down / unbuffered stems), `syncNudgeRate` (multiplies tempo, tick uses effective rate, cleared on load/eject), `syncSetLoop` (exact window via `LoopController.syncSet`), `syncSetControls` (diffed whole board, unlisted reset, lead, stems via `SyncExtras`), `syncSeedEvents`, `syncSessionActive` (durable session suspended, user's own mix parked and given back at end, or protected by `postSessionPersistHold` while the decks still sound; a parked launch restore is refused during a session), `setAutoDjBlocked(reason)` (-> `MixTogetherBlock`), `silenceForRemoteController` (system cause; suspends a running Auto-DJ), `audiblePlayhead`, `outputLatencySeconds`, `deckReady`, `loopWindowMs`.
- `MixDeckSessionStore.suspendWrites(on)`: save/saveDebounced/updatePosition/clear are no-ops while on; a pending debounce lands first; `flush` still writes the held (pre-session) snapshot.

Tests: `MixSyncEngineTest` 52 new tests (full suite 7707 green, 0 failures; `:app:assembleDebug` green). Manifest/gradle/proguard untouched, so no assembleRelease.

## Files touched outside the owned list (all minimal and additive)
- `AutoDj.kt` (shared touchpoint): `onAutoBlocked` now restores the user's Auto setting when the block lifts (iOS `autoEnabledBeforeBlock`; REM-6 left this open); `remotePause` is now `override` of a new default `AutoDjHooks.remotePause()`.
- `EngineCore.kt`: `AutoDjHooks.remotePause()` default; `EngineCore.tapGesture` / `gestureMuted` defaults.
- `LoopController.kt`: one `loop` / `loopUnits` gesture tap with the exact window (internal re-seek muted), `syncSet(...)`.
- `StemController.kt` (`MixDeckExtras` init only): installs `engine.syncExtras`.
- `MixTick.kt`: playhead advance uses `effectiveRate` (tempo x nudge).
- `di/MixGraph.kt`: `silenceForRemoteController()` now delegates to the engine's.

## Deviations / notes
- Output latency = `AudioSink.latencyFrames()` (AudioTrack buffer size); a finer `AudioTrack.getTimestamp` estimate can be plugged in through `MixEngine.outputLatencyProvider` (device-only tuning; REM-13 may wire it).
- Eject taps `eject`; startAutoMix's take-over reset taps `resetDeck` (as iOS); Auto is blocked in a session anyway.
- Wrapping the app's system transport entry points (lock screen / headset / Auto / Assistant) and engine-internal retire paths in `engine.caused(SYSTEM|ENGINE)` is left to P2-REM-13 (the API and the stamping are done; only `silenceForRemoteController` is wrapped here).
- Loop gestures are tapped but, as before, not written to the session log (Android never logged loops).

## Questions for Levi
- None.
