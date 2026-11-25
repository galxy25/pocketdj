state: merged

# P2-REM-13 Mix Together live: anchored starts, drift correction, held decks, section + banner

Two Android devices can now mix the same two decks together over a Remote session.

## What shipped
- `remote/mix/MixSync.kt` (new): the engine-facing driver over the existing `MixSyncCore` (iOS `MixSync` port).
  - Local gestures -> proposals (owned decks only; a gesture on a deck you don't own is undone from the mirror on the next tick).
  - Anchored starts via `syncPlay`: `startLead` 300 ms (60 ms min / 2 s max). The owner proposes play only once its deck can sound (deferred play), the host holds a start for the owner's ready report <= 4 s (core).
  - Drift: threshold 40 ms + both clocks' uncertainty + 20 ms, 2 consecutive strikes, < 250 ms -> <= 1 % nudge for exactly offset/1 % ms, else re-seek, 4 s cooldown measured from the nudge end, beats > 1.5 s stale ignored, looping decks compare PHASE (`MixSyncDrift.offsetMs`).
  - 2 s owner heartbeat; every device folds the beat into its mirror; the owner's own heartbeat anchor is folded into its own mirror (`MixSyncCore.noteLocalAnchor`, additive).
  - System causes stay local: a SYSTEM pause HELD the deck silent (no repair/beat/drift) until the system resumes it or Rejoin; any own play brings every held deck back; ENGINE-cause stops are ignored.
  - Readiness reports (`mix.ready`), "isn't available on this device" (deck left empty/silent), `unavailableDevices`.
  - Cue/PFL, meter, recording and session log stay local (engine seams from P2-REM-12); the saved mix is not overwritten (`syncSessionActive`).
  - `MixEnginePort`: production `MixSyncDeckPort` over `MixEngine`; remote loads use the synchronous `loadNow` under `applyingRemote` so an async commit can never tap as a user load.
  - `MixTogetherInstaller`: hello `caps:["mix"]` (only when `ParityFlags.MIX_TOGETHER`), routes `mix.*`, live-mix election activity probe, 250 ms tick while a session is live; lazy driver build.
- `ParityFlags.MIX_TOGETHER` added and flipped to true.
- `screens/remote/MixTogetherSection.kt`: Remote "Mix Together" section (start/end, DJs, your deck, footer copy) + `MixTogetherCopy` (pure copy).
- `screens/mix/MixTogetherBanner.kt`: "Mixing together" banner on the Mix screen: who's in, your deck, Auto-off reason, status, "Paused on this device" + Rejoin, per-deck owner + Claim/Release, "'X' isn't available on this device - this deck stays silent here." / "Silent on ...".
- System transport wrapped as SYSTEM-cause (`EngineMixTransportPort.remotePlay/remotePause/remoteSkip/pauseBoth`): lock screen, headset, Auto, Assistant, audio-focus loss.

## Tests
`MixSyncDriftTest`: 34 new JVM tests (drift/nudge/re-seek/strikes/cooldown/stale beat/threshold widening, loop phase + exact window + late joiner order, held decks + Rejoin, deferred play + host hold timeout, unavailable song, seed + reconcile, far-future/min-lead clamps, coalescing, ownership revert, UI state + copy, installer caps). Full suite: see summary below; `:app:testDebugUnitTest :app:assembleDebug` green at the tip. Manifest/gradle/proguard/libraries untouched, so no assembleRelease.

## Files touched outside the owned list (all minimal and additive)
- `remote/mix/MixSyncCore.kt`: `noteLocalAnchor` (owner folds its own heartbeat into its mirror).
- `di/RemoteGraph.kt`: `mixSync`/`mixSyncIfBuilt` lazy driver + `MixTogetherInstaller.install` in `wire()`.
- `mix/service/MixSessionPlayer.kt` (`EngineMixTransportPort`): system transports under `engine.caused(SYSTEM)`.
- `screens/remote/RemoteScreen.kt`: optional `mixTogether` slot in `RemoteContent`/`ActiveSession`; `screens/mix/MixScreen.kt`: `MixTogetherBannerHost(graph)`.
- `ParityFlags.kt`.

## Deviations / notes
- Deck controls are not greyed read-only for non-owned decks (iOS `mixReadOnly`); a stray gesture is reverted from the mirror on the next tick, and the banner shows per-deck ownership. Greying needs DeckView edits (not owned).
- Engine-internal stops are only ignored when stamped ENGINE; the engine's own retire/watchdog paths are not yet wrapped in `caused(ENGINE)` (an owner's end-of-track pause is proposed as a normal pause, as on iOS).
- Output latency uses `AudioSink.latencyFrames` (REM-12); a finer `AudioTrack.getTimestamp` estimate is device-only tuning (`MixEngine.outputLatencyProvider`).
- Drift tests run over an in-memory FIFO net (as `MixSyncCoreTest`), not `LoopbackHub`; the driver never touches the transport directly.
- Opening a Remote session builds the Mix graph once (the driver needs the engine to answer snapshots and report readiness).
- Two-phone 40 ms sync target is device-only (not measured).

## Questions for Levi
- None.

## Review
- MAJOR engine-internal stops not tagged ENGINE -> fixed: `MixTick` (end-of-track retire, zero-length pause, watchdog recover) and `StreamDecks` (stream-failed drop eject) now run under `engine.caused(Gesture.Cause.ENGINE)`. Stream hold/stall pauses go through `controller.pause()` only (no `setPlaying`, so no tap). Tests: `MixSyncEngineTest` end-of-track retire and zero-length pause tap as ENGINE; driver-level ENGINE-pause-proposes-nothing already existed in `MixSyncDriftTest`. (Engine-initiated `pauseBoth`/`stopAutoMix` are user-driven here, left as USER.)
- MINOR non-owned deck gestures only repaired on tick -> fixed: repair is posted immediately from the tap; `DeckArea` takes `readOnlyDecks` (dimmed, taps swallowed) fed from `MixSyncUi.controllable` via `rememberMixReadOnlyDecks`.
- MINOR stale state after `onActive(false)` -> fixed: `localSong`, `lastBeatAt`, `lastDriftFixAt` cleared. Test: `endingTheMixClearsTheLocalSongAndDriftBookkeeping`. (driftFixCount/nudgeCount are public diagnostics counters, left.)

fixes applied. Tests: 7871 -> 7874, all green; assembleDebug green.
