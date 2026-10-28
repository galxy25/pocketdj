state: implemented

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
