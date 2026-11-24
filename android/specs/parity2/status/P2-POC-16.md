state: implemented

# P2-POC-16 Pocket surfaces (Android Auto, shortcut, deep link, Assistant phrase)

## Checklist
- [x] AutoPockets (+ AutoPocketsSource): "▶ Pocket for now" (`pocketwheel:now`, subtitle `<collection> · Tue 8 AM`) and browsable "Pockets right now" (`pocketwheel:list`, top 5 moments +-1 h, playable `pocketwheel:m:<token>`), above the For You tiles
- [x] AutoId.PocketNow/PocketList/PocketMoment codec; AutoBrowseTree `pockets` param + `hasForYouTab`
- [x] AutoLibraryCallback: select -> `AutoPlayer.playPocketForNow/playPocketMoment`; failure = AutoPlayException (toast + car error, never an empty player); wheel refreshed on root fetch / For You tab fetch, re-notify only when the rows' signature changed
- [x] AppAutoPlayer / AppAutoPocketsSource / PlaybackService wiring (car session => `refresh(carOverride=true)` => carPlay mode)
- [x] ShellActions.playPocketForNow(car)/playPocketMoment(key) (veto + ensureReady, same door as UI), `NoPocketFits` ("Not enough playable songs fit your pocket right now. ..."), `pocketNowLinkSeam`, snackbar "Playing your pocket: <caption>."
- [x] `pocketdj://pocket/now` (DeepLink.PocketNow, seam `pocketNow`), static shortcut "Play my pocket" (STATIC_COUNT 3 -> 4, JVM test keeps XML and count in sync)
- [x] MediaSearchResolver step 1: "my pocket" / "pocket for now" / "something that fits" (+ variants) -> PocketForNow, before collection names (focus Any/Playlist only)
- [x] Tests: AutoPocketsTest (21), ShellActionsPocketTest (8)

## Tests
29 new JVM tests. Full suite 7053 tests, 0 failures (`:app:testDebugUnitTest :app:assembleDebug :app:assembleRelease` green; release run because shortcuts.xml/strings changed).

## Deviations / files touched outside owned list
- PocketWheelController.kt: `refresh(carOverride: Boolean = false)` (additive; Auto sessions count as car-connected, which `UI_MODE_TYPE_CAR` alone does not detect for phone projection).
- ShellGraph.kt (`pocketWheel` provider + `pocketNow` seam), PlaybackService.kt, AppAutoServices.kt (AppAutoPlayer + AppAutoPocketsSource), AutoBrowseDebug.kt (`pocketwheel*` picks resolve under For You), DeepLinkParser/Dispatcher, strings (`shortcut_strings.xml`).
- The "Pockets right now" folder is hidden when no moment is within +-1 h; the For You tab now exists when either tiles or pocket rows do.
- Emulator steps (autoDump / adb VIEW pocketdj://pocket/now) not run: emulator owned by the integrator.
- one-at-a-time.sh refused `--no-quiesce-fin` (7 GB LM Studio models resident); ran with the default quiesce, which restored fin-agentd afterwards.

## Questions for Levi
- None.
