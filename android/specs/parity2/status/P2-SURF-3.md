state: implemented

Glance widget 👍/👎 pair + self-contained verdict commands + effective repeat.

- [x] snapshot/inputs/sync carry recVerdict + recScope, fed from NowPlayingFeedback.currentTarget (+ RecFeedbackStore revision flow)
- [x] WidgetCommand.scope (additive); verdicts never expire; verdicts lacking songId/scope dropped at drain (iOS parity)
- [x] WidgetBridge applies VERDICT_* to the command's own songId+scope via NowPlayingFeedback.recordFor(Surface.WIDGET)
- [x] 👍/👎 in Medium/Large (ic_widget_thumb_up/down); Medium drops Previous + shrinks glyphs to fit
- [x] repeat glyph uses effectiveRepeatMode
- [x] optimistic snapshot update on offline verdict tap (NowPlayingSnapshot.afterVerdictTap)
- [x] tests: WidgetVerdictTest (9 new); :app:testDebugUnitTest + assembleDebug + assembleRelease green; 7466 tests, 0 failures

## Files touched outside owned set
- data/recs/NowPlayingFeedback.kt: additive `recordFor(songId, scope, verdict, surface)`; `record` delegates to it.
- res/drawable/ic_widget_thumb_up.xml, ic_widget_thumb_down.xml (new).
- test PendingWidgetCommandsTest: existing verdict enqueue now carries scope (scope-less verdicts are dropped by design).

## Deviations
- one-at-a-time.sh refused with --no-quiesce-fin (LM Studio models loaded); ran with default quiesce.
- Medium omits Previous when thumbs show (iOS keeps five glyphs); width would overflow otherwise.

## Questions for Levi
None.
