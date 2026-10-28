package com.levi.pocketdj.work

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.PeriodicWorkSpec
import java.io.IOException
import java.util.concurrent.TimeUnit

object WorkIds {
    const val RIP_RECONCILE = "pdj.rip-reconcile"
    const val STORAGE_PRUNE = "pdj.storage-prune"
}

/** The two periodic jobs the shell declares via FeatureModule.periodicWork. */
object ShellWork {
    val specs = listOf(
        PeriodicWorkSpec(WorkIds.RIP_RECONCILE, repeatMinutes = 15, requiresNetwork = true),
        PeriodicWorkSpec(WorkIds.STORAGE_PRUNE, repeatMinutes = 24 * 60),
    )
}

/** Pure description of one unique periodic request (testable without WorkManager). */
data class WorkPlan(
    val uniqueName: String,
    val intervalMinutes: Long,
    val requiresConnected: Boolean,
    val policy: ExistingPeriodicWorkPolicy = ExistingPeriodicWorkPolicy.KEEP,
)

object WorkSchedulerPolicy {
    /** One plan per id; duplicates collapse so scheduling twice yields one unique work. */
    fun plan(specs: List<PeriodicWorkSpec>): List<WorkPlan> =
        specs.distinctBy { it.id }.map {
            WorkPlan(
                uniqueName = it.id,
                // WorkManager floors periodic work at 15 min.
                intervalMinutes = it.repeatMinutes.coerceAtLeast(PeriodicWorkRequest.MIN_PERIODIC_INTERVAL_MILLIS / 60_000),
                requiresConnected = it.requiresNetwork,
            )
        }
}

class WorkScheduler(private val context: Context) {
    /** Idempotent: KEEP policy means a second call changes nothing. */
    fun ensureScheduled(specs: List<PeriodicWorkSpec>) {
        val wm = WorkManager.getInstance(context)
        for (plan in WorkSchedulerPolicy.plan(specs)) {
            val worker = when (plan.uniqueName) {
                WorkIds.RIP_RECONCILE -> RipReconcileWorker::class.java
                WorkIds.STORAGE_PRUNE -> StoragePruneWorker::class.java
                else -> continue
            }
            val request = PeriodicWorkRequest.Builder(worker, plan.intervalMinutes, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(if (plan.requiresConnected) NetworkType.CONNECTED else NetworkType.NOT_REQUIRED)
                        .build(),
                )
                .build()
            wm.enqueueUniquePeriodicWork(plan.uniqueName, plan.policy, request)
        }
    }
}

enum class WorkOutcome { SUCCESS, RETRY }

/** Maps a job body to a worker result: IOException retries, anything else is final. */
suspend fun runWorkBody(body: suspend () -> Unit): WorkOutcome =
    try {
        body()
        WorkOutcome.SUCCESS
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: IOException) {
        WorkOutcome.RETRY
    } catch (e: Exception) {
        android.util.Log.e("PocketDJ", "[work] failed", e)
        WorkOutcome.SUCCESS
    }

/** Test seam for the job bodies. */
object WorkSeams {
    @Volatile var ripReconcile: suspend (Context) -> Unit = { ctx ->
        AppGraph.get(ctx).ripsRepository.refresh()
        android.util.Log.i("PocketDJ", "[work] rip-reconcile refreshed manifest")
    }

    @Volatile var storagePrune: suspend (Context) -> Unit = { ctx ->
        // No destructive prune exists yet (LRP prune lands with storage work); measure only.
        val total = AppGraph.get(ctx).storageService.measureAll().values.sum()
        android.util.Log.i("PocketDJ", "[work] storage-prune checked, total=$total")
    }
}

private fun WorkOutcome.toResult() =
    if (this == WorkOutcome.SUCCESS) androidx.work.ListenableWorker.Result.success()
    else androidx.work.ListenableWorker.Result.retry()

class RipReconcileWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork() = runWorkBody { WorkSeams.ripReconcile(applicationContext) }.toResult()
}

class StoragePruneWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork() = runWorkBody { WorkSeams.storagePrune(applicationContext) }.toResult()
}
