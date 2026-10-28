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
