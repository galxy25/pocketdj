state: implemented

# PB-8 - Apple Music rows in a run

Tests: 2498 total, 0 failed; +55 new (EndReasonTest 13, AppleMusicEndMonitorTest 16, AppleMusicAdapterStateMapTest 12, AppleMusicRowTest 14). `:app:testDebugUnitTest :app:assembleDebug` green.

- [x] am/AppleMusicEndMonitor.kt: EndReason, EndVerdicts (iOS endReason/trackEnded/trackRestarted/neverStarted/stoppedByInterruption, 1:1), AppleMusicEndMonitor tick state machine (FirstAudio / Ended / Restarted / Interrupted / Resumed), sticky intentional pause
- [x] am/AppleMusicController.kt: engine interface (fakeable) + BackendAppleMusicController (marks intentional pause, feeds PauseDiscriminator, interruption-resume hook)
- [x] session/AppleMusicPlayerAdapter.kt: SimpleBasePlayer + TransportOwner("am"); pure AppleMusicAdapterStateMap; 3-item playlist (prev stub, current, next stub) so Media3 next/prev are "available"; seek routing to sequencer.skipNext/skipPrevious
- [x] sequencer/AppleMusicRowResolver.kt (Rung.APPLE_MUSIC, AppleMusicSource backend="appleMusic"); canPlayFullTrack=false on emulator => falls through
- [x] SetlistSequencer: handleAppleMusicEnded (NATURAL/SYSTEM_SKIP->noteAdvanceAway+advance USER/NEVER_STARTED->advance never replay), handleAppleMusicRestarted, noteAppleMusicInterrupted/Resumed (AM notice hold)
- [x] AppleMusicBackend: non-suspending Main surface (snapshot, pauseNow, ...), changeListener, itemEndedListener
- [x] PlaybackController wiring: resolver registered, Media3Port.load/stop AM branch (loadAppleMusic), poll loop, EngineProbe AM-aware (so audible-time/cascade breaker see AM rows), rekick no-op for AM, single-row AM play also fronts the session with the adapter

## Deviations / outside owned files
- `playback/PlaybackController.kt` (not in owned list): AM wiring above. `di/PlaybackGraph.kt`: supervisor probe reports Lane.APPLE_MUSIC (detector-only) while AM is active (one-line additive).
- SessionSwitchboard.kt unchanged: the adapter uses its existing register/setOwner/resign API; "one-player-at-a-time" is covered by those existing tests + adapter pauseForHandoff.
- No AppleMusicPlayerAdapterTest with a live SimpleBasePlayer (needs a Looper; no Robolectric in the project): state mapping/command availability/seek routing are tested as the pure AppleMusicAdapterStateMap instead.
- Reduced iOS monitor: no `reconcilePoll` self-heal of stale SDK status, no onNearEnd/prefetch cache (not in PB-8 acceptance).
- Interruption resume re-queues the song and seeks back to the cut-off point (device-only, unverified); ExoPlayer replay() declines for AM so repeat-one reloads the AM row.
- DEVICE-ONLY: full-track playback, the AM session card, system skip/previous detection, interruption hold. Not emulator verified (emulator not used).
- ARCHITECTURE-ANDROID.md ledger left to the integrator.

## Questions for Levi
- None blocking.

## Review
fixes applied

- MAJOR PlaybackController:336 Exo teardown kills AM -> fixed. Adapter session claim is gated (AppleMusicSessionCore.holdClaims) across backend.play + the Exo stop/clearMediaItems in loadAppleMusic and tryAppleMusic, then releaseClaims claims. Test: AppleMusicSessionCoreTest.claimIsDeferredWhileHeld_thenGrantedOnRelease.
- MAJOR AppleMusicPlayerAdapter:159 pauseForHandoff marks listener pause -> fixed. New AppleMusicController.pauseQuiet (backend.pauseNow only, no onPlayIntent/noteIntentionalPause), and only when AM holds a live PLAYING/BUFFERING row. Tests: handoff_* , everyExoStart_doesNotTouchTheAmListenerPath.
- MAJOR PlaybackController:706 scrubber skips noteSeek -> fixed. seekTo routes through amController.seekTo (noteSeek + seekNow). Tests: ourOwnBackwardScrub_afterNoteSeek_isNotARestart / backwardJumpWithoutNoteSeek_isARestart (monitor contract; the controller routing itself is device-only).
- MAJOR AppleMusicPlayerAdapter:204 handleStop -> fixed. Adapter takes onStop; the controller wires it to PlaybackController.stop() (abandonRun + disarm + backend stop). Test: sessionStop_routesToTheControllersFullStop_notTheEngine.
- MINOR PlaybackController:343 stray start watchdog -> fixed in SetlistSequencer: post-load armStartStall only if firstAudioPending. Test: firstAudioDuringLoad_doesNotArmAStrayStartWatchdog (FakePlayerPort.duringLoad hook).
- MINOR PlaybackController:259 interruption resume -> fixed. amResuming guards the poll loop; AppleMusicBackend.play(resume=true) preserves startedSongId (no duplicate History row) and restores the interrupted row on failure so the hold + notice stay. Device-only, not unit-tested.
- MINOR PlaybackService:170 onDestroy releases adapter -> fixed. Exo player held in a field and released directly; session released without releasing session.player; non-Exo owner resigned; the adapter stays valid for the next service instance.
- MINOR AppleMusicRowResolver:726 token fetch on resolve path -> fixed. Resolver uses AppleMusicBackend.canPlayFullTrackCached (no network); a cold token is warmed off-path (scope.launch) so the next row sees it. Trade-off: the first AM row after a cold token falls through to the rip rungs.
- NIT AppleMusicEndMonitor:641 -> documented (neverStarted covered by the 10 s confirm timeout in production).

Tests: 2508 run, 0 failures (was 2497-class baseline; new AppleMusicSessionCoreTest + 4 added cases). assembleDebug green.
