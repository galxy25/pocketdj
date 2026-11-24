state: implemented

# P2-MM-4 Mix Mode ph2a: Mix Mode state + NowPlayingPrefetcher, network policy, disk guard

- [x] NetworkClass.kt (UNMETERED/EXPENSIVE/CONSTRAINED/OFFLINE, pure classify + ConnectivityManager reader)
- [x] DiskGuard.kt (pure verdict, admit() sweeps once via injected sweep, re-checks)
- [x] NpMixMode.kt (NpMixModeState @Serializable, Indicator, IndicatorInput, indicator(), BufferDot, BufferRow)
- [x] NowPlayingPrefetcher.kt (generalised lane: plan(Input), legacy plan(...), rips, disk guard per step, cooldowns, awaitPendingDownload)
- [x] StemLockPrefetcher.kt -> typealias
- [x] NetworkMonitor.networkClass (shared touchpoint, additive default)
- [x] Tests: NowPlayingPrefetcherTest, NpMixModeIndicatorTest
- [x] Green build: :app:testDebugUnitTest :app:assembleDebug (5941 tests, 0 failed). assembleRelease not run: no manifest/gradle/proguard/library change.

## Deviations / files touched outside owned set
- Kotlin typealiases cannot expose nested classes, so `StemLockPrefetcher.Network/Track/Step/Plan` no longer resolve:
  MixGraph.kt (4 references + disk-guard wiring + npNetwork via NetworkClass.current) and StemLockPrefetcherOrderTest.kt
  (imports) were edited minimally. `Network` is now top-level `NetworkClass`.
- `isCatalogOwner` of iOS is replaced by `isRipServerConfigured` (design input name); the caller folds ownership in.
- MixGraph wires DiskGuard with only the 1 GB free-space floor (footprint 0, no-op sweep); P2-MM-5 binds footprint/cap/sweep to StorageManager.
- Explicit-download wait (`awaitPendingDownload`, 90 s) is provided and tested; production fetchSong wiring (BurnStore pending-download lookup) is P2-MM-5.

## Summary
      37 new tests (NowPlayingPrefetcherTest, NpMixModeIndicatorTest); suite 5941 total, 0 failures. Mix Mode off == legacy Stem Lock plan is pinned by a
sweep over windows x networks x carries x cellular policies. Build ran with FIN_MIN_FREE_GB=1 (machine free-memory guard otherwise deadlocked the queue).

## Questions for Levi
- None blocking. Default for rips/cloud stem separation: gated on rip-server-configured (iOS gates on catalog owner); confirm who may trigger rips on Android.
