state: reviewed

# MIX-16 Integrations: Jukebox <-> Mix, MixPlayOutcomeBridge, MixFacadeImpl
- [x] MixPlayOutcomeBridge (deck-keyed, async event resolution, verdict table)
- [x] MixJukeboxSource + MixJukeboxPort + MixJukeboxSeam; JukeboxRepository prefers the live mix (snapshot, placement, pending drain)
- [x] MixFacadeImpl + MixGraph wiring (bridge hooks, jukebox seam, facade; ports shared with mixViewModel)
- [x] Tests (37 new: bridge 19, source 10, facade 7, repo 1), specs/mix.md
- Suite: 4204 tests, 0 failures; assembleDebug green.

## Deviations / notes
- docs/ARCHITECTURE-ANDROID.md NOT edited (integrator owns it, per instructions): open question #1 resolve + ledger row + new files are left for the integrator.
- Touched outside owned files (minimal): di/ShellGraph.kt (one `.also { it.mixFacade = ... }`), screens/mix/MixViewModel.kt (MixAutoStarter single-crate empty guard, iOS parity).
- Event-id resolution is polled (store records async off the bus) instead of iOS's synchronous record() return.
- JukeboxGraph untouched: repository finds the Mix via process-wide MixJukeboxSeam set in MixGraph.init.
- Jukebox `nowPlaying.positionMs` is sent for the mix (iOS sends nil); guests interpolate from it.
- Emulator steps (broker payload via logcat, History tag) not run: emulator owned by integrator.

## Questions for Levi
- None.

## Review
fixes applied
- Snapshot gate (MINOR) -> fixed: MixJukeboxPort.isRunning (engine.isRunning); snapshot()/isLive use isRunning || autoMixing; place() stays autoMixing-only. Tests: handDrivenMixBroadcastsButIsNotAnAutoQueueOwner.
- Un-ripped match (MINOR) -> fixed (partial): decide() offers any placement match to a live auto mix; requestBurn burns a ripped song or records burnWhenRipped (AppGraph drains it) for an un-ripped one. Android has no stream-through-rip trigger, documented in the ARCHITECTURE ledger row.
- Exception falls back to sequencer (MINOR) -> fixed: once the auto mix owns the setlist an error surfaces in transientError, never the ExoPlayer path; requestBurn is launched on appScope (not awaited under runLock). Test: throwingBurnKickDoesNotUnparkTheRequest.
- drainPending drops ended-mix inserts (MINOR) -> fixed: returns Landed items; repository routes them via applyPlacement when the sequencer is running. Test: parkedInsertIsHandedBackWhenTheMixEnded.
- History context (MINOR) -> fixed: contextLabel = auto sourceLabel ?: mixSessions.currentName; new contextId = mixSessions.currentId. Test: mixSessionIdRidesTheContext.
- ARCHITECTURE-ANDROID.md (MINOR) -> fixed: Mix ledger row updated (PARTIAL, device-only notes, new files). Open question #1 was already marked RESOLVED. Emulator acceptance still not run (integrator owns the emulator).
- NIT: removed unused playedTracks; kick() after a successful mix place. Not done: catalog length for streaming-deck durationMs, onAirBuffering in the payload (iOS parity unverified).
- Suite: 4206 tests, 0 failures; assembleDebug green.
