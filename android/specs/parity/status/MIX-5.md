state: merged

# MIX-5 MixEngine core: decks, load/seek/transport, EQ, FX rack, Vol/crossfader, cue, lead/sync, VU, 10 Hz tick, session hooks, durable persistence

- [x] MixUiState.kt: DeckState / MixUiState (StateFlow), DeckPositions (polled playhead holder, outside the flow), NowPlayingRule
- [x] EngineCore.kt: EngineCore interface for sub-controllers, AutoDjHooks (MIX-9 seam), seams (MixTrackResolver, MixSourceOpener, VoiceRunner, TickDriver), LoadWindow window math
- [x] DeckController.kt: per-deck Voice + [startFrame,endFrame) window, true playhead
- [x] MixRecordingHooks.kt: recorder emit, onSongPlayed once per load, onDeckTrackEnded (high-water, first reason wins)
- [x] MixPersistence.kt: snapshot build / restored slots / atEnd / parked summary (pure)
- [x] MixTick.kt: 10 Hz tick (dt clamp 0.5 s, loop fold hook, stream-held hook, end retire unless auto runs, watchdog ~1/s, heartbeat line 1/s, position persistence), CoroutineTickDriver
- [x] MixEngine.kt: load/loadFile/loadSource, play/pause/togglePlay/playBoth/pauseBoth/toggleAll/resumeMasterPaused, restart/resetDeck/clearDeck/ejectAll, seek, rate/pitch/EQ/volume/crossfader (+non-recording applyCrossfader), cue, lead/sync/phaseAlign, FX rack + effect-keyed shims, meters, truePlayhead, nowPlayingDeck, persist (immediate/debounced), persistPositions, parked restore + materialize
- [x] di/MixGraph.kt: app-scoped `mixEngine` lazy (AudioTrackSink, Mp3Decoder, VoicePump, BurnStoreTrackResolver, recorder = mixSessions, deck store)
- [x] Tests: MixEngineTransportTest (27), MixEnginePersistenceTest (16), CrossfaderSyncTest (14)

## Tests
JVM suite 1620 -> 1677 (+57), 0 failures; `assembleDebug` green.

## Deviations / notes
- Hooks instead of the later packages: loop (MIX-8), stems (MIX-8), streaming (MIX-10), Auto-DJ (MIX-9), remote lock-screen verbs (MIX-11), mod tick (MIX-17) are NOT implemented; the engine exposes `autoDj: AutoDjHooks`, `streamHeldProvider`, `loopWindowProvider`, `onLoopInvalidated`, `onStemsReset`, `streamLoad`, `onRestoreDeckExtras`, `onAudioStarted`, `onNowPlayingChanged`, `keepEngineAlive`. DeckState already carries stem/loop fields so they round-trip through the snapshot.
- The test file names follow the roadmap; the unit_tests list names (MixEngineTest / MixEngineSessionTest / MixEngineRecorderTest) are covered inside those three files.
- Cue/PFL setters record no session event and are not persisted (iOS behaviour: transient monitoring state), so "every setter emits an event" applies to everything except cue.
- Playhead is the iOS wall-clock accumulator (dt*rate); `truePlayhead` reads the Voice's own frame counter (honors seek + loop folding). No silent-run position taint (iOS P1-9) and no silent-playing detector: those belong with the MIX-11 robustness lane.
- The sink is created lazily on the first real transport (a restore is inert). It is not stopped when idle; `pauseEngineIfIdle()` is provided for the audio-owner arbiter (MIX-11).
- Slot strength sent to the render snapshot is the stored strength (modulation overlay is MIX-17).
- `restorePersistedMixIfIdle()` / `materializePendingRestoreIfNeeded()` are NOT called automatically: the launch task / Mix screen (MIX-14) must call them (AppGraph untouched).
- No files touched outside owned set (only di/MixGraph.kt, which is owned). Emulator step (force-stop + relaunch, mixdiag heartbeat) not run (no emulator per instructions).
- Device-only: audible tempo/pitch quality and cue routing.

## Questions for Levi
- None.

## Review
- MAJOR DeckController closes decoder under live pump -> fixed: `VoicePump.stopAndJoin()` (runner closer joins before source close), pump loop catches decoder faults; test VoicePumpJoinTest (threaded, strict source).
- MAJOR restore never parked / empty engine clears store -> fixed: `materializePendingRestoreIfNeeded` parks from the store when unsettled (honours setlist-live); `persist()`/`persistPositions()` never clear/write before the restore is settled; tests freshEngineMaterializesStraightFromTheStore..., anUnrestoredEmptyEngineSetterNeverDeletesTheSavedMix.
- MINOR load() disk IO on main -> fixed: `loadOffload` seam (IO resolve/open/window, Main commit, per-deck generation guard); wired in MixGraph; test offMainLoadCommitsLater...
- MINOR ledger row -> fixed (PARTIAL).
- MINOR silent-run position taint -> fixed: persistPositions writes last trusted playhead after 3 s of running with no audible signal.
- NIT heartbeat gated on deck playing -> fixed (also when mixWantsAudio/autoMixing).
- NIT wav/opener refusal invisible -> fixed: opener and load refusals log diag lines (decoder-by-extension deferred).

fixes applied. JVM suite 1677 -> 1682, 0 failures; assembleDebug green.
