state: reviewed

# ANS-PB-1 - Editions on restore + clean-only skip

- [x] SessionRow.resolveId (+ cleanOnlySkip) optional; restore uses persisted id; absent -> decider re-run (SessionRestorer)
- [x] QueueItem.cleanOnlySkip stamped by PolicyEditionDecider (cleanOnly && EditionPolicy.isSkipped)
- [x] playCurrent: CLEAN_ONLY_EXPLICIT unplayable BEFORE resolve/load/start-window; advance UNPLAYABLE_HERE
- [x] NextRowPreloader never targets a skipped row
- [x] Realize freezes clean-only (SetlistTrack.variant, drop skipped, stamp clean) + QueuePlan carries it locked
- [x] Tests

## Notes / files outside owned list (minimal, additive)
- data/collections/CollectionsModels.kt: SetlistTrack.variant (iOS field already exists on the wire)
- playback/QueuePlan.kt: QueueEntry.variant -> locked QueueItem
- Extra Android-only snapshot key `cleanOnlySkip` (iOS ignores) so a restored held deck cannot play a skipped explicit row.
- skipPrevious onto a skipped row bounces forward (advance UNPLAYABLE_HERE), not further back.
- Frozen (locked) rows in a realized set never get cleanOnlySkip: skipped songs were dropped at realize.

## Summary
Snapshot rows persist resolveId (+cleanOnlySkip); restore trusts it, else re-runs the EditionDecider under the origin's clean-only flag. Clean-only explicit rows with no clean cut are stamped cleanOnlySkip, never resolved/loaded/preloaded, and hopped via UNPLAYABLE_HERE without removal. Realize freezes clean-only (iOS parity).
Tests: 13 added (CleanOnlySkipTest 5, CleanOnlyFreezeTest 3, HeldRestoreTest +3, PlaybackSessionStoreTest +1, PolicyEditionDeciderTest +1). Full suite 5144 tests, 0 failures; assembleDebug green.

## Questions for Levi
None.
