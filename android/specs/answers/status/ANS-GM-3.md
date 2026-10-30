state: reviewed

# ANS-GM-3 - Games deep links

- [x] DeepLink.Game(GameLink) + GameLink enum (Puzzle, InThePocket) in DeepLinkParser; `pocketdj://games/puzzle|inthepocket` (lenient tokens), bare `pocketdj://games` opens the Games tab
- [x] DeepLinkSeams.game seam + DeepLinkDispatcher.pendingGame/takePendingGame fallback (parks and posts Games tab)
- [x] GamesGraph.gameLinks (GameLinkHandler, defined in GamesRoutes.kt) installs the seam; posts Tab(Games) + pendingGame
- [x] GamesRoute LaunchedEffect consumes pendingGame and opens the puzzle / In the Pocket overlay
- [x] No new ShellRoute subtype; manifest unchanged (scheme-only filter already matches)
- [x] Tests: 8 new (DeepLinkParserTest +3, DeepLinkDispatcherTest +2, GamesDeepLinkTest 3); suite 5604 tests, 0 failures; assembleDebug green

Notes: build needs -Pkotlin.daemon.jvmargs=-Xmx4g; one transient compiler backend failure under load, passed on rerun. Emulator step not run (shared emulator).
## Questions for Levi
None.

## Review
- MINOR GamesRoutes effect untested -> fixed: extracted pure `applyGameLink(game) -> GameLinkState` (used by the LaunchedEffect) + 2 tests; effect already sits above the overlay early returns. Emulator cold/warm step NOT run (shared emulator; integrator owns it).
- NIT missing tokens -> fixed: collectorspuzzle, gem-collector, gemcollector (+ test).
- NIT dispatcher fallback double-post -> rejected (optional; harmless defence, left as is).
- NIT imports -> fixed (imports sorted, FQNs replaced in GameLinkHandler).

fixes applied. Suite 5607 tests, 0 failures (was 5604); assembleDebug green.
