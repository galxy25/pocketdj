state: in-progress

# P2-PB-2 Sequencer extension seams I

- [x] AdvanceCause split (NATURAL_END / AUTO_SKIP / STALL_HOP) + TransitionCause (AdvanceCause.kt)
- [x] SequencerHooks bus + listener, StartInterceptor / AdvanceInterceptor interfaces (SequencerHooks.kt)
- [x] SetlistSequencer: transitionSeq / lastUserTransitionSeq / queueGeneration, hooks fired, completeClaimedStart, advanceWithoutLoad
- [x] SessionExtras registry + SessionWriter wiring + held restore delivery
- [x] ParityFlags.kt
- [ ] SequencerHooksTest, InterceptorTest, SessionExtras tests
- [ ] testDebugUnitTest + assembleDebug

Touched outside owned files: ResumptionProvider.kt (SessionRestorer passes `extras = SnapshotExtras.of(snap)` to restoreHeld),
SequencerState.kt (additive queueGeneration/transitionSeq), PlaybackGraph.kt (touchpoint: SessionWriter gets seq.sessionExtras).
