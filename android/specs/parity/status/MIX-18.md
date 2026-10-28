state: implemented

# MIX-18 Now Playing Mix mini-panel (F4) + Stem Lock

- [x] StemLock.kt: partPriority V>D>O>B, Indicator (off/idle/loading/active/unavailable), StemLockState (iOS JSON shape <-> SessionStemLock), StemLockSession (carry, user-change capture, applying guard, unavailable marker, restore/reset, pure indicator rule)
- [x] StemLockPrefetcher.kt: pure plan (song first, enabled stems V>D>O>B, further tracks, muted LAST, network sizing, cloud stemify once), one-at-a-time worker, keep-wanted/cancel-unwanted, failure cooldown
- [x] NowPlayingDspEngine.kt: `NowPlayingDspSeam` (engage/disengage/isPlaying/currentTimeSec/rate/onReachedEnd) over a private MixGraph deck A (shared Voice + Handover + DSP chain + AudioSink); tempo/pitch/gain/4 effects/stems (60 ms linear hand-over, generation-guarded fetch)
- [x] NowPlayingDspHost.kt: swap-on-touch engage (idempotent), hidden gate (non-local / mix running / Apple Music / held), Stem Lock apply on every track start, UI state flow
- [x] NowPlayingDspSessionPlayer.kt: TransportOwner `npdsp` (SimpleBasePlayer) - the ONE MediaSession, never a second card
- [x] NowPlayingDspPanel.kt + StemLockIndicator.kt (installed in NowPlayingSeams.dspSlot)
- [x] di/MixGraph.kt: engine/host/prefetcher/lock lazies + `installNowPlayingDsp()` (sequencer observers, heartbeat, mixSessionActive publisher)
- [x] Tests: NowPlayingDspEngineTest (21), NowPlayingDspHostTest (10), StemLockTest (10), StemLockPrefetcherOrderTest (12) = 53 new (suite 4519, 0 failures; was 4466)
- [x] assembleDebug green

## Files touched outside the owned set (minimal, additive)
- playback/session/SessionSwitchboard.kt: `yieldMixToExo()` also yields the `npdsp` owner (a controller load while the DSP owns the session would otherwise be dropped by the SimpleBasePlayer).
- di/AppGraph.kt: one `init` line calling `mixGraph.installNowPlayingDsp()` on Main.
- di/PlaybackGraph.kt: SessionWriter `stemLock = { app.mixGraph.stemLockForSession() }` (the param already existed, PB-4 reserved it).
- New files in mix/nowplaying/: NowPlayingDspHost.kt, NowPlayingDspSessionPlayer.kt (not in the roadmap list; host/glue split from the engine).

## Deviations / notes
- Late stem parts: a partial set goes on air with SILENT fillers for muted-missing parts; a part that lands AFTER the group is built joins at the next engage (iOS joins silently live). Enabled parts are always awaited before the hand-over.
- Stems are scheduled with the same window as the full mix (burned stems share the song's frame timeline).
- Panel expanded flag is `rememberSaveable` (iOS @AppStorage persists across launches).
- Stem Lock hybrid-owner gating for cloud stemify relies on RipJobTracker.hasServer() (no separate owner flag exists on Android).
- Found+fixed during testing: DeckChain handover state persists across engages; a track following one that ended on stems would have started with main gain 0. `engage()` now settles the handover to the full mix.
- The in-app transport (PB-6 ladder) already reaches the DSP player via the MediaController (the session player is switched by the switchboard), so pause/skip need no PB-6 change.

## Device-only / not verified here
- Audible seamlessness of the ExoPlayer->DSP swap (engine starts at the Exo position read at touch time; ~tens of ms prime latency), route changes, AudioTrackSink under real focus.
- Emulator steps (burn, toggle stem, skip, kill+relaunch) not run (emulator owned by integrator).

## Questions for Levi
- None.
