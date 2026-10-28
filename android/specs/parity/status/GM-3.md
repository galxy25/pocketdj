state: reviewed

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

## Review
fixes applied. Tests: 2507 total, 0 failed (was 2497; +8 contract, +2 engine).

- MAJOR ownership read only from sequencer state -> fixed. SetlistSequencer.noteForeignPlay()/foreignPlayCount, called by PlaybackController.setQueueAndPlay (album queue, non-member single) and the full-track AM start; SequencerGameRunPlayer latches a takeover (foreign count moved or a different session running), reports isRunning=true / foreign runningTag, refuses skip/append/stop. Tests drive the abandonRun and retirePendingStart paths.
- MAJOR preview rung shadowed by CloudRowResolver -> fixed. CloudRowResolver returns null for rows with runTag; ladder test with ripServerConfigured=true.
- MAJOR startRound wedges on cancellation -> fixed. Cancellation before RUNNING resets to IDLE; added single-flight startRoundDetached() on the engine scope. Tests for both.
- MINOR probe budget -> fixed. Unanswered ids are unknown and optimistic (no more dropping the first chunk); AppleMusicPreviewResolver fetch is cancellable (enqueue + cancel on coroutine cancel), so the budget really bounds Start.
- MINOR warmAhead -> fixed. Cursor-relative window of 12 re-warmed as the sequencer index moves; per-session negative cache.
- MINOR puzzle-decisions sync -> fixed. SyncEntry("puzzle-decisions") with onPulled = reloadFromDisk() (union-by-id merge).
- MINOR restore ghost tag -> fixed in SetlistSequencer.restoreHeld: `puzzle_` sourceSetlistId, context runTag/contextId and row runTags are stripped. Test added.
- NIT ledger row -> outstanding for the integrator: docs/ARCHITECTURE-ANDROID.md status ledger row for GM-3 is not updated here.
