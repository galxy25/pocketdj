package com.levi.pocketdj.data.location

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Android [ListeningLocationSource]: Fused low-power updates (5 min / 200 m displacement,
 * delivered to [FusedLocationReceiver] so they survive the process) + a periodic one-shot poll
 * ([LocationPollWorker]) because a stationary device gets no displacement updates and the
 * [DwellDetector] needs recurring fixes to prove a stay. Raw fixes go straight into the detector;
 * only visit / hint samples reach the store. Nothing is logged, nothing leaves the device.
 *
 * Detector state is in-memory: after process death the next fix re-anchors, so a stay's arrival
 * can be recorded up to one dwell later than the true arrival (never earlier).
 */
class FusedVisitSource(
    private val context: Context,
    private val detector: DwellDetector = DwellDetector(),
    /** Called after any ingest so the pockets service can settle contexts onto plays. */
    private val onIngested: () -> Unit = {},
) : ListeningLocationSource {

    @Volatile private var store: ListeningLocationStore? = null

    override val authorization: ListeningLocationAuthorization get() = LocationSettings.current(context)

    override fun start(store: ListeningLocationStore) {
        this.store = store
        registerUpdates()
    }

    override fun stop() {
        runCatching { LocationServices.getFusedLocationProviderClient(context).removeLocationUpdates(pendingIntent(context)) }
        detector.reset()
        store = null
    }

    /** The system permission sheet needs an Activity: the Settings row launches it, then calls this to re-sync. */
    override fun requestAlwaysUpgrade() = Unit

    /** (Re)register the updates after a permission change. Safe to call repeatedly. */
    @SuppressLint("MissingPermission")
    fun registerUpdates() {
        if (!LocationSettings.current(context).isGranted) return
        runCatching {
            val req = LocationRequest.Builder(Priority.PRIORITY_LOW_POWER, UPDATE_INTERVAL_MS)
                .setMinUpdateDistanceMeters(MIN_DISPLACEMENT_M)
                .setMinUpdateIntervalMillis(UPDATE_INTERVAL_MS / 2)
                .build()
            LocationServices.getFusedLocationProviderClient(context).requestLocationUpdates(req, pendingIntent(context))
        }
    }

    /** One fix in; visit/hint samples out to the store. */
    fun feed(fix: DwellDetector.Fix) {
        val s = store ?: return
        val out = detector.onFix(fix)
        for (o in out) when (o) {
            is DwellDetector.Output.Visit -> s.ingestVisit(o.sample)
            is DwellDetector.Output.Hint -> s.noteMovement(o.sample)
        }
        if (out.isNotEmpty()) onIngested()
    }

    /** Periodic poll body: one balanced fix (no-op without permission / when off). */
    @SuppressLint("MissingPermission")
    suspend fun pollOnce() {
        if (store == null || !LocationSettings.current(context).isGranted) return
        val client = LocationServices.getFusedLocationProviderClient(context)
        val loc = runCatching {
            suspendCancellableCoroutine<android.location.Location?> { cont ->
                val req = CurrentLocationRequest.Builder()
                    .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
                    .setMaxUpdateAgeMillis(2 * 60_000L)
                    .setDurationMillis(30_000L)
                    .build()
                client.getCurrentLocation(req, null)
                    .addOnSuccessListener { if (cont.isActive) cont.resume(it) }
                    .addOnFailureListener { if (cont.isActive) cont.resume(null) }
            }
        }.getOrNull() ?: return
        feed(loc.toFix())
    }

    companion object {
        const val UPDATE_INTERVAL_MS = 5L * 60 * 1000
        const val MIN_DISPLACEMENT_M = 200f
        const val WORK_ID = "pdj.location-poll"
        private const val ACTION = "com.levi.pocketdj.LOCATION_UPDATE"

        private fun pendingIntent(ctx: Context): PendingIntent {
            val i = Intent(ctx, FusedLocationReceiver::class.java).setAction(ACTION)
            // Location updates are written into the intent extras, so the PendingIntent must be mutable.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            return PendingIntent.getBroadcast(ctx, 0, i, flags)
        }
    }
}

fun android.location.Location.toFix() = DwellDetector.Fix(
    latitude, longitude, if (hasAccuracy()) accuracy.toDouble() else Double.MAX_VALUE, time,
)

/** Receives the fused updates (also delivered when the process was dead; builds the graph on demand). */
class FusedLocationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = runCatching { LocationResult.extractResult(intent) }.getOrNull() ?: return
        val pending = goAsync()
        Thread {
            try {
                val source = com.levi.pocketdj.di.AppGraph.get(context).collectionsGraph.fusedLocationSource()
                result.locations.sortedBy { it.time }.forEach { source?.feed(it.toFix()) }
            } catch (_: Exception) {
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/** Periodic coverage poll. Self-gated: does nothing unless places & trips is on and permitted. */
class LocationPollWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        runCatching {
            com.levi.pocketdj.di.AppGraph.get(applicationContext).collectionsGraph.fusedLocationSource()?.pollOnce()
        }
        return Result.success()
    }
}
