package com.levi.pocketdj

import android.app.Application
import com.levi.pocketdj.di.AppGraph
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
class PocketDjApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val scheduler = WorkScheduler(this)
        val firstForeground = AtomicBoolean(true)
        AppLifecycleObserver(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            onForeground = listOf(
                // Launch fetch is forced once per process; later foregrounds are throttled.
                { AppGraph.get(this).refreshEndpoints(force = firstForeground.getAndSet(false)) },
                { AppLifecycleObserver.widgetDrain() },
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
            ),
            flush = { AppGraph.get(this).flushNow() },
        ).install()
    }
}
