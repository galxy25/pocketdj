state: reviewed

# COL-20 Android location source (Fused + dwell) + Settings rows + wiring

- [x] DwellDetector (pure): 5 min / 150 m dwell, close on radius+accuracy, >3000 m ignored, coarse fixes hint-only
- [x] FusedVisitSource: low-power updates (5 min / 200 m) via PendingIntent receiver + LocationPollWorker (15 min periodic, self-gated)
- [x] LocationSettings: permission mapping (COARSE/FINE => WHEN_IN_USE, +BACKGROUND => ALWAYS), status copy, Settings deep link
- [x] ListeningLocationSection (order 665): toggle (ON needs pockets, OFF never blocked), status, Allow Always / Open Settings, places/trips, Erase
- [x] CollectionsGraph: real ListeningLocationStore replaces Noop provider; onDisabled => store.setEnabled(false) (erases); settleContexts after each ingest; poll worker registered
- [x] Manifest: location permissions + receiver
- [x] Tests: DwellDetectorTest (5), LocationSettingsTest (4, incl. denied => nothing ingested, upload event only plc_ id / no coordinates). Suite 5109 tests, 0 failures.

## Notes / deviations
- Foreground prompt requests COARSE + FINE together (user may choose approximate): a COARSE-only grant has ~km accuracy, so it yields movement hints (provisional coarse anchor) but no places (anchor accuracy gate 200 m); Settings shows an Allow precise location row.
- Detector state (anchor, last in-radius time, visit-emitted) is persisted to a no-backup file while on, erased on stop.
- Files touched outside owned list: none beyond owned (CollectionsGraph, manifest are owned). New: LocationSettings.kt/LocationSettingsTest.kt are NOT in the roadmap owned list (additive new files only).
- Device-only: real movement/dwell; emulator via `adb emu geo fix` (needs ~6 min hold, polled by the worker/updates).

## Questions for Levi
- Is approximate-only location acceptable (hints only, no places)? Default: ask for precise too.

## Review
fixes applied
- MAJOR coarse-only produces nothing -> fixed: DwellDetector keeps a provisional coarse anchor and emits hints; Settings shows "Allow precise location" when approximate-only; docs corrected; tests coarseOnlyYieldsHintsButNoVisits + approximateOnlyAndRetryRules.
- MINOR detector state lost on process death -> fixed: snapshot/restore persisted in noBackupFilesDir, erased on stop; test snapshotRestoreResumesStayAfterProcessDeath.
- MINOR toggle race -> fixed: Mutex + latest-requested-value wins; prompt skipped if latest is off.
- MINOR lapsed grant shows Denied/Open Settings -> fixed: denial count + rationale decide REQUEST_FOREGROUND vs OPEN_SETTINGS (LocationSettings.canRequestAgain).
- MINOR unconditional 15 min worker -> fixed: FusedVisitSource enqueues on start, cancels on stop; removed from periodicWork.
- MINOR denied test ingested nothing -> fixed: test now calls ingestVisit/noteMovement while DENIED; store gates ingest on auth.isGranted (also FusedVisitSource.feed). ListeningPlacesStoreTest.contextLookupDelegates reordered to grant before ingest.
- MINOR iOS divergence -> fixed: section renders only under the rec engine, toggle disabled (not hidden) with pockets off, footer always shown.
- MINOR acceptance gaps -> ledger row updated (PARTIAL); emulator geo-fix sequence NOT run (emulator owned by integrator); owned-files claim corrected.
- NIT fusedSource stale / feed ordering -> fixed: onStopped clears the reference; detector + store calls under one lock.
Suite: 5112 tests, 0 failures; assembleDebug OK.
