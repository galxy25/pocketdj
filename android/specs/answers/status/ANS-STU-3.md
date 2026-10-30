state: reviewed

# ANS-STU-3 — Studio session owner + park/resume on transient focus loss

- [x] StudioSessionPlayer (engine "studio", SimpleBasePlayer TransportOwner) + StudioPlayerStateMap/StudioTransportPort
- [x] SessionSwitchboard.yieldMixToExo covers "studio"
- [x] LoopAudition park/resume (+ onAudible / onUserTransport hooks)
- [x] MultitrackPlayer park (arrangement + positionMs) / resume (fresh doc lookup)
- [x] InstrumentEngine replay park (events + replayPositionMs) / resume
- [x] StemPlayer (single + synced + routing) park/resume/dropInterruptionPark
- [x] StudioGraph: shared parkingFocus handle, coordinator registrations (loop, multitrack, instrument, demux), MediaController bind, background observer no longer stops the loop
- [x] Tests
- [x] Full gradle green (5301 tests, 0 failures; new tests added in this package)

## Notes / deviations
- Parked engines KEEP their focus request (stop paths take holdFocus / skip release) - otherwise AUDIOFOCUS_GAIN is never delivered. Any explicit user play/stop or permanent loss clears the park and releases focus.
- Multitrack master-record take cannot park: it ends instead.
- Instrument replay resume restarts the primary voice only; extra overdub-backing staffs were retired at park (engine owns them) - not resumed.
- Only the Loop audition claims the media session (per acceptance); other Studio voices still stop on app background.
- remotePlay on the studio card is a no-op (card exists only while the loop sounds).
- Touched nothing outside owned files except StemPlayer interface defaults (own file list) - none outside.

## Questions for Levi
None.

## Summary
Loop audition now owns the media session (engine "studio") and survives backgrounding; Loop, Multitrack, Instrument replay and Demux park on transient focus loss and resume on gain via one InterruptionCoordinator; permanent loss / user transport clears the park.

## Review

fixes applied

- MAJOR loop focus lambda self-pause (StudioGraph) -> fixed: all Studio focus lambdas call `pauseNowPlayingForStudio()`, which skips the NP pause when `SwitchboardOwner.engine == "studio"` (check runs on Main, FIFO-ordered before the loop's setOwner launch, removing the first-start race). Tests: `loopBStartedWhileLoopAPlaysKeepsPlayingWhenTheGatedNowPlayingPauseIsSkipped`, `nowPlayingPauseIsSkippedOnlyWhileStudioOwnsTheSession`.
- MAJOR park resigns session / card disappears -> fixed: a park no longer fires `onAudible(false)`; the card is reported for a parked loop (`StudioCard.parked`) as STATE_READY, playWhenReady kept, with `PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS` (ExoPlayer's own representation of transient loss; keeps the foreground service, unlike playWhenReady=false). Resign happens only on a real stop / clearParked / permanent loss / failed resume. New `onParkChanged` re-publishes the state. Tests: updated park test (no `audible=false` on park), `userStopWhileParkedResignsTheSession`.
- MINOR live notes survive transient loss -> fixed: instrument coordinator entry uses `isAudibleForPark` (replay or held notes) and `parkForInterruption()` (parks replay, always `allNotesOff`). Test `transientLossSilencesLivePlayedNotesEvenWithoutAReplay`.
- MINOR parkedReplay holds focus forever after live notes -> fixed: `ensureRunning` drops the park (and forgets "instrument" in the coordinator) when it makes a fresh focus request. Test `liveNotesDuringAParkDropTheParkSoFocusIsNotHeldForever`.
- MINOR multi-staff partial resume -> fixed via the finding's second option: a multi-staff replay is stopped (not parked) on interruption. Test `multiStaffReplayEndsOnInterruptionInsteadOfResumingPartially`.
- MINOR second transient loss during resume decode -> fixed: `isAudible` includes the in-flight resume; a re-park cancels the decode (generation bump) and stays parked. Test `secondTransientLossDuringResumeDecodeRepartsInsteadOfSounding`.
- NIT test count -> recorded: 5301 at the reviewed tip, 5309 now (0 failures). Emulator steps (Home with loop playing + `dumpsys media_session`; transient-gain park/resume) still NOT run: emulator owned by the integrator; they remain the verification gate.
