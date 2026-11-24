state: in-progress

# P2-PB-3 Sequencer extension seams II

- [ ] PlanTag.kt + QueueItem fields (plan, djUserNext, pinned) + SequencerHooks.onRowLandedNext
- [ ] SetlistSequencer: pinned on edits, setUserNext/landed-next, replaceUpcoming, appendRunRows
- [ ] effective repeat (repeatForcedOff) + SequencerForwardingPlayer
- [ ] external driver APIs (applyingExternal, play(atMs,startPaused), jumpToUpcoming(uid,atMs), insertUpcoming, silenceForController, noteListenerPlayIntent, transportGate)
- [ ] snapshot row mapping plan/djUserNext (SessionSnapshot.kt touch)
- [ ] tests: ReplaceUpcomingPropertyTest, EffectiveRepeatTest, ExternalDriverApiTest
- [ ] build green

## Deviations / files touched outside owned list
