state: implemented

# P2-PB-3 Sequencer extension seams II

Summary: QueueItem gains `plan: PlanTag?` / `djUserNext` (+ `pinned`, `pinnedCopy()`), excluded from equality. SequencerListener.onRowLandedNext(uid)
fires for every edit landing a row at index+1 (insertNext, move-to-next, drag-to-top, drop-before-next, random/remote insert at next). Edits pin moved/inserted
run rows and maintain the single next-up pick (setUserNext; spent when the row starts). `replaceUpcoming(Map<uid,QueueItem>, Set<uid>)`, `replaceableUpcomingRows`,
`appendRunRows`, `replaceUpcomingSegment` with the apply-time protection rules (never <= index, never plan==null/pinned, index+1 needs >= 30 s runway, pending rip only
for on-device/instant replacement), canonicalOrder slot kept, uid uniqueness enforced, preload re-armed. `repeatForcedOff` provider (default `pwr_` source prefix) +
`effectiveRepeatMode`; `setRepeatMode` inert while forced off; all playback logic obeys the effective mode; `SetlistSequencerControl.repeatMode` (forwarding player /
MediaSession) reports the effective mode and re-asserts it on a refused change; restore keeps `pwr_` ids (only `puzzle_` ghost rule). External-driver APIs:
`applyingExternal{}`, `play(..., atMs, startPaused)`, `jumpToUpcoming(uid, atMs)` (cue travels with the load), `insertUpcoming`, `silenceForController`,
`setHeldResumePosition`, `noteListenerPlayIntent` (+ userPlayIntentSeq/lastUserPlayIntent), `transportGate` + sealed `TransportRedirect` consulted by play, skipNext/Prev,
jumpToUpcoming/Played, playNow, resumeFromHold (SetPlaying(true)), startCurrent (LocalStart), pause/resume.

Tests: +43 JVM tests (ReplaceUpcomingPropertyTest 8, EffectiveRepeatTest 7, ExternalDriverApiTest 15, RowPlanPinPickTest 13). Total 6165 -> 6208, 0 failures.
`:app:testDebugUnitTest :app:assembleDebug` green (no manifest/gradle/proguard touched, so assembleRelease not run).

- [x] PlanTag.kt + QueueItem fields + SequencerHooks.onRowLandedNext
- [x] pinned/pick on edits, replaceUpcoming, appendRunRows
- [x] effective repeat + SequencerForwardingPlayer
- [x] external driver APIs + transportGate
- [x] snapshot row mapping (plan, djUserNext)
- [x] tests
- [x] build green

## Deviations / files touched outside owned list
- `playback/durable/SessionSnapshot.kt`: `row()` writes `plan`/`djUserNext`; `toQueueItems()` restores them (pick only on the row after current, legacy djPlaced mapped as on iOS). Additive.
- `playback/durable/SnapshotExtras.kt` (`overlay`): plan and djUserNext are now authoritative from the row instead of inherited by songId from the previous row
  (otherwise a spent pick / removed plan would be revived). Plan unknown keys, an explicit `false`, and legacy `djPlaced` (only while the pick is held) are still carried.
- `test/.../SessionSnapshotPassthroughTest.kt`: one assertion flipped (`assertNull(rebuilt.queue[0].plan)` -> `assertNotNull`), because plan now round-trips through QueueItem.
- `SequencerState` gained `repeatForcedOff` / `effectiveRepeatMode`. `state.repeatMode` stays the STICKY mode (what the session writer persists). UI/widget/Auto surfaces that
  read `state.repeatMode` should switch to `effectiveRepeatMode` (not done here: those files belong to other packages).
- Remote `applyingRemote` of the audit is named `applyingExternal`; existing `applyingCause` kept (applyingExternal wraps it with REMOTE + gate bypass).
- `QueueItem.pinned` is derived from `plan.pinned` (iOS has no separate field); a plan-less row is never "pinned" (it is already unreplaceable).
- Production wiring left to the consumers: `repeatForcedOff` default is the `pwr_` prefix; `djModeEnabled` provider (DJ pack) defaults false; `transportGate` is set by Remote.
  Routing MediaSession/widget/Auto/Assistant ▶/⏸ through `noteListenerPlayIntent` happens automatically for paths that reach the sequencer's PLAY/PAUSE reports; surfaces
  that bypass the sequencer should call it themselves (R8 follow-up).

## Questions for Levi
- none
