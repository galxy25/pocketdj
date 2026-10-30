state: merged

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
Tests: 13 added (CleanOnlySkipTest 5, CleanOnlyFreezeTest 3, HeldRestoreTest +3, PlaybackSessionStoreTest +1, PolicyEditionDeciderTest +1). Full suite 5151 tests, 0 failures; assembleDebug green.

## Questions for Levi
None.

## Review
fixes applied

1. Live-insert stamping diverges from iOS: FIXED. Inserts (append/insertNext/insertAt/random/playNow) now stamp ONLY in a clean-only run (stampInsert); global Prefer-explicit stays play()-time (iOS parity). playNow of a skipped row is refused with notice "Explicit - skipped in this clean-only set". Tests added.
2. Skipped rows leak into prefetch/presign/widget/jukebox: FIXED. SequencerState.upcomingPlayable used by stem-lock prefetch (MixGraph), presign ahead (PlaybackController x2), WidgetBridge, JukeboxRepository. Mix jukebox source (MixJukeboxSource) reads the Mix deck's own autoUpcoming, not sequencer rows: not applicable.
3. Restore re-decide gated only on catalog: FIXED for the async inputs. PlaybackGraph ready = catalog loaded AND edition setting emitted once. Collections load synchronously in CollectionsStore init, so that half of the finding is REJECTED (already loaded when read).
4. Blind restore never re-decides: FIXED. Restorer records unlocked rows lacking resolveId; SetlistSequencer.resumeFromHold re-decides them (before the first write) once the decider is ready. Test added.
5. Files outside owned list: FLAGGED FOR INTEGRATOR. Besides CollectionsModels.kt and QueuePlan.kt: di/PlaybackGraph.kt (hot file, also ANS-PB-3/PB-5/PB-7/SHELL-1; one `ready =` line + setting-loaded flag), playback/sequencer/EditionDecider.kt (isReady()), data/edition/PolicyEditionDecider.kt (ready param), SequencerState.kt (upcomingPlayable), plus one-line consumers in MixGraph, PlaybackController, WidgetBridge, JukeboxRepository. All additive.
6. NIT resolveId on every row: REJECTED. Absent must keep meaning "old/iOS file, re-decide"; a schema marker is more risk than ~0.8 MB on a rare 26k-row queue. Revisit if snapshot size shows up in profiling.
7. NIT all-skipped notice: FIXED ("No clean versions in this set"). skippedEntryCount left as is.
8. NIT test count: FIXED (5151 after +4 tests). realize()->freezeCleanOnly integration test not added.
