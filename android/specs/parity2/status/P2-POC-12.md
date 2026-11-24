state: implemented

# P2-POC-12 Motion settings section + adapt pocket runs to walking & running

- [x] ActivityTracker (pure, 180 s sustain, low-confidence ignored, once-per-mode via shouldRetarget)
- [x] PocketRunStore seams (adaptToActivity, startActivityUpdates, stopActivityUpdates, profileForMode), noteActivity, ticker re-check, retarget through existing replaceUpcoming path; sequencer path only (viaMix skipped); stopped on endRun/clearLocal
- [x] ListeningMotionSection: "Notice walking & running" (prominent disclosure before runtime request), "Adapt pocket runs..." toggle, "Motion access" status (Allowed/Not asked yet/Denied + Open Settings), footer per listening-pockets state
- [x] PocketsGraph wiring (section registered at order 667, run store seams)
- [x] testDebugUnitTest + assembleDebug green: 7464 tests, 0 failures; ActivityTrackerTest adds 8 (manifest/gradle untouched, no release build needed)

## Notes / deviations
- Files touched outside owned: MotionTimelineStore (additive `onEnter` live ENTER feed), PocketsGraph (wiring + settingsSections), SettingsSections.kt (id constant only).
- Android delivers one ENTER per change (no continuous samples), so the 180 s check also runs on the run ticker. Failed retarget attempts retry at most once a minute.
- Run start seeds the tracker with the activity already under way, clock starting at run start (no instant re-target on play).
- Opt-in stays on if permission is denied (iOS parity); status row shows Denied + Open Settings.
- Section hidden when the rec engine is off (same as places & trips).
- one-at-a-time.sh refused `--no-quiesce-fin` (LM Studio model resident); ran with default quiesce.
- No store-level retarget test (PocketRunStoreTest's FakePlayer is private to that file, not owned); logic covered by pure tests.

## Questions for Levi
- None.
