state: in-progress

# ANS-STU-3 — Studio session owner + park/resume on transient focus loss

- [x] StudioSessionPlayer (engine "studio", SimpleBasePlayer TransportOwner) + StudioPlayerStateMap/StudioTransportPort
- [x] SessionSwitchboard.yieldMixToExo covers "studio"
- [x] LoopAudition park/resume (+ onAudible / onUserTransport hooks)
- [x] MultitrackPlayer park (arrangement + positionMs) / resume (fresh doc lookup)
- [x] InstrumentEngine replay park (events + replayPositionMs) / resume
- [x] StemPlayer (single + synced + routing) park/resume/dropInterruptionPark
- [x] StudioGraph: shared parkingFocus handle, coordinator registrations (loop, multitrack, instrument, demux), MediaController bind, background observer no longer stops the loop
- [x] Tests
- [ ] Full gradle green, final commit

## Notes / deviations
- Parked engines KEEP their focus request (stop paths take holdFocus / skip release) - otherwise AUDIOFOCUS_GAIN is never delivered. Any explicit user play/stop or permanent loss clears the park and releases focus.
- Multitrack master-record take cannot park: it ends instead.
- Instrument replay resume restarts the primary voice only; extra overdub-backing staffs were retired at park (engine owns them) - not resumed.
- Only the Loop audition claims the media session (per acceptance); other Studio voices still stop on app background.
- remotePlay on the studio card is a no-op (card exists only while the loop sounds).
- Touched nothing outside owned files except StemPlayer interface defaults (own file list) - none outside.

## Questions for Levi
None.
