state: merged

# GM-4 Gem Collector screens

- [x] PuzzleComponents.kt: PuzzleScreenLogic (poolCountText, startEnabled, timerText, parseYear, target cap/toggle, labels) + segmented/check-row composables
- [x] PuzzleGenreScreen.kt, CollectorsPuzzleScreen.kt (setup w/ pinned Start bar, sampling, countdown, running, summary, Add-to sheet multi-filing via noteFiled/endFiling)
- [x] GamesRoutes.kt: in-tab open of the puzzle (rememberSaveable flag + BackHandler), no nav route
- [x] PuzzleScreenLogicTest (6 tests). Suite 2765 run, 0 failed; assembleDebug OK.

## Notes / deviations
- GamesGraph.kt not modified (engine/persistence already wired by GM-3); draft settings persist via engine.updateSettings on every change.
- Screen opens as an in-tab overlay in GamesRoute (GamesRoutes.kt, GM-1 file) rather than a NavHost route; ShellNavigation untouched.
- Bias picker labels shortened for phone width (Recent / Not lately / Non-favs).
- Emulator steps not run.

## Questions for Levi
None.

## Review
- MAJOR sheet state lost on teardown -> fixed: Add-to sheet now driven by engine state.filingSongId (onDismiss -> endFiling); test abandonedFilingIsVisibleInStateAndRecoverable added
- MAJOR ledger row -> fixed: GM-4 row set to PARTIAL (emulator steps not run)
- MINOR .kotlin crash log -> fixed: git rm --cached, android/.kotlin/ gitignored
- MINOR GamesRoutes cross-package edit -> acknowledged, rejected as change: in-tab overlay kept (sheet-loss root cause fixed separately); a games/puzzle NavHost route is a follow-up for ShellNavigation owner
- MINOR poolStats on main -> fixed: wrapped in Dispatchers.Default
- MINOR New Pocket silent no-op -> fixed: Create disabled until store loaded
- MINOR RunningView not scrollable -> fixed: verticalScroll
- MINOR test baseline/lifecycle -> fixed: baseline 2765 -> 2766 run, 0 failed (+1 lifecycle test)
- NIT bias labels -> not changed (disclosed phone-width deviation)

fixes applied
