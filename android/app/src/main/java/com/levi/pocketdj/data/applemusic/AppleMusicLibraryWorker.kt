package com.levi.pocketdj.data.applemusic

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** Pure decision for how a finished index run maps to a WorkManager result (testable without WorkManager). */
enum class LibraryWorkResult { SUCCESS, RETRY }

fun libraryWorkResult(o: AppleMusicLibraryIndexer.Outcome): LibraryWorkResult = when (o) {
    is AppleMusicLibraryIndexer.Outcome.Indexed -> LibraryWorkResult.SUCCESS
    // Not signed in / token rejected: retrying cannot help; the sign-in hook or the next daily run re-tries.
    AppleMusicLibraryIndexer.Outcome.NeedsUserToken -> LibraryWorkResult.SUCCESS
    is AppleMusicLibraryIndexer.Outcome.RateLimited -> LibraryWorkResult.RETRY
    is AppleMusicLibraryIndexer.Outcome.Failed -> if (o.status == null || o.status >= 500) LibraryWorkResult.RETRY else LibraryWorkResult.SUCCESS
}

enum class SignInIndexDecision { NONE, AUTO, FULL }

/**
 * What the Apple Music sign-in watcher enqueues. [prevSignedIn] is null on the first emission (process start).
 * A false-to-true transition is a (possibly different) account: FULL. At launch while already signed in, run
 * only when there is no index yet or the last one is over a day old; steady state is the periodic worker's.
 */
fun signInIndexDecision(
    prevSignedIn: Boolean?, signedIn: Boolean, storeEmpty: Boolean, lastIndexMs: Double, nowMs: Double,
): SignInIndexDecision = when {
    !signedIn -> SignInIndexDecision.NONE
    prevSignedIn == false -> SignInIndexDecision.FULL
    storeEmpty || lastIndexMs <= 0.0 || nowMs - lastIndexMs > 24 * 3_600_000.0 -> SignInIndexDecision.AUTO
    else -> SignInIndexDecision.NONE
}

/**
 * Daily + after-sign-in indexing of the user's Apple Music library (P2-LIB-2). Declared periodic by
 * ServicesGraph (network + battery-not-low; unmetered NOT required); [enqueueNow] is the sign-in / Settings
 * "Re-index" hook. Off when [AmLibrarySettings.ENABLED] is false.
 */
open class AppleMusicLibraryWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result = try {
        val services = com.levi.pocketdj.di.AppGraph.get(applicationContext).servicesGraph
        val mode = if (inputData.getBoolean(KEY_FULL, false)) AppleMusicLibraryIndexer.Mode.FULL else AppleMusicLibraryIndexer.Mode.AUTO
        val outcome = services.runAmLibraryIndex(mode, manual = inputData.getBoolean(KEY_MANUAL, false))
        if (outcome != null && libraryWorkResult(outcome) == LibraryWorkResult.RETRY) Result.retry() else Result.success()
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: java.io.IOException) {
        Result.retry()
    } catch (e: Exception) {
        android.util.Log.e("PocketDJ", "[am-library] index failed", e)
        Result.success()
    }

    companion object {
        const val PERIODIC_ID = "pdj.am-library-index"
        const val ONCE_ID = "pdj.am-library-index-now"
        const val KEY_FULL = "full"
        const val KEY_MANUAL = "manual"

        /**
         * One-time run: after Apple Music sign-in (auto mode) or Settings ▸ "Re-index" ([manual] => FULL,
         * ignores the daily toggle and the battery constraint). Unique + KEEP so a burst of taps is one run.
         */
        fun enqueueNow(context: Context, manual: Boolean = false, full: Boolean = manual) {
            val c = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(!manual).build()
            val req = OneTimeWorkRequestBuilder<AppleMusicLibraryWorker>()
                .setConstraints(c)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .setInputData(Data.Builder().putBoolean(KEY_FULL, full).putBoolean(KEY_MANUAL, manual).build())
                .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(ONCE_ID, if (manual) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, req)
        }
    }
}
