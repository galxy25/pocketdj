state: implemented

# P2-POC-12 Motion settings section + adapt pocket runs to walking & running

- [x] ActivityTracker (pure, 180 s sustain, low-confidence ignored, once-per-mode via shouldRetarget)
- [x] PocketRunStore seams (adaptToActivity, startActivityUpdates, stopActivityUpdates, profileForMode), noteActivity, ticker re-check, retarget through existing replaceUpcoming path; sequencer path only (viaMix skipped); stopped on endRun/clearLocal
- [x] ListeningMotionSection: "Notice walking & running" (prominent disclosure before runtime request), "Adapt pocket runs..." toggle, "Motion access" status (Allowed/Not asked yet/Denied + Open Settings), footer per listening-pockets state
- [x] PocketsGraph wiring (section registered at order 667, run store seams)
- [x] testDebugUnitTest + assembleDebug green: 7469 tests, 0 failures; adds ActivityTrackerTest 10 + PocketRunStoreTest 3 (EXIT clears the sustain clock; adapt toggle followed mid-run) (manifest/gradle untouched, no release build needed)

## Notes / deviations
- Files touched outside owned: MotionTimelineStore (additive `onEnter` live ENTER feed), PocketsGraph (wiring + settingsSections), SettingsSections.kt (id constant only).
- Android delivers one ENTER per change (no continuous samples), so the 180 s check also runs on the run ticker. Failed retarget attempts retry at most once a minute.
- Run start seeds the tracker with the activity already under way, clock starting at run start (no instant re-target on play).
- Opt-in stays on if permission is denied (iOS parity); status row shows Denied + Open Settings.
- Section hidden when the rec engine is off (same as places & trips).
- one-at-a-time.sh refused `--no-quiesce-fin` (LM Studio model resident); ran with default quiesce.

## Questions for Levi
- None.

## Review
- beginActivityUpdates double-call (PocketRunStore) -> fixed: returns early when the feed is already on; test beginningTheFeedTwiceKeepsTheSustainClock
- Single-slot MotionTimelineStore hooks (PocketsGraph) -> fixed: stop only clears callbacks this graph installed (identity check)
- Motion toggle hidden when rec engine off while opt-in stays on (ListeningMotionSection) -> fixed: section stays visible while the opt-in is enabled. ON_RESUME already refreshes the status.
- NIT isEnabled volatility -> rejected: ListeningMotionStore.isEnabled is already @Volatile

fixes applied. Tests: 7470, 0 failures; assembleDebug green.
