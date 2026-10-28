state: implemented

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
