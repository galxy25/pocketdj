package com.levi.pocketdj.data.transfers

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.levi.pocketdj.work.WorkOutcome
import com.levi.pocketdj.work.WorkSeams
import com.levi.pocketdj.work.runWorkBody

/**
 * Periodic (daily) storage soft-cap prune - the Android twin of the iOS `storage-prune` BGTask.
 * Scheduled by the shell (id `pdj.storage-prune`, no network). The body is the
 * [WorkSeams.storagePrune] seam: `StorageManager.pruneIfDue()` (no cap => no-op; 20 h gate with
 * the stamp written before any deletion).
 */
open class StoragePruneWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result =
        when (runWorkBody { WorkSeams.storagePrune(applicationContext) }) {
            WorkOutcome.SUCCESS -> Result.success()
            WorkOutcome.RETRY -> Result.retry()
        }
}
