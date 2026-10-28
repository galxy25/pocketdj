package com.levi.pocketdj

import android.app.Application
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.AppLifecycleObserver
import com.levi.pocketdj.work.WorkScheduler

/** Builds the graph at process start and installs the lifecycle doctrine. */
class PocketDjApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val graph = AppGraph.get(this)
        val scheduler = WorkScheduler(this)
        AppLifecycleObserver(
            scope = graph.appScope,
            onForeground = listOf(
                { graph.refreshEndpoints() },
                { AppLifecycleObserver.widgetDrain() },
                { scheduler.ensureScheduled(graph.features.periodicWork) },
            ),
            flush = { graph.flushRegistry.flushAll(graph.features.flushables) },
        ).install()
    }
}
