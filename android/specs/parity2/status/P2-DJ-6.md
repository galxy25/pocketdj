state: reviewed

# P2-DJ-6: DJ Mode session shell

- [x] ParityFlags.DJ_MODE = false (P2-DJ-8 flips it)
- [x] DjModeController (SequencerListener + SessionExtra "djMode"), RemoteSessionProbe (default Inactive), DjEngineHooks seam
- [x] DjModeWiring (new file, playback/dj) installed from PlaybackGraph after Mix Mode; binds seq.djModeEnabled
- [x] DjChip.kt: NpDjModeSwitch (np-dj-mode, left of Mix Mode), NpDjModeMenuItem (np-menu-dj-mode), DjChipText
- [x] NowPlayingDspPanel (switch + DJ words on the Mix chip), RecordPlayer + MiniPlayerBar menus
- [x] DjModeControllerTest: 17 tests

Tests: 6842 total, 0 failures; DjModeControllerTest adds 17.

## Deviations / files outside the owned list
- New file playback/dj/DjModeWiring.kt (production assembly); additive edits to PlaybackGraph (djMode lazy + install), RecordPlayer.kt (one menu line).
- Mix Mode off => DJ off is done by observing NpMixCoordinator.state (not editing the coordinator).
- Suspended words ("DJ — paused · Remote session"/"· Mix tab") live in DjChipText; DjMode.Indicator chipText (iOS "SharePlay") left untouched.
- Engine work (replan, engage, arm, level, indicator) is behind DjEngineHooks (DjModeWiring.engineHooks); P2-DJ-8/10 bind it.
- The Remote probe's flow is read at install; P2-REM-5 should set controller.remote before install (or call onSuspensionInputsChanged).

## Questions for Levi
None.

## Review
- MINOR DjModeController.setDjMode engaged while held -> fixed (applyOnTrackStart only when not suspended and !held; onResumedFromHold engages). Test toggleOnWhileHeldDoesNotEngageUntilResume.
- MINOR Mix Mode off ordering / restored DJ-on+Mix-off -> fixed (NpMixCoordinator.onModeSwitched hook fires before the re-plan and wiring calls onMixModeChanged; onResumedFromHold clears DJ if Mix Mode is off; flow collector kept as backstop). Test heldRestoreDjOnWithMixOffTurnsDjOffOnFirstPlay.
- NIT Remote probe captured at install -> fixed (DjModeWiring.bindRemote re-launches the collector and re-evaluates suspension).

Tests: 6844 total, 0 failures (+2).

fixes applied
