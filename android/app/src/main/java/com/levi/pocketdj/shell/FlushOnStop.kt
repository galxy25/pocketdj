package com.levi.pocketdj.shell

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking

/**
 * ON_STOP funnel: runs every module [Flushable] BLOCKING (on Dispatchers.IO) so the writes land
 * before the process can be frozen/killed after backgrounding. Attach to ProcessLifecycleOwner.
 */
class FlushOnStop(private val registry: FeatureModuleRegistry) : DefaultLifecycleObserver {
    override fun onStop(owner: LifecycleOwner) {
        runBlocking(Dispatchers.IO) { registry.flushAll() }
    }
}
