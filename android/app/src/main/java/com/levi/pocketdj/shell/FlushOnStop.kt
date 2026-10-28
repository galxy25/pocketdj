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
    private companion object { const val FLUSH_BUDGET_MS = 2_500L }

    override fun onStop(owner: LifecycleOwner) {
        // Bounded: a slow module flush (network diag upload, big documents) must not freeze the main looper.
        runBlocking(Dispatchers.IO) { kotlinx.coroutines.withTimeoutOrNull(FLUSH_BUDGET_MS) { registry.flushAll() } }
    }
}
