state: merged

# SURF-2 — Application lifecycle + background work

- [x] PocketDjApplication (manifest android:name), ProcessLifecycle observer (AppLifecycleObserver)
- [x] FlushRegistry (ordered, exception-isolated, 2 s bound, logged); AppGraph.flushRegistry + module flushables
- [x] BrowseSessionFlushable writes live session on ON_STOP (guarded until restore ran)
- [x] WorkScheduler + RipReconcileWorker/StoragePruneWorker; ShellGraph.periodicWork declares the two jobs (KEEP, unique)
- [x] Tests: FlushRegistryTest (5), WorkSchedulerPolicyTest (4); 635 total, 0 failures; assembleDebug green

## Notes / deviations
- Touched outside owned: AppGraph.kt (flushRegistry + register), BrowseModels.kt (BrowseSession.restored flag, currentState internal), MainActivity.kt (removed onStart refresh; now in Application observer).
- storage-prune worker only measures (no LRP prune exists yet). Widget drain is `AppLifecycleObserver.widgetDrain` hook for WID-1.
- Worker Result tests are via pure runWorkBody (SUCCESS/RETRY), not WorkTestBuilder.
- Emulator steps not run.

## Review
fixes applied. 642 tests, 0 failures (was 635; +7), assembleDebug green.
- MAJOR flush on delayed ProcessLifecycle ON_STOP -> fixed: MainActivity.onPause/onStop call AppGraph.flushAsync() (serialized, idempotent via Mutex); process ON_STOP flush kept. Tests: BrowseSessionFlushableTest (3, drives flushable directly, no debounce), AppLifecycleObserverTest (2).
- MINOR rip-reconcile RETRY unreachable -> fixed: RipsRepository.refreshStrict() throws IOException; worker seam uses it and logs success only after a real fetch. refresh() keeps iOS silent-cached behaviour.
- MINOR cold-start graph cost -> fixed: Application no longer builds AppGraph; forced endpoint fetch moved out of AppGraph.init into the first foreground hook (once per process, later throttled). Residual: a worker wake still builds AppGraph (SecretMigration, IntentSink.install, BrowseSession.attach); a narrower worker seam is future work.
- MINOR hardcoded worker mapping -> fixed: WorkerRegistry (modules register id->class); unknown id is logged at error level, not silently dropped.
- MINOR idempotency test -> fixed: WorkScheduler takes an enqueue seam; test calls ensureScheduled twice and asserts KEEP + unique names. Partially rejected: WorkManagerTestInitHelper needs an Android Context (no Robolectric on the JVM test classpath); a real WorkManager unique-work check belongs in androidTest/emulator.
- MINOR ledger row -> fixed: ARCHITECTURE-ANDROID.md SURF-2 row = PARTIAL. Gaps: storage-prune is measure-only (iOS runs a real soft-cap pruneIfDue), jukebox bootstrap on onStart deferred, emulator steps not run.
- MINOR AppGraph edits outside owned files -> fixed in part: Browse flushable now contributed via BrowseGraph.flushables (removed from AppGraph). AppGraph still carries flushRegistry/flushNow and BrowseModels.kt the `restored` flag + persist(); unavoidable.
- NIT unordered writes -> fixed: BrowseSession.persist() under one Mutex writes the live state at lock time, used by both the debounced collector and the flush.

