state: merged

# SVC-3 TransferCoordinator over WorkManager

All sub-steps done. 46 new JVM tests (BearerPolicy 7, Coordinator 13, Codec 4, Worker/Runner 14, Notifications 1, BurnStore+transfers 7); suite 1412 tests, 0 failures; assembleDebug green.

- [x] TransferModels / BearerPolicy / TransferCoordinator (TransferWork seam, BytesThrottle)
- [x] BurnDownloadWorker (+ BurnDownloadRunner, DownloadOutcome.from, WorkManagerTransferWork)
- [x] RipReconcileWorker in data/transfers (typealias in work/WorkScheduler.kt keeps WorkIds/registry/tests unchanged)
- [x] TransferNotifications; manifest SystemForegroundService dataSync merge
- [x] BurnStore `transfers` param: queued path (ledger row + record persisted before enqueue), finalize/fail hooks, healStrandedDownloads, cancelTransfers
- [x] ServicesGraph (transfers, transferRuntime); AppGraph launch: transfers.reconcileOnLaunch + healStrandedDownloads
- [x] Tests

## Files touched outside owned list (minimal, additive)
- work/WorkScheduler.kt: RipReconcileWorker class replaced by typealias to the new class.
- di/AppGraph.kt: two launch lines after burnStore.reconcileOnLaunch().
- data/burns/BurnModels.kt: BurnResult.queued (default 0).
- AndroidManifest.xml: xmlns:tools + SystemForegroundService foregroundServiceType=dataSync (tools:node=merge).

## Deviations
- Terminal failures also count as "finished" so the overlay clears (iOS leaves the counter stuck).
- Background path skips in-process analog per-song cut export (exportAnalogCut) and relies on album file + startMs; stems/beatgrid post-pass unchanged.
- Presigned URL rides in WorkManager input data (not the record); bearer decision made at enqueue, token read at run.
- Burn Stop button wiring (BurnStore.cancelTransfers) exists but no UI caller changed (not in owned files).

## Device/emulator-only (not verified; emulator owned by integrator)
- force-stop survival, notification, jobscheduler periodic rip-reconcile.

## Questions for Levi
- None blocking. POST_NOTIFICATIONS runtime prompt is not requested anywhere yet; without it the foreground notification is hidden (download still runs).

## Review
fixes applied. Suite 1417 tests (+5), 0 failures; assembleDebug green.
- MAJOR Stop no-op in transfer mode -> fixed: BurnStore.requestStop cancels DOWNLOADING transfers and drops rows (test requestStopCancelsBackgroundWorkAndDropsRows).
- MAJOR analog sibling .part race -> fixed: per-worker part name, per-album mutex in the runner (siblings skip the download and finalize from the shared file), re-check before move (test siblingAnalogRecordsDownloadAlbumOnceAndNeverCorrupt).
- MAJOR RipReconcileWorker FQN -> fixed: real subclass kept at com.levi.pocketdj.work.RipReconcileWorker (base class now open); typealias removed.
- MINOR beginRun per song -> fixed: once at run start, only when no live records (test countersResetOncePerRunNotPerSong; existing in-flight test still green).
- MINOR stale presign -> fixed: on HTTP 403 the runner re-presigns once (ServicesGraph refreshUrl) and retries (test expiredPresignRetriesOnceWithFreshUrl).
- MINOR reconcile drops just-enqueued record -> fixed: records enqueued by this process are skipped (test reconcileKeepsRecordsEnqueuedByThisProcess).
- MINOR orphan files after late cancel -> fixed: runner deletes produced sidecar and non-analog audio when the record is gone (shared analog album left in place).
- MINOR ledger row -> fixed: PARTIAL with device-only list.
- NIT destDir via folder.dirFor -> not done (v1 is app-private only; revisit with SAF).
