state: reviewed

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

## Review
fixes applied

- MAJOR silent-playing used voice intent -> FIXED. RecoveryPort now carries tap signal age (`tapAgeSeconds(true)`), loop, gain, crossfader factor, all-stems-muted; suspect = playing, not held, not looping, gain>0.01, crossfader open, not stem-muted, audio left, mix running >3 s AND sigAge >3 s (or never); 3 strikes then log + pause unless recording. Re-kick only touches IDLE/UNDERRUN voices (also resolves the scheduled-start NIT). Tests: MixRecoveryTest drives the sigAge path (silent, never-signal, audible clears, young mix, recording, each expected-silence gate).
- MAJOR no service/notification on Mix-only start -> FIXED. MixGraph binds a MediaController on first Mix audio (starts PlaybackService); PlaybackService seeds its MediaSession from `board.sessionPlayer(forwarding)` (one-line shared touchpoint in playback/PlaybackService.kt). Not device-verified (emulator off-limits); media3 foreground promotion on first play is assumed.
- MINOR focus regain invariants -> FIXED. GAIN requires switchboard ownership (else latch dropped, "not-owner"); `onHandoff()` clears the latch (wired from pauseForHandoff); latch only when a deck is audible; transient loss / becoming-noisy act on mixWantsAudio (live Auto-DJ). Tests added.
- MINOR denied focus / idle abandon -> FIXED. Denied request does remotePause (no regain is delivered for a failed request); onTransportIdle uses mixWantsAudio so a live Auto-DJ keeps focus between decks.
- MINOR card ignores holds / AD gaps -> FIXED. MixCard.held -> STATE_BUFFERING with constant position; playWhenReady from mixWantsAudio.
- MINOR no MixSessionPlayer tests -> FIXED within limits. No Robolectric in project, so the command mapping was extracted to Android-free `MixTransportRouter` (play/pause/stop/handoff/next/prev) which the player delegates to; tested against a fake port. Constructing the SimpleBasePlayer itself still needs a device/instrumented test.
- MINOR docs ledger -> FIXED. MIX-11 row now PARTIAL; MIX-5 row notes the detector landed. Export control stays on Debug screen (DebugScreen not owned by this package): recorded as a deviation.
- NIT reprime overwrites scheduled start -> FIXED (status gate). NIT SimpleDateFormat per call -> FIXED (ThreadLocal); export file write stays on the Debug button's thread (rejected: DebugScreen not owned, tiny file).
