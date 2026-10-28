package com.levi.pocketdj.data.applemusic

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The UNATTENDED Apple Music sync (iOS `AppleMusicAutoSync`): fire once per local day at the
 * user's chosen time; a missed slot fires on the next launch / foreground / periodic tick.
 */
object AppleMusicAutoSync {
    /** 4:20 PM local - the default daily fire time. */
    const val DEFAULT_MINUTES = 16 * 60 + 20

    /** WorkManager unique id (a catch-up tick, not the schedule itself - the gate decides). */
    const val WORK_ID = "pdj.am-auto-sync"

    /**
     * PURE: is a run due at [nowMs], given the last claimed run and the fire time (minutes past
     * local midnight)? Due <=> we're at/past today's fire AND the last run predates it.
     */
    fun isDue(nowMs: Double, lastRunMs: Double?, minutesOfDay: Int, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        val now = Instant.ofEpochMilli(nowMs.toLong()).atZone(zone)
        val m = minutesOfDay.coerceIn(0, 1439)
        val todayFire = LocalDate.from(now).atStartOfDay(zone).plusHours((m / 60).toLong()).plusMinutes((m % 60).toLong())
        if (now.isBefore(todayFire)) return false
        if (lastRunMs == null || lastRunMs <= 0.0) return true
        return Instant.ofEpochMilli(lastRunMs.toLong()).isBefore(todayFire.toInstant())
    }
}

/**
 * Claim-before-run single-flight gate (iOS `autoSyncIfDue`): the `lastRun` stamp is written BEFORE
 * the pass, so concurrent triggers (launch + foreground + periodic tick) cannot double-run it.
 */
class AutoSyncGate(
    private val enabled: suspend () -> Boolean,
    private val minutesOfDay: suspend () -> Int,
    private val lastRunMs: suspend () -> Double?,
    private val setLastRunMs: suspend (Double) -> Unit,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    private val mutex = Mutex()

    /** Claims today's slot and returns true iff the caller should now run the pass. */
    suspend fun claimIfDue(): Boolean = mutex.withLock {
        if (!enabled()) return false
        val now = nowMs()
        if (!AppleMusicAutoSync.isDue(now, lastRunMs(), minutesOfDay(), zone)) return false
        setLastRunMs(now)
        true
    }

    /** Claim, then run [pass]. Returns whether it ran. */
    suspend fun runIfDue(pass: suspend () -> Unit): Boolean {
        if (!claimIfDue()) return false
        pass()
        return true
    }
}

/** Periodic catch-up tick (WorkManager floors at 15 min; hourly is plenty for a once-a-day gate). */
open class AmAutoSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result = try {
        com.levi.pocketdj.di.AppGraph.get(applicationContext).collectionsGraph.autoSyncTick()
        Result.success()
    } catch (e: java.io.IOException) {
        Result.retry()
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.success()
    }
}
