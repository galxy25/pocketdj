state: reviewed

# MIX-9 Auto-DJ machine + readiness rules + glide + remote freeze + jukebox queue seams

- [x] AutoDj.kt: startAutoMix (eject both + .resetDeck x2, on-device-first shuffled open, preload A/B), autoFire lanes (preroll / fade / postroll / idle), beginAdvanceTransition fade cap >=0.5 s + pendingFadeRestore, begin/finishAutoCrossfade, ensureNextPreloaded (drop vanished, defer transiently unloadable), skipToNext, pauseAuto/resumeAuto/beginResumeHandoff, stopAutoMix/endAutoLoop, repeat off/one/all, autoStatus (StateFlow `ui`), autoEndedExhausted (on engine), remotePause/remotePlay/remoteSkip + unfreezeAutoClock, engineStall park/unpark/checkpoint, snapshot/restoreSuspended
- [x] AutoReadiness.kt: pure `ready`/`canAir` rules + AutoReadinessOps (deckReadyToAir/deckCanAir, promoteReadyUpcoming, extendLive, abandonTransition, standbyCanAir), `mixadvance` log lines
- [x] GlideMachine.kt: texture run via MixMath.rollTexture (seeded per queue), per-deck slot resolution, Mix Glide params, preroll/postroll, glidePhaseAlign, non-recording setters, compact `.glide` events
- [x] AutoQueueSeams.kt: onAirTrack/onAirBuffering/autoUpcoming(+Detailed)/autoPlayed(+Detailed)/autoUpcomingLockedCount, insert next/end/random >= committed bound, shuffle/remove/move uncommitted only, persist on each change
- [x] Tests: AutoDjTest (40), AutoReadinessTest (~20), GlideMachineTest (~15), AutoQueueSeamsTest (~15)

## Tests
JVM suite 2533 total, 0 failures; +90 from this package; `assembleDebug` green.

## Touched outside owned files (all additive)
- mix/engine/MixEngine.kt: `ejectDeckCore`/`matchBpm`/`resetLoadCycle` made internal; new internal `loadNow` (sync load that bypasses loadOffload, needed because the machine checks the deck right after loading), `songOnDisk`, `noteSounded`, `clearMasterPaused`, `hasMasterPaused`; watchdogRecover calls `autoDj.parkEngineStall()/unparkEngineStall()`.
- mix/engine/EngineCore.kt: `AutoDjHooks.parkEngineStall()/unparkEngineStall()` (default no-op).
- mix/engine/MixTick.kt: calls `autoDj.unparkEngineStall()` when the sink renders.
- di/MixGraph.kt: builds `AutoDj`, exposes `autoDj`, fills `EngineAutoMixHost` insert/start/label/upcoming hooks (downloader RANDOM/END -> JukeboxDecisionAction).
- test: AutoDjTest.kt hosts shared `AutoRig` / `FakeSeams`; new AutoQueueSeamsTest.kt (listed in roadmap unit_tests though not in files).

## Deviations / notes
- Stream readiness (MIX-10) comes through the `AutoSeams` interface (`stream(deck)`, `songOnDevice`, `transientlyUnloadable`); defaults = everything on disk. MIX-10 must assign `autoDj.seams` and call `autoDj.restampEnd(deck)` / `setDeckDuration(deck)` on stream truncation. Held state reads `engine.streamHeld` (OR of stream + stem providers).
- Lock-screen verbs: the auto-side pieces live on AutoDj (`remotePause/remotePlay/remoteSkip`); MIX-11 should call those and wire `onSkipCommandsEnabled`. In-app `pauseBoth` still ends a running auto via the engine hook.
- Not wired in UI (MIX-13/14): `autoDj.ui` StateFlow is the banner source ("n / total · Deck X").
- iOS `streamHeldSince` logging is tracked inside `fire` (only while mixing).
- AutoReadinessTest "no gap" check renders the real graph (OfflineRenderer) during a frozen fade and asserts every ~2 ms window has signal.
- Failed finish-time preloads keep the dead row in the queue until the next lead (ensureNextPreloaded drops it), exactly as iOS.
- Not done: emulator step (no emulator per instructions); ledger row in docs/ARCHITECTURE-ANDROID.md (integrator).

## Device-only
Real lock-screen transport and headset-button behaviour; audible glide quality; logcat `mixadvance` lines on a real drive.

## Questions for Levi
- None.

## Review

fixes applied

- MAJOR AutoReadiness seams not wired -> fixed. `LoaderAutoSeams` (burn store + MixStreamLoader) is assigned to `autoDj.seams` in di/MixGraph.kt: `transientlyUnloadable` = ripped && !burned && !canStream; `songOnDevice` = burned or finished non-failed stream. Test: `loaderSeamsDeferGatedRippedSongAndCountFinishedStreamsOnDevice`. `stream(deck)` StreamView stays null until MIX-10 StreamDecks supplies views (MIX-10 reads `autoDj.seams.stream`).
- MINOR streamHeldSince stale across lock-screen pause -> fixed. trackHolds runs before the remote-freeze / engine-stall guards; cleared in remotePause, remotePlay and ejectForReplacement. Test: `lockScreenPauseDuringHoldDoesNotBankHoldTimeTowardStallSkip` (verified failing without the fix).
- MINOR main-thread IO -> fixed for the per-tick path. `MixTrackResolver.exists()` (cheap, no sidecar reads) backs `songOnDisk`, so promoteReadyUpcoming no longer reads beat-grid JSON for every queued song each tick. `loadNow` stays synchronous by contract (the machine checks the deck straight after); its prepare() cost is unchanged (device-verify jank on untagged mp3).
- MINOR shared touchpoints -> recorded: this package edits di/MixGraph.kt (autoDj construction + `autoMixHost` hook block + seams assignment), MixEngine.kt, MixTick.kt, EngineCore.kt (watchdogRecover park/unpark, tick unpark, visibility, `MixTrackResolver.exists`). MIX-11 must EXTEND the existing autoDj / EngineAutoMixHost hook block in MixGraph (remotePause/remotePlay/remoteSkip/onSkipCommandsEnabled) rather than rewrite it.
- NIT restampEnd guard -> fixed in `setDeckDuration` (restamps only when the deck's end is already armed); onSeek path unchanged. isReady guards in skipToNext/fire left as is.
- NIT ledger row -> integrator: mark PARTIAL in docs/ARCHITECTURE-ANDROID.md. Device-only unverified: lock screen + headset buttons, glide sound, banner/logcat, stream StreamView (MIX-10).
