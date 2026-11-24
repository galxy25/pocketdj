state: reviewed

# P2-POC-8 Pocket run store

## Summary
- `PocketRunStore` (data/pockets/wheel): start (plan off-main via a compute dispatcher; prior = `PocketTuning.fold(allowBans=false)`; rows tagged `PlanTag`; plays through `pwr_<UUID>`; log `start run= moment= rows= fresh= bench= mix=`; failure returns false with "Not enough playable songs fit your pocket right now. ..."), 1 Hz `evaluate` (one bounded tail walk, verdicts only from History, bans from THIS run only, 10 s ownership grace = learn-only, held run does no work), debounced (1.5 s) re-plan + rescore every 5 completions via `replaceUpcoming`, W2 `rowsNeeded` trim/top-up (30 s backoff, stops at the 100th, never a 101st), `retarget` (for P2-POC-12), Mix seam (`playThroughMix` >= 10 loadable, `mixTag`), persistence to `pocketdj-pocket-run.json` (iOS keys, past[] capped 50, unknown keys ignored), `clearLocal`, `stop`, `runHistory`.
- Relaunch improvement over iOS: `resumeTrackingIfNeeded` re-derives prior + this run's bans from History (iOS leaves prior empty after a relaunch).
- `PocketRunPlayer` seam + `SequencerRunPlayer` adapter so the store is JVM-testable.
- `PocketTuning.verdicts(events, excludingRun, excludingEvent)` added (History -> verdicts).
- History stamp: `SetlistSequencer.pocketRunTagFor` -> `PlayContext.pocketRun` (requestContext), carried to the Exo path by a new `pdj.pocketRun` media extra (PlaybackContract/Controller/Service). AM path uses the request context directly.
- Up Next: "Re-tuned ✦" label (testTag `np-retuned`) driven by `runStore.retunedUids` (only rows that landed; older timer never clears a newer badge).
- `PocketsGraph.runStore` (main-thread scope), `wheelController.play` -> `runStore.start`, `resumeRun()` on `start()`, clear hook registered.

## Tests
37 new JVM tests (PocketRunStoreTest 27, PocketTuningTest 10). Full suite 6862 tests, 0 failures; `:app:testDebugUnitTest :app:assembleDebug` green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / files touched outside owned list
- SetlistSequencer.kt (additive `pocketRunTagFor` hook + requestContext), PlaybackContract.kt / PlaybackController.kt / PlaybackService.kt (`pdj.pocketRun` extra), DebugScreen.kt (new buttons "Pocket: run best / run status / run stop"; the existing "Pocket: build+start" still drives the In the Pocket game round, not re-pointed, to keep the game probes working), PocketsGraph.kt (shared touchpoint).
- SkipTracker.kt NOT modified: `currentEventId` is read from the existing tracker.
- `thumbsDown` seam is left empty in the graph (iOS never wires it either; Android has no lifetime thumbs-down song set outside RecFeedbackStore scopes).
- ActivityTracker / `noteActivity` (adapt to activity) not ported: belongs to P2-POC-11/12; `retarget(profile, mode)` and `retargetedMode` are in place for it.
- Mix path: the seams exist but `playThroughMix`/`mixOwnsRun` are not wired to MixFacade here (P2-POC-15 per design).
- Emulator verification (logcat `replan ... banned=[...]`, np-retuned) not run: emulator is owned by the integrator.

## Questions for Levi
- one-at-a-time.sh free-memory guard: ran with FIN_MIN_FREE_GB=5.

## Review

- start() Building wedge / old run killed early -> fixed (try/finally resets Building; previous run ended only after the new plan is non-empty). Test: aThrowingBuildDoesNotWedgeLaterStartsAndKeepsTheOldRun.
- flashRetuned wipes badge when nothing landed -> fixed (early return before touching state/generation). Test: aNoOpFlashKeepsThePreviousBadge.
- Debug "Pocket: build+start" -> fixed (now drives PocketRunStore.start; game probe relabelled "Pocket: game round").
- Duplicate RunSummary on start()/stop() over a finished run -> fixed (finished run is only cleared). Test: startingOverAFinishedRunDoesNotDuplicateItsSummary.

Tests: 6865 run, 0 failures (+3). assembleDebug OK.

fixes applied
