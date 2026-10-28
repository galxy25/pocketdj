state: implemented

# GM-3 Gem Collector engine + GameRunPlayer over the sequencer

Tests: 2497 total, 0 failed (`./gradlew :app:testDebugUnitTest :app:assembleDebug` green). New: CollectorsPuzzleEngineTest (45), GameRunPlayerContractTest (9).

- [x] playback/GameRunPlayer.kt: RunItem + GameRunPlayer (runningTag/isRunning/position, ownsRun, playRun, appendRun, skipNext, stopRun, filterResolvable)
- [x] playback/SequencerGameRunPlayer.kt: adapter over SetlistSequencer (play with PlayContext.game(tag,label), appendRows(runTag), ownership = running && capturedContext.contextId==tag), GamePreviewResolver (local rip/burn instant; AM-only via cached 30 s preview, chunks of 12, first chunk awaited, 4 s probe budget), GamePreviewRowResolver (FALLBACK rung, run-tagged rows only)
- [x] data/games/puzzle/CollectorsPuzzleEngine.kt: full state machine (start/countdown/cloud budget 2.5 s/tick order/watchdog/drift batch/top-up single-flight + round guard/assign/skip/filing hold+credit/endRound scoreboard/reset), CollectorsPuzzleEnv + PuzzleSettingsPersistence seams, StateFlow<PuzzleRoundState>
- [x] di/GamesGraph.kt: puzzleDecisions, gameRunPlayer (registers preview rung), puzzleEngine, env wiring to collections/favorites/history/rips/burns, settings in SharedPreferences `pdj-puzzle`
- [x] Tests: engine (iOS test names ported) + contract (fake + real sequencer via SequencerHarness)

## Notes / deviations
- Roadmap file list names SequencerGameRunPlayer (not Media3GameRunPlayer); no PlaybackController edits were needed because PB-1's sequencer already has appendRows/currentIndex.
- GameRunPlayer is synchronous/state-based (engine's tickOnce is sync): position/runningTag read the sequencer's published state.
- Watchdog parity: the start arm counts as card 0's attempt (as on iOS), so silence on card 0 is not re-armed.
- Songs the player cannot resolve are dropped from the round queue and remembered (droppedIds) so top-up never resamples them (extra vs iOS, prevents a retry loop). If every sampled song is unresolvable the start fails with 'No songs match these settings.'
- Preview probing is optimistic beyond the first 12 AM-only songs; a miss there is skipped by the sequencer at its turn.
- PB-8 NOTE: an Apple Music rung (Rung.APPLE_MUSIC) must skip rows with runTag != null, otherwise it would take game rows ahead of the preview fallback.
- Added test-only `tickerEnabled` seam on the engine.
- Touched outside owned files: none (test helpers FakeGameRunPlayer.kt, MsgAsserts.kt are new test files).
- Emulator steps not run (emulator owned by integrator). Device-only: AM preview resolution needs network.
- The engine has no screen yet; GM-4 consumes `GamesGraph.puzzleEngine`. Decision store sync entry not wired here.

## Questions for Levi
None.
