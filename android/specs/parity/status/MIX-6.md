state: merged

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

## Review
fixes applied. Suite: 1398 tests, 0 failures (4 added: ReviewFixesTest x3, MixStreamLoaderTest.slowAdoptionDoesNotHoldTheLoaderLock); assembleDebug green.
- MAJOR hasServer cold-start false -> fixed: `SeededFlag` seeded by one runBlocking(IO) read in MixGraph before the loader exists, refresh throttled to once per 5 s (test: seeded first read, 50 reads -> 1 refresh).
- MAJOR adoption under loader lock -> fixed: complete()/adoptStemsIfComplete move files on `scope` outside the lock, re-take it to publish finalFile/adopted (identity-checked); stream reads as still-streaming until the move finishes. Test: parked adopter, queries answer < 1 s.
- MINOR NetworkMonitor offline-at-launch / stale set -> fixed: `DefaultNetworkTracker` tracks only the current default network, seeded from activeNetwork + INTERNET capability (3 tests).
- MINOR stem parts same priority as songs -> fixed (substitute for URLSessionTask.lowPriority): stem parts use a second OkHttpClient whose Dispatcher caps at 2 requests (`StreamSink.lowPriorityClient`).
- MINOR yieldBackgroundDownload no-op / adopt races burn -> partly fixed: `BurnStore.adoptStreamedFile` returns null while `runLock` is held (file stays playable from cache); `TODO(SVC-3)` at the site to wire yieldBackgroundDownload. Wiring itself stays deferred to SVC-3.
- MINOR sweep/client on main -> fixed: construction snapshots existing files and deletes them on the IO scope; test waits for the sweep.
- MINOR acceptance (debug action + emulator logcat) -> NOT done: emulator is owned by the integrator. Package is JVM-verified only; integrator must run the emulator step. Treat as PARTIAL until then.
- NIT manifest ACCESS_NETWORK_STATE -> recorded as a shared touchpoint (additive, required); expect a trivial merge conflict with other packages editing permissions.
