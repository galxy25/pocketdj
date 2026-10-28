state: implemented

# MIX-11 - Mix transport owner (MixSessionPlayer, focus, recovery, MixDiag)

- [x] MixDiag: 2000-line ring + `mix` lane forward; export to text file (Debug screen "Mix: export diag" -> cacheDir/diag/mixdiag-*.txt)
- [x] MixAudioFocus: MixFocusMachine (GAIN on start, transient loss -> remotePause + interruptionParked, regain resumes only parked, LOSS -> pauseBoth + abandon, noisy -> remotePause) + AndroidFocusSystem
- [x] MixRecovery: sink-routing park/unpark of Auto-DJ clocks, sink restart + voice re-kick, silent-playing 3-strike detector (re-kick x2, log + pause unless recording tap open)
- [x] MixSessionPlayer: SimpleBasePlayer TransportOwner; nowPlayingDeck card, rate = deck tempo (extrapolated), play/pause/next(5s)/previous(skipFadeSeconds), no heart; EngineMixTransportPort
- [x] di/MixGraph wiring (installTransportOwner) + tests (33 new; suite 2913, 0 failures)

## Design notes
- AudioTrackSink already rebuilds the track on route change and retries with backoff, and voices are decoder-driven, so "re-prime / resume at the frozen frame" is a re-kick of each playing deck's pull (voices keep their frame), not a seek.
- A deck hand-started during a focus park clears the latch (user took over; regain does nothing). That is my reading of "keeps recovery".
- Next/previous are offered only while an Auto-DJ is live (AutoDj.isMixing); card is not seekable.
- Becoming-noisy receiver registered once at engine build.

## Files touched outside owned set (minimal, additive)
- mix/engine/MixEngine.kt: `onSinkRouting`, `onHeartbeat` hooks; sink.onRoutingChanged wired in startEngineIfNeeded
- mix/engine/MixTick.kt: heartbeat() calls onHeartbeat
- screens/settings/DebugScreen.kt: "Mix: export diag" button
- engine diagSink now MixDiag.log (which still forwards to NPLog MIX lane)

## Device-only
Bluetooth route changes, phone-call focus, headset buttons, real lock screen. The MediaSession only swaps to the Mix when PlaybackService is running (as for the AM adapter); nothing starts the service for a Mix-only cold start.

## Questions for Levi
- Should starting a Mix deck with no PlaybackService running start the service (foreground notification)? Defaulted to no (same as AM adapter).
