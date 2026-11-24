state: reviewed

# P2-MM-9: Mix Mode ph4 - Apple Music rows (prefer local rip, AM->local touch hand-off, rip-ahead)

Tests: 31 new JVM tests (PreferLocalAudioTest 15, AppleMusicHandOffRulesTest 6, AppleMusicHandOffTest 10); full suite 6679 tests, 0 failures; `:app:testDebugUnitTest :app:assembleDebug` green. assembleRelease not run (no manifest/gradle/proguard/library change).

## Done
- [x] `PreferLocalAudio` (in RowResolverRegistry.kt) + registry params (preferLocalAudio / isAppleMusicSourced / localCopyInstant); AM rung walked FIRST only when Mix Mode buffers, the row is AM-sourced + ripped and its rip is NOT instant (no local file, no cached presign, rip server configured) - never trades an instant AM start for a slow presign. Instant copy => rip plays, AM stays behind. Mix off => old ladder unchanged.
- [x] `AppleMusicRowResolver` honours ctx.appleMusicFirst / defers to an instant copy.
- [x] `AppleMusicHandOff.kt`: pure rules (3 s tail guard, lead 0, cause `npmix-am-handoff`) + orchestrator: AM position -> engage DSP paused -> stop AM -> play. Refusal (incl. DSP refusal) leaves AM playing; one dead-air transition closed at DSP first sound; only entered from the panel touch (host port), never from timers/events.
- [x] Rip-ahead: `PlaybackRipWindow.allowsAhead` (in window, never the playing row); MixGraph `requestRipAhead` (fire-and-forget through `/rip` + `notePlaybackRipQueued`, so the window cancels on skip); `isRipServerConfigured` now = rip server configured; AM-only rows classified `APPLE_MUSIC_ONLY`. Plan already limited to next 2 AM-only rows.
- [x] The playing AM row's whole song is now fetchable by the lane (needed for the hand-off target).
- [x] MM-8 GrowingStart `appleMusicFirst` fact now real (PreferLocalAudio + AM can play).

## Files touched outside owned list (minimal, additive)
- playback/sequencer/RowSourceResolver.kt (ResolveContext: 3 defaulted fields)
- mix/nowplaying/NowPlayingDspHost.kt (DspHostPorts: appleMusicHandOffReady/handOffFromAppleMusic defaults; available()/engageLocked AM branch; hasLocalCopy/engageLocalPaused)
- playback/npmix/NpMixWiring.kt (AM hand-off env + refresh hooks; growing appleMusicFirst fact; controller.preferLocalAudioProvider)
- di/MixGraph.kt (ports, onAudioStarted hook, requestRipAhead, source classification, replan refresh)
- playback/PlaybackController.kt (ripServerConfigured, registry wiring)

## Deviations
- `CloudRowResolver.kt` not changed: no change was needed (rip-on-demand already sits after the AM rung).
- "AM behind the rip as fallback" relies on the existing stall-hop/failure machinery; no new fallback walker was added.
- Android's ladder already prefers a manifest rip over AM when Mix Mode is off, so preferLocalAudio only ever reorders toward AM (slow presign case), mirroring the dead-air rule.
- Hand-off ordering: the DSP engage claims the session (onEngaged -> player.claim) before AM is stopped; AM's resign only affects the switchboard if AM owns it, so no re-claim step.

## Questions for Levi
- Rip-ahead gate: shipped default = rip server configured (Settings > Import server URL+token); otherwise rows show "Apple Music only".
- Emulator/device not exercised (shared emulator is the integrator's): real-AM hand-off needs the device check in the roadmap.

## Review
- MAJOR AppleMusicHandOff pos==null treated as 0 -> fixed: handOff refuses `no-position` (Apple Music plays on); appleMusicPositionMs now reads a nullable snapshot position (PlaybackController.appleMusicPositionMsOrNull) instead of the 0L stand-in. Test: anUnreadablePositionRefusesAndLeavesAppleMusicPlaying_neverRestartsAtZero.
- MINOR stopAppleMusic unguarded -> fixed: try/catch (CancellationException rethrown) rolls back via env.disengage(), sets refusedUid, abandons the open dead-air transition (new env.meterAbandoned). Test: aFailedAppleMusicStopRollsTheDspBackAndAbandonsTheMeter.
- MINOR play/interruption semantics -> fixed: Facts.appleMusicPlaying + pauseIntentional; interruption refuses only when neither holds (iOS interruptionHolds); DSP sounds only if Apple Music was audibly playing (wasPlaying). Tests: aMusicKitOwnedInterruptionFlag..., theDspOnlySoundsWhenAppleMusicWasSounding.
- MINOR rip-first AM fallback -> fixed with a code path: RowResolverRegistry.resolve(reResolve) remembers the last backend per row; the supervisor's re-resolve of an AM-sourced row whose rip was picked walks Apple Music first (rip no longer "instant"). Tests: aRipFirstRowWhoseRipDidNotSound_reResolvesToAppleMusic, reResolveNeverReorders...
- NIT main-thread JSON reads -> fixed: hasLocalCopy runs on Dispatchers.IO inside facts().

Tests: 6685 run, 0 failures (was 6679; +6). `:app:testDebugUnitTest :app:assembleDebug` green.

fixes applied
