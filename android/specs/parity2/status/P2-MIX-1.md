state: implemented

# P2-MIX-1: Mix Auto Mix crate stall

Summary: LaneIssue {tokenRejected, noServer, ripServerRefused(status), ripsStalled} with honest bar copy; refused rip batches back off
exponentially (2,4,8..67 ticks) and never POST while the auth holdoff is up; stall watchdog (133 ticks) re-requests; burn lane parks
(bounded, 2 h) under a rejected token with songs kept queued (a miss under a rejected token re-queues at the front; user burns go through
BurnStore directly and ignore the hold); MixStreamLoader treats a rejected token as a credential hold (no server-down trip, no doubled
presign, reopens on token change); declared count is overlap-corrected; `catalogDidChange()` re-resolves on every catalog assign
(late members join the lanes and the running mix; an exhausted mix is never revived by a catalog event); "catalog still loading" only
while loading; `ShellActions.playMixCratesInNowPlaying` + `MixFacade.releaseForNowPlaying` (cancels downloader, stops auto mix / pauses
hand-played decks) + DownloadBar "Play in Now Playing" button; `otherAudioActive` seam stops background landings starting a mix over
Now Playing.

Tests: 5934 total, 0 failures at the tip (this package added: CollectionMixDownloaderLaneTest 22, ShellActionsMixFallbackTest 4,
MixStreamLoaderTest +3, CrateMenuStateTest +1 and one expectation updated). `:app:testDebugUnitTest :app:assembleDebug :app:assembleRelease` green.

## Checklist
- [x] LaneIssue.kt  - [x] downloader lanes/backoff/watchdog/park/overlap/catalogDidChange  - [x] MixStreamLoader hold
- [x] ShellActions fallback + MixFacade  - [x] DownloadBar/AutoMixBars  - [x] tests, release build

## Files touched outside the owned list (all minimal/additive)
- `di/MixGraph.kt`: downloader seams (`catalogIsLoading`, `otherAudioActive`), catalog-assign collector -> `catalogDidChange()`, `releaseForNowPlaying` lambda into MixFacadeImpl.
- `mix/MixFacadeImpl.kt`, `shell/MixFacade.kt`: `releaseForNowPlaying()` (default no-op in the interface).
- `screens/mix/MixScreen.kt`: DownloadBar `onPlayInNowPlaying`, AutoMixBanner `laneNote`.
- tests: `CrateMenuStateTest` (shortfall copy now depends on `catalogStillLoading`), `MixStreamLoaderTest`.

## Deviations / INTEGRATION REQUIRED after P2-LIB-1 merges
- P2-LIB-1 (parallel, not merged here) owns the token-scoped auth hold and `BatchRipResult.refusedStatus`. This package defines the consumer seams with
  safe defaults (`MixDownloadRips.requestRips/isAuthRejected/authHoldoff/refreshAuth`, `MixStreamRips.authHoldoff/isAuthRejected`), so until wired
  the behavior equals today's. WIRE-UP (integrator, ~15 lines): in `MixGraph.RipsMixRips` override `requestRips` = `coordinator.ripCollection(...)` ->
  `RipBatchOutcome(result.refusedStatus)`, cache `isAuthRejected`/`authHoldoff` from `client.isAuthRejected()/authHoldoff()` in `refreshAuth()`;
  in the `MixStreamRips` object in `streamLoaderLazy`, `authHoldoff()/isAuthRejected()` from a `SeededFlag` over the same client calls.
  "Presign 401 charged to the token it was SENT with" lives in LIB-1's `RipAuthState.noteStatus(status, token)`.
- "Mix log 'no loadable next' throttled": AutoDj already logs once per distinct deferred set (not at 10 Hz); iOS's extra 30 s re-log was not ported (AutoDj.kt not owned).
- No `ShellActions` background-event guard beyond the downloader seam: auto-start paths in other packages (AutoDj) are unchanged.

## Questions for Levi
- None blocking. Default chosen: the fallback plays shuffled (iOS default `shuffle: true`).
