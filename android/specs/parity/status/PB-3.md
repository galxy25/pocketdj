state: reviewed

# PB-3 - Zero dead air: rip-on-demand in runs, runway, watchdogs, stall hop, cascade breaker, rip window, live backstop, supervisor, DeadAirMeter, pause discriminator

Tests: 1742 total, 0 failed, 0 skipped (`./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip). +122 new tests over the 1620 baseline of feat/android-parity (counted from app/build/test-results).

- [x] health/PlaybackRunway (RunwayLock + PowerRunwayLock partial wake lock, 25 s cap, idempotent end, `[runway] begin/end held=…s reason=…`)
- [x] health/StartWatchdog (8 s re-kick, 20 s escalate), ResolveStallHop (+ResolveStallTimer, 6 s, lookahead 50, on-device > instant, defer-not-drop), LiveBackstop (length + 45 s, listener-paused time excluded)
- [x] health/AutoAdvanceCascadeBreaker (3 x <5 s), PlaybackRipWindow (ahead 10, heard 30 s, evict/keep/endSession), PauseDiscriminator (Media3 playWhenReady reasons + suppression), EngineProbe
- [x] health/PlaybackSupervisor: pure Core (ported verbatim incl. strings and timings) + Shell (1 Hz, only while a run exists, feeds the meter, abandons transitions on pause/interruption/held)
- [x] health/DeadAirMeter: iOS Day/Pair/Document JSON, `filesDir/pocketdj-dead-air.json`, 60 d prune, 30 s save throttle, `[deadair] gap=…` and `day=… active=…s dead=…s ratio=…%` lines character-identical, flush via PlaybackGraph.flushables (background)
- [x] sequencer/CloudRowResolver (RIP_ON_DEMAND rung -> `RipOnDemandSource`, pdj-resolve://song/<id>)
- [x] session/ResolvingSongDataSource: RipOnDemandResolver (POST /rip -> durable | live HLS | error), RipOnDemandSession (one in-flight resolution per song, cancelled on skip), Media3 `ResolvingDataSource.Resolver`
- [x] SetlistSequencer: start window (runway + first audio + dead-air transition), start watchdog, resolve stall hop, cascade breaker (halt/pausedByCascade/playbackNotice, play retries row, user transports reset), live (`noteLive`, waitingForLive, backstop), rip window hooks, audible sampler (1 Hz), supervisor hooks (`supervisorRetryInPlace/Escalate`), `onFirstAudio`, `noteSourceResolved`
- [x] PlaybackController: CloudRowResolver registered; Media3Port loads the placeholder item immediately, watcher swaps in live HLS; engine probe, first-audio / playWhenReady / suppression feeds; placeholder load errors skip the presign retry
- [x] PlaybackService: ExoPlayer built with `DefaultMediaSourceFactory(ResolvingDataSource(DefaultDataSource))`
- [x] PlaybackGraph: DeadAirMeter, supervisor Shell (starts/stops from `sequencer.state.isRunning`), runway lock, flushable
- [x] Tests: PlaybackSupervisorTest (Core table + Shell), CascadeBreakerTest, RipWindowTest, DeadAirMeterTest, StartWatchdogTest (start watchdog / stall timer + hop choice / live backstop on virtual time), PauseDiscriminatorTest, CloudRowResolverTest (ladder, uri, POST /rip orchestration, session), plus SequencerHealthTest (sequencer integration)

## Deviations / files touched outside the owned list
- AppGraph NOT edited (roadmap text said "val deadAirMeter / supervisor in AppGraph"): they live on `PlaybackGraph` per decision D3 (AppGraph already calls `playbackGraph.wire()`).
- `playback/PlaybackController.kt` (not in the owned list): registers the CloudRowResolver, builds the RipOnDemandSession + EngineProbe, Media3Port rip-on-demand branch, listener feeds. `playback/sequencer/SequencerState.kt`: additive `waitingForLive`, `pausedByCascade`. New `health/EngineProbe.kt`. New test file `sequencer/SequencerHealthTest.kt`.
- Cascade breaker, start watchdog and the audible sampler are ARMED BY ATTACHING an `EngineProbe` (`sequencer.engine`). The controller always attaches one; the PB-1/PB-2 queue-semantics tests do not, so a harness that never produces audio is not misread as a cascade. The PB-1 `failureLapComplete` interim guard stays (repeat-ALL full lap).
- The sequencer's default log sink stripped the doubled lane prefix (`[playback] [playback] …`): DiagLog already adds `[category]`, so `removePrefix("[playback] ")` in the default sink only (tests still see the bracketed line).
- Live swap: the placeholder item is replaced with `setMediaItems(live)` (same mediaId). The service's History gate emits a PLAYLIST_CHANGED PlayStarted for it; PlayHistoryStore's 30 s same-song window absorbs the duplicate (device-verify).
- A "Next" affordance for waitingForLive is the existing skip; the deck UI (PB-6) reads `SequencerState.waitingForLive`/`pausedByCascade`/`playbackNotice`.
- Settings ▸ Debug "Playback dead air" readout: not built here (`DeadAirMeter.summaryLine()` is the data); belongs with the Debug screen work.
- Foreground-service lifetime during a long rip wait relies on Media3 keeping the service foreground for a BUFFERING item with playWhenReady=true; no `setForegroundServiceTimeoutMs` call (device-verify).
- Apple Music lane: probe lane is LOCAL/IDLE only (PB-8 adds APPLE_MUSIC; the Core already handles it detector-only). Not emulator/device verified (emulator not used).

## Questions for Levi
- None blocking. Defaulted: a rip-on-demand wait is capped at 10 minutes before the row is failed (then the cascade/advance rules apply).

## Review

fixes applied

- MAJOR cascade-halt ▶ -> fixed: `SequencerControl.isPausedByCascade`; `SequencerForwardingPlayer.play()` routes a halted run to `startCurrent()` before the idle check (test: playOnCascadeHaltedDeckWithLoadedItemRetriesTheRow).
- MAJOR live-swap for resolveId != id -> fixed: `watchRipOnDemand` compares the placeholder's mediaId (`item.id`) while the session stays keyed by resolveId; `noteLive`/`noteSourceResolved` already use `matches`. No controller-level unit test (Media3Port is not fakeable here); covered by review of the one-line compare.
- MINOR loader-thread begin/cancel -> fixed: `RipOnDemandSession.join()` only joins an existing resolution (IOException if absent); `begin`/cancel-others stay on the Main-thread port (test: session_loaderThreadOnlyJoins_neverStartsOrCancelsOthers). A failed resolve now leaves nothing to re-POST on ExoPlayer load retries. Custom LoadErrorHandlingPolicy not added (retries are now cheap and do not hit the server).
- MINOR supervisor vs 10-min wait -> fixed: `SetlistSequencer.ripWaitProbe` (wired to `RipOnDemandSession.isResolving()`) keeps `isStartPending` true while the placeholder is still resolving (test: ripWait_keepsStartPendingPastTheRunwayCap).
- MINOR wake lock -> fixed: `ExoPlayer.Builder.setWakeMode(C.WAKE_MODE_NETWORK)` (WAKE_LOCK permission already declared).
- MINOR PlaybackController touchpoint -> PARTIAL: not extracted (risk/size); flagged here as a shared touchpoint for PB-4..PB-8 (`Media3Port.load`, `watchRipOnDemand`, `onPlayerError` `pdj-resolve` branch must survive merges). Ledger-row acceptance remains open by instruction.
- NIT retry re-resolve -> fixed: each rip-on-demand load cancels the song's cached resolution first, so retry-in-place re-POSTs fresh. presigned-url preference, `playbackRipAllowed` wiring and start-stall log fields -> not done (optional; `playbackRipAllowed` kept, it is test-covered).

Tests: 1742 -> 1745, 0 failures; assembleDebug OK.
