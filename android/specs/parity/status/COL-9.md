state: merged

COL-9 Apple Music playlist sync (Lambda WS2): client, coordinator, audit/run persistence, daily auto-sync, Settings pane.

- [x] AMPlaylistSyncClient: 202 submit -> stall-based poll (progress change resets 180 s deadline), 5xx/429/IO/decode absorbed, 404 jobGone, 4xx/worker terminal (id cleared), transient/stall keeps jobId, re-attach within 1 h (SharedPreferences job store) - AMPlaylistSyncClientTest (15, MockWebServer, virtual clock)
- [x] PlaylistAppleMusicSync: resolveOutgoing (normName merge, allowsPush gate, AM-provenance pockets, name+artist gate, trackMeta, skipped reporting), on-device catalog-id resolve w/ persisted cache, newImports (existing playlist+pocket names, link-by-id, fullest-of-same-name), import via createPlaylist(source=mirror), linkToAppleMusic stamping, audit read-merge-write cap 20, RunSnapshot per step, interrupted hydration, resumeIfInterrupted - PlaylistAppleMusicSyncTest (19)
- [x] AppleMusicAutoSync.isDue + AutoSyncGate (claim-before-run, single-flight Mutex) + AmAutoSyncWorker (hourly WorkManager catch-up) + foreground trigger - AutoSyncScheduleTest (6; named per owned file, covers the roadmap's isDueBoundaries/claimBeforeRun)
- [x] AmSyncSettings (iOS key names), Settings "Apple Music syncing" section (⇅ Sync / ↑ Send / ↓ Get, live steps, interrupted hint, history, automatic: daily switch, time picker, import-new)
- [x] CollectionsGraph wiring (client, coordinator, host, autoSyncTick, runFullPass, periodicWork, section)

Deviations / notes
- Reconcile (remove/reorder) omitted per roadmap; the AM mirror private-server branch (appleMusicPrivateSync) is omitted - Android always runs the public two-way path.
- Debug endpoint override: pref `amPlaylistSyncBaseOverride` (AmSyncSettings.BASE_OVERRIDE), no UI; set via DataStore for the emulator MockWebServer step.
- amPlaylistId links are in-memory only (iOS parity), so link-by-id dedupe resets each launch.
- Touched outside owned files: none (WorkerRegistry.register is called from CollectionsGraph.periodicWork; PocketDjApplication already schedules features.periodicWork).
- Device/emulator-only: real subscription + MUT; emulator steps not run (shared emulator).
- Suite: 4740 tests, 0 failures; assembleDebug green.

## Questions for Levi
- Daily auto-sync default ON (iOS parity) means a signed-in Android user pushes collections at 4:20 PM daily; signed-out it fails quietly with "Sign in to Apple Music". OK?

## Review

fixes applied

- MAJOR manual sync on screen scope: fixed. Buttons call `CollectionsGraph.startManualSync` (app scope); cancellation now flips RUNNING steps to INTERRUPTED. Test: `cancelledSyncShowsInterruptedNotSpinner`.
- MINOR autoSyncTick onboarding guard: fixed (`!app.onboarding.isComplete` returns early).
- MINOR manual buttons skip shared halves: fixed (`runManual` = syncNow, converted reconcile when not PUSH, write-back backfill when not PULL).
- MINOR DST fire time: fixed (wall-clock `atTime`); test `isDueUsesWallClockOnDstDays`.
- MINOR main-thread hydration: fixed (Settings section builds `playlistAmSync` via produceState on IO; buttons disabled until ready).
- MINOR ledger row: fixed (COL-9 PARTIAL with device-only notes).
- NIT base override: fixed (honoured only when BuildConfig.DEBUG).

Tests: 4742 run, 0 failed; assembleDebug OK.
