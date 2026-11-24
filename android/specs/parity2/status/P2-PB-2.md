state: merged

# P2-PB-2 Sequencer extension seams I

Summary: SetlistSequencer now exposes the seams every parity-2 feature uses, all behaviour-neutral with nothing registered.
- AdvanceCause.AUTO split into NATURAL_END / AUTO_SKIP / STALL_HOP (+ `isAuto`, `toTransitionCause()`); new TransitionCause {USER, NATURAL_END, AUTO_SKIP, STALL_HOP, UNPLAYABLE, REMOTE}.
- `sequencer.hooks` (SequencerHooks): ordered listeners, events delivered in emission order even when a listener re-enters, exceptions logged + isolated.
  Events: onSessionStarted/Ended(STOPPED|REPLACED|FINISHED), onTrackStarted(TrackStart), onTransition, onUserTransport, onQueueChanged, onFirstAudio, onHeld, onResumedFromHold.
- transitionSeq / lastUserTransitionSeq / queueGeneration (also in SequencerState); `[session] transition cause=.. seq=..` and `[session] queueGen=..` log lines go to the `session` lane (PocketDJ.session).
- `applyingCause(cause){}` tags every transition inside (REMOTE for Remote; a REMOTE transport is not reported as user intent) - the base PB-3's applyingExternal builds on.
- StartInterceptor (priority-ordered, asked after the in-place replay check and before resolve/load) + `completeClaimedStart(gen, path, backend, emitHistory, fresh)`.
- AdvanceInterceptor (offered on a natural end after repeat logic) + `advanceWithoutLoad(cause, path, backend, rendering)` = advanceToNext minus PlayerPort.load: gate/breaker, wrap/finish, repeat counter reset, ONE History play (PlayEventBus.PlayStarted), natural-end verdict counted once, meter, hooks, no load.
- SessionExtras registry (typed keys npMixMode/fxLock/djMode over the P2-DATA-1 DTOs): SessionWriter writes registered features' values, `notifyChanged()` persists at once (never while held/idle), held restore delivers values HELD via `restoreHeld(..., extras=)` (late registrants get them too until first play/stop).
- ParityFlags.kt created (empty object + table; packages add their own `const val`).

- [x] all sub-steps; testDebugUnitTest + assembleDebug green. Total JVM tests now: 5941 (0 failures). New: SequencerHooksTest 15, InterceptorTest 15, SessionExtrasTest 6 (36 added).

Files touched outside the owned list (minimal, additive): playback/durable/ResumptionProvider.kt (SessionRestorer passes `extras = SnapshotExtras.of(snap)` to restoreHeld), playback/sequencer/SequencerState.kt (+queueGeneration, +transitionSeq), di/PlaybackGraph.kt (touchpoint: `sessionExtras = seq.sessionExtras`), new test playback/durable/SessionExtrasTest.kt.

Deviations / notes:
- AdvanceCause keeps its name (enum extended) rather than being replaced by TransitionCause; TransitionCause is a separate enum.
- onTrackStarted `fresh` = new track start (not a repeat pass / in-place replay / mid-song resume).
- A restore fires onSessionStarted then onHeld (session-scoped features reset, then receive stored values); `adoptForeign` therefore also reports a session start.
- SessionExtra.write() returning null means "leave stored value" (not clear); features that are off write `enabled=false`.
- PB-3 owns onRowLandedNext, applyingExternal, queue row fields (not done here).
- assembleRelease not run (no manifest/gradle/proguard/library change).

## Questions for Levi
None.

## Review
- MINOR UserTransport PAUSE/SEEK never fired on real input -> fixed: SequencerControl.noteUserTransport (SetlistSequencer.reportUserTransport); SequencerForwardingPlayer fires PAUSE, SEEK (seekTo both overloads, not the internal rekick), and PLAY on the plain ExoPlayer resume, only while a run exists. Passthroughs delegate to the same method. Tests: SequencerForwardingPlayerTest (2 new).
- MINOR persistExtras skipped while held -> fixed: SessionWriter allows held; PlaybackSessionStore.updateExtras rewrites the loaded (not-yet-adopted) snapshot with only extras changed, position/offset kept. Test: SessionExtrasTest.toggleWhileHeld_persistsExtrasKeepingStoredPosition.
- NIT AdvanceInterceptor not offered on preload roll -> documented in SequencerHooks (no behaviour change).
- NIT queueEdited events while idle -> fixed: generation bump, onQueueChanged and EDIT only while running.

fixes applied. Tests 5941 -> 5944, 0 failures, assembleDebug green.
