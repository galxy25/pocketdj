state: reviewed

# ANS-SHELL-1 status (Q98 minimal background graph)
- [x] di/StartupPlan.kt: StartTier/StartStep/StartupPlan/StartupLedger (pure, idempotent) + NpHeartbeatGate
- [x] AppGraph: init blocks replaced by tiered ledger; CORE on every construction; startPlayback(); startInteractive()
- [x] PlaybackService.onCreate -> startPlayback(); MainActivity.onCreate -> startInteractive(); workers get CORE only
- [x] 1 Hz session tick only while a sequencer run exists (collectLatest on isRunning)
- [x] npdsp 4 Hz heartbeat flow-driven (engaged || run exists || Mix running); Mix flag settled on the way down
- [x] Widget owner poll replaced by SessionSwitchboard.addListener (additive; service replacing onChange cannot drop it); WidgetBridge started in PLAYBACK tier (ShellGraph.startWidgets)
- [x] Recs flush/release feed (startRecs) only in INTERACTIVE tier
- [x] Tests: BackgroundStartTest (7). Full suite 5669 tests, 0 failures; assembleDebug green.

## Tiers
CORE: endpoints install, browse session, secret migration, favorite seam, burn reconcile, intent sink.
PLAYBACK: sequencer wire+tick, mix orphans, npdsp, studio wire, play stats, jukebox bootstrap, widgets.
INTERACTIVE: recs.

## Files outside owned list touched
- playback/session/SessionSwitchboard.kt (additive addListener/fire), MainActivity.kt (one line), ShellGraph.kt (startWidgets; deepLinkHandlers no longer starts widgets).
- BrowseGraphRecsWiringTest not changed (startRecs body unchanged).

## Notes
- A widget command arriving while no service/UI is up queues (WidgetCommandBus.executor null) as before; executor now installs on PLAYBACK start rather than at every cold start.
- Manifest/proguard untouched; assembleRelease not run.
- Emulator steps (jobscheduler run, logcat) not run: emulator owned by integrator.

## Questions for Levi
- none

## Review
- MAJOR INTENT_SINK in CORE: fixed (moved to INTERACTIVE; worker start no longer builds `features`). Test: CORE plan excludes it + source-scan test that no CORE branch of runStartStep references features/playback/mix/games/studio/browse/shell graphs.
- MINOR tests only check enum: fixed in part (new seam scan test over runStartStep; plan assertions updated). A full coroutine test of the collectLatest gates was not added (would need graph refactor): rejected for scope.
- MINOR RECS tier: fixed (RECS moved to PLAYBACK so recEnabledMirror seeds in car-only sessions).
- NIT WidgetBridge owner seed: fixed (listener registered first, then seed).

fixes applied
