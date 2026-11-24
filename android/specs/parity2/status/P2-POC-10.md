state: implemented

# P2-POC-10: Moment card + History Pockets Wheel|List + List Play = derived run

All checklist items done. `:app:testDebugUnitTest :app:assembleDebug` green: 7271 JVM tests, 0 failures
(new: PocketMomentCardTest 8, PocketsTabGateTest +4 = 12). No manifest/gradle/proguard changes, so no assembleRelease run.

## Summary
- ParityFlags.POCKET_WHEEL flipped to true.
- PocketsTabGate.tabVisible gained `historyNonEmpty` (default false, so old callers/tests are unchanged). HistoryScreen
  feeds it from PlayHistoryStore and the wheel snapshot (only while POCKET_WHEEL).
- PocketsTabScreen: Wheel|List SegmentedButton (default Wheel, stored in SharedPreferences "pdj" key
  pdj.history.pockets.segment); List hidden when answered && !on (declined). Finished-run card "Pocket finished ·
  N played · X % skipped" with "another pocket" (dismissFinished + playBest) and Dismiss.
- PocketMomentCard + pure PocketCardText: bars, artists/genres/tempo/era, place chips, stats, play (long-press opens
  Clear menu), Clear button while that cell plays, Why this colour, past-runs strip. ModalBottomSheet < 600 dp, side pane
  (inside PocketWheelScreen's wide layout) >= 600 dp. The legend (pocket-legend-*) already lived in PocketWheelScreen.
- ListeningPocketDetailScreen: Play -> PocketRunStore.start(PocketProfile.fromListening) with the build / success /
  failure notes (pocket-run-note); "Play the original songs" (pocket-replay) keeps the old exact-list playback.

## Deviations / files outside owned set
- ListeningPocketsScreen.kt (hosts PocketsTabGate): added the `historyNonEmpty` param. Minimal, additive.
- PocketWheelScreen.kt not edited (its `card` hook was sufficient).
- iOS has no finished-run card UI (only the store's dismissFinished), so the card text/layout is my design.
- Emulator steps not run (emulator is the integrator's).

## Questions for Levi
- None.
