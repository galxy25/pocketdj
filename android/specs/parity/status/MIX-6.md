state: implemented

# MIX-6 MixStreamLoader
- [x] StreamSink (OkHttp; ordered response->bytes->finished; Range append / 200 restart; 4 Hz / 256 KB throttle)
- [x] NetworkMonitor (ConnectivityManager callback; SettableNetworkMonitor for tests)
- [x] MixStreamLoader port (open/openStems/cancel/cancelStems, makeRoom w/ pinned, 3 Range retries, 120 s song cooldown, 60 s server-down, cut->side fallback on any non-2xx, adoption via BurnStoreAdopter, stem listeners/owners)
- [x] MixGraph.mixStreamLoader wiring (main-thread hooks, plain app http client, cacheDir/mixstream)
- [x] Tests: StreamSinkTest (6) + MixStreamLoaderTest (22) = 28 new; full suite 1394 tests, 0 failures; assembleDebug green

## Deviations / notes
- Touched outside owned files: AndroidManifest.xml (+ACCESS_NETWORK_STATE, additive); test-only helpers StreamTestSupport.kt (new, mix/stream).
- Tunables (maxConcurrent, maxRetries, cooldowns) are instance vars rather than statics.
- Launch sweep happens when the loader is first constructed (lazy in MixGraph), not at process start; partials from an earlier launch are removed before any stream starts.
- BurnStore has no yieldBackgroundDownload yet (SVC-3 transfer path); StreamAdopter.yieldBackgroundDownload is a hook, MixGraph passes a no-op. Wire it when SVC-3's background burns land.
- hasServer is synchronous on iOS; Android's isConfigured is suspend, so MixGraph keeps a refreshed cached flag (false until first answer, ms after construction).
- Debug action for emulator verification not added (no debug-UI touchpoint owned); logcat/telemetry categories "mixstream open/resume/done" go through DiagLog.telemetry.

## Questions for Levi
- none
