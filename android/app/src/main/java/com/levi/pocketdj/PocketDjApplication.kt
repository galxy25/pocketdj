package com.levi.pocketdj

import android.app.Application
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.data.storage.SweepTicker
import com.levi.pocketdj.data.storage.TemporarySweep
import com.levi.pocketdj.shell.AppLifecycleObserver
import com.levi.pocketdj.work.WorkScheduler
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Installs the lifecycle doctrine. The AppGraph is NOT built here: a WorkManager cold start
 * builds only what the worker touches, and the UI paths (first ON_START / MainActivity) build
 * the full graph, so a background wake does not pay for a launch plus a forced endpoint fetch.
 */
class PocketDjApplication : Application(), androidx.appfunctions.service.AppFunctionConfiguration.Provider {
    /**
     * P2-SURF-12: how the AppFunctions library builds [com.levi.pocketdj.assistant.PocketDjAppFunctions]. Only the
     * library's API-36 service ever asks (minSdk stays 35); the graph is built lazily on the first Gemini call.
     */
    override val appFunctionConfiguration: androidx.appfunctions.service.AppFunctionConfiguration
        get() = androidx.appfunctions.service.AppFunctionConfiguration.Builder()
            .addEnclosingClassFactory(com.levi.pocketdj.assistant.PocketDjAppFunctions::class.java) {
                com.levi.pocketdj.assistant.PocketDjAppFunctions(AppGraph.get(this).shellGraph.appFunctionsAdapter())
            }
            .build()

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {
            // Debug-only: log (never crash on) disk work on Main so emulator runs can grep `StrictMode` for mix/* offenders.
            android.os.StrictMode.setThreadPolicy(
                android.os.StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites().penaltyLog().build(),
            )
        }
        val scheduler = WorkScheduler(this)
        val firstForeground = AtomicBoolean(true)
        val firstForeground2 = AtomicBoolean(true)
        // Hourly temporary-asset sweep while the app is in the foreground (started/stopped with it).
        val sweepTicker = lazy {
            val g = AppGraph.get(this)
            SweepTicker(g.appScope, TemporarySweep.INTERVAL_MS) {
                g.servicesGraph.storageManager.sweepTemporaryIfDue("tick", minIntervalMs = TemporarySweep.INTERVAL_MS - 60_000L)
            }
        }
        AppLifecycleObserver(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            onForeground = listOf(
                // Launch fetch is forced once per process; later foregrounds are throttled.
                { AppGraph.get(this).refreshEndpoints(force = firstForeground.getAndSet(false)) },
                { AppLifecycleObserver.widgetDrain() },
                // Pre-release albums: recheck on every foreground (self-gated to daily per album; iOS parity).
                { AppGraph.get(this).browseGraph.refreshProvisionalAlbums() },
                // Process death: re-park the persisted mix (file read off Main, park on Main) so the lock screen /
                // Auto row / Mix tab see it without anyone opening Mix. Once per process.
                { AppGraph.get(this).mixGraph.launchRestore() },
                { scheduler.ensureScheduled(AppGraph.get(this).features.periodicWork) },
                // WorkManager periodic work can slip for days under Doze/standby: also try the (self-gated,
                // cheap) soft-cap prune on every foreground, deferred well past launch (iOS does the same).
                {
                    val g = AppGraph.get(this)
                    g.appScope.launch(Dispatchers.IO) {
                        delay(15_000)
                        runCatching { g.servicesGraph.storageManager.pruneIfDue() }
                    }
                },
                // Temporary (Mix Mode buffer) asset expiry sweep: launch (first foreground, after the first
                // frame) and every foreground, gated to once per 5 min; then the hourly tick.
                {
                    val g = AppGraph.get(this)
                    val reason = if (firstForeground2.getAndSet(false)) "launch" else "foreground"
                    g.appScope.launch(Dispatchers.IO) {
                        delay(3_000)
                        runCatching { g.servicesGraph.storageManager.sweepTemporaryIfDue(reason, minIntervalMs = 5 * 60 * 1000L) }
                    }
                    sweepTicker.value.start()
                },
            ),
            onBackground = listOf({ if (sweepTicker.isInitialized()) sweepTicker.value.stop() }),
            flush = { AppGraph.get(this).flushNow() },
        ).install()
    }
}
