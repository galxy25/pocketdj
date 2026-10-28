state: implemented

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
