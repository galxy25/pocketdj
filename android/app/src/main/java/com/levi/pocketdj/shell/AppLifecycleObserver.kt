package com.levi.pocketdj.shell

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Process-level foreground/background doctrine. ON_START: refresh endpoints (throttled
 * inside), drain widget commands (hook, no-op until WID-1), ensure periodic work.
 * ON_STOP: flush debounced writers.
 */
class AppLifecycleObserver(
    private val scope: CoroutineScope,
    private val onForeground: List<() -> Unit>,
    private val flush: suspend () -> Unit,
) : DefaultLifecycleObserver {

    override fun onStart(owner: LifecycleOwner) {
        for (hook in onForeground) runCatching { hook() }
    }

    override fun onStop(owner: LifecycleOwner) {
        scope.launch { runCatching { flush() } }
    }

    fun install() = ProcessLifecycleOwner.get().lifecycle.addObserver(this)

    companion object {
        /** Widget pending-command drain; WID-1 replaces this. */
        @Volatile var widgetDrain: () -> Unit = {}
    }
}
