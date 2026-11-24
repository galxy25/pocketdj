state: merged

# P2-POC-9 status: Pocket wheel UI

## Summary
- `WheelLayout.kt`: pure port of iOS WheelLayout (hole 0.30, focus 1.8, weekend gap 0.025, ring gap 0.006, max 3 slivers, 20% floor, polar hit-test), plus `WheelAccessibility` (spoken value, recurring hours, hour stepping) and `PocketWheelPaint` (opacity/desaturation/dimming).
- `PocketWheelActions.kt`: actions data class (iOS shape) + `rememberPocketWheelActions(PocketsGraph)` bound to PocketWheelController + PocketRunStore (NonCancellable starts).
- `PocketWheelScreen.kt`: `PocketWheelScreen` (stateless) + `PocketWheelHost` (graph-bound): Canvas of 7 rings x 24h, mode slivers, fisheye weekday picker, now needle, scrub with Popup callout, mode chips (All/Car/Trip/Run/Walk/Mix/Browse/Home, Material icons), legend with highlight, centre play button (best-match colour ring, done/total arc, pause while running, long-press / secondary-click menu: Clear this pocket, Start a new pocket for now, Not this? alternatives), empty state, TalkBack node per ring with next/previous-hour custom actions, testTags `pocket-wheel-*`, reduce-motion via ANIMATOR_DURATION_SCALE, two-pane at >= 600dp.
- `ParityFlags.POCKET_WHEEL = false`; Debug > "Wheel preview" toggle hosts the wheel inline (ignores the flag).
- Tests: 15 new in WheelLayoutTest (full suite 7039 JVM tests, 0 failures).

## Checklist
- [x] WheelLayout + tests
- [x] PocketWheelActions
- [x] PocketWheelScreen
- [x] ParityFlags + Debug preview
- [x] testDebugUnitTest + assembleDebug green (assembleRelease not run: no manifest/gradle/proguard/library change)

## Deviations / notes
- Touched outside owned files: ParityFlags.kt and DebugScreen.kt (shared touchpoints, additive).
- The screen does not scroll itself; the host (History / Debug) scrolls. The moment card is a `card` slot (P2-POC-10); without it a small selected-cell summary shows.
- Canvas radius follows iOS: side = min(width-32dp, 520dp), layout radius = side/2 - 22dp label margin.
- Fisheye focus change is not animated (iOS animation is also a snap on a Canvas input).
- Builds ran with one-at-a-time.sh WITHOUT --no-quiesce-fin: the wrapper refuses to start with 14GB of LM Studio models loaded while fin-agentd runs; default quiesce (restores after) is the documented fix and Levi's standing policy.
- Mode chip order follows the acceptance text (Car, Trip, Run, Walk, Mix, Browse, Home), not the sliver precedence order.

## Questions for Levi
- None.

## Review
- Gesture consumes scroll (MINOR) -> fixed: down no longer consumed; moves consumed only over a cell; a consumed/cancelled pointer aborts without onSelect.
- Double refresh on main (MINOR) -> fixed: loop uses refreshIfStale, snapshot effect skips first composition, both run on Dispatchers.Default.
- Touch targets / reduce motion (MINOR) -> fixed: chips min 48dp; reduce-motion read each composition. Radius kept at iOS-matching layout (documented deviation).
- Unused revision collection (NIT) -> fixed (removed).

fixes applied
