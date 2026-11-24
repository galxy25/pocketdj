state: merged

Glance widget 👍/👎 pair + self-contained verdict commands + effective repeat.

- [x] snapshot/inputs/sync carry recVerdict + recScope, fed from NowPlayingFeedback.currentTarget (+ RecFeedbackStore revision flow)
- [x] WidgetCommand.scope (additive); verdicts never expire; verdicts lacking songId/scope dropped at drain (iOS parity)
- [x] WidgetBridge applies VERDICT_* to the command's own songId+scope via NowPlayingFeedback.recordFor(Surface.WIDGET)
- [x] 👍/👎 in Medium/Large (ic_widget_thumb_up/down); Medium drops Previous + shrinks glyphs to fit
- [x] repeat glyph uses effectiveRepeatMode
- [x] optimistic snapshot update on offline verdict tap (NowPlayingSnapshot.afterVerdictTap)
- [x] tests: WidgetVerdictTest (9 new); :app:testDebugUnitTest + assembleDebug + assembleRelease green; 7468 tests, 0 failures

## Files touched outside owned set
- data/recs/NowPlayingFeedback.kt: additive `recordFor(songId, scope, verdict, surface)`; `record` delegates to it.
- res/drawable/ic_widget_thumb_up.xml, ic_widget_thumb_down.xml (new).
- test PendingWidgetCommandsTest: existing verdict enqueue now carries scope (scope-less verdicts are dropped by design).

## Deviations
- one-at-a-time.sh refused with --no-quiesce-fin (LM Studio models loaded); ran with default quiesce.
- Medium keeps Previous; with thumbs the heart yields and glyphs shrink to 32dp (five glyphs like iOS).
- Bridge waits up to 10s for the catalog before recording a queued verdict (taste weights).

## Questions for Levi
None.

## Review
- MINOR WidgetBridge verdict catalog wait (10s) -> fixed: wait only while catalog Idle/Loading with no error (0 when failed/errored/ready-empty), capped at 2s; drain runs verdicts after transport commands (`WidgetVerdicts.transportFirst`). Tests: catalogWaitIsSkippedWhenItWillNotLoad, drainRunsVerdictsAfterTransportCommands.
- MINOR widget thumbs gated on lazy NowPlayingFeedback -> fixed: recRev builds the store off-main (IO) once the sequencer is running, and wakes on sequencer start instead of a 3s poll tick.
- NIT KDoc placement / duplicate heart helpers / test budget -> fixed: KDoc moved, shared `heartVisible`, `WidgetSizes` owns ROOT_PAD/MEDIUM_COVER/MEDIUM_GAP and usable widths used by the test (composable dp literals unchanged).

fixes applied. testDebugUnitTest + assembleDebug green; 7470 tests (+2), 0 failures.
