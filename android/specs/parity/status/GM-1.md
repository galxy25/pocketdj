state: reviewed

# GM-1 Games tab + Scoreboard store + GamesGraph

- [x] GameKind (frozen tokens, free labels), GamesPrefs
- [x] GameScoreboardModels (RunRecord/Tombstone/Document, lenient ScoreboardCodec, tombstone union)
- [x] GameScoreboardStore (record/trim 500, best/recent, inThePocketStats, tombstoned delete/deleteAll, id-based reloadFromDisk, clear, seedFixture)
- [x] GamesGraph: scoreboard lazy, reset hook, sync entry `game-scores`, debug seed (`-e pdj.seedGames true`, boolean or string extra)
- [x] GamesScreen (3 cards, scoreboard, long-press + overflow menus, saveable confirm dialog) + GamesRoute
- [x] Tests: GameScoreboardStoreTest (16), ScoreboardMergeTest (3). Suite: 2208 tests, 0 failures.

## Notes / deviations
- Touched outside owned files: shell/ShellNavigation.kt (Games composable now GamesRoute(graph) instead of the placeholder; minimal).
- PlaySource.GAME / PlayContext.game and PocketDjDestination tests (sevenDestinations, games route) already existed from earlier packages; not duplicated.
- Run/tombstone ids are uppercase UUID strings (iOS wire shape); invalid-UUID rows are dropped as lenient failures.
- Store saves synchronously (small atomic write); UI deletes run on Dispatchers.IO.
- Card taps for Gem Collector / In the Pocket are inert until their packages pass onOpenPuzzle/onOpenInThePocket to GamesRoute. Music with Friends New/Join buttons and session rows belong to a later package.
- Nothing yet calls reloadFromDisk after a sync pull (no sync engine consumer of SyncEntry exists yet).

## Questions for Levi
None.

## Review
fixes applied
- Games store IO on main (MINOR) -> fixed: GamesGraph init warms `scoreboard` on appScope/IO.
- No reload callback on sync entry (MINOR) -> fixed: `SyncEntry.onPulled` added (shell/FeatureModule.kt, default null); GamesGraph passes `scoreboard.reloadFromDisk()`. The sync engine package must invoke it after a pull. Test: SyncEntryHookTest.
- Seed wipes real history (MINOR) -> fixed: replacing seed only with `-e pdj.useFixture true`; otherwise polite no-op.
- Delete cancelled by UI lifecycle (NIT) -> fixed: GamesRoute passes `graph.appScope` as deleteScope.
- ShellNavigation.kt shared touchpoint (NIT) -> acknowledged: Games placeholder removal in the listOf block; Mix package will conflict there, merge order to be planned by integrator.
- Ledger row + emulator steps (NIT) -> deferred to orchestrator/integrator (emulator not used here).
- Tests: 2210 run, 0 failures (was 2208); assembleDebug OK.
