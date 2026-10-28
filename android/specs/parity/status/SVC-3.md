state: in-progress

# SVC-3 TransferCoordinator over WorkManager

- [x] TransferModels / BearerPolicy / TransferCoordinator (+TransferWork seam, BytesThrottle)
- [x] BurnDownloadWorker (+ BurnDownloadRunner, DownloadOutcome.from, WorkManagerTransferWork)
- [x] RipReconcileWorker moved to data/transfers (typealias left in work/WorkScheduler.kt)
- [x] TransferNotifications; manifest SystemForegroundService dataSync merge
- [x] BurnStore `transfers` param (queued path, finalize/fail hooks, healStrandedDownloads, cancelTransfers)
- [x] ServicesGraph wiring; AppGraph launch reconcile
- [ ] Tests
