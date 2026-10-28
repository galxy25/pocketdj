package com.levi.pocketdj.data.transfers

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.levi.pocketdj.work.WorkOutcome
import com.levi.pocketdj.work.WorkSeams
import com.levi.pocketdj.work.runWorkBody

/**
 * Periodic (15 min, network-required) rip-manifest reconcile — the Android twin of the iOS
 * `rip-reconcile` BGTask. Scheduled by the shell via `FeatureModule.periodicWork`
 * (id `pdj.rip-reconcile`); the body is the [WorkSeams.ripReconcile] seam (onboarding-gated).
 * IOException => retry, anything else is final (next period picks it up).
 */
open class RipReconcileWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result =
        when (runWorkBody { WorkSeams.ripReconcile(applicationContext) }) {
            WorkOutcome.SUCCESS -> Result.success()
            WorkOutcome.RETRY -> Result.retry()
        }
}
