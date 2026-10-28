package com.levi.pocketdj.shell

import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.getAndUpdate

/**
 * The single pending-navigation slot (iOS `IntentServices.pendingRoute` + `routeMessage`).
 *
 * Contract:
 *  - [post] is set-then-replace, never queued: a newer request supersedes an unconsumed one.
 *  - [take] is an ATOMIC take (clear first): with several shell collectors only the first
 *    finds the route non-null — exactly iOS's multi-window discipline.
 *  - [signal] is a state flow so the shell can react to a post without polling; it is
 *    cleared by [take], so `signal.value != null` means "unconsumed".
 */
object NavRequestBus {
    private val slot = AtomicReference<ShellRoute?>(null)
    private val _signal = MutableStateFlow<ShellRoute?>(null)
    val signal: StateFlow<ShellRoute?> = _signal

    /** Browse's search-field hand-off (iOS `pendingBrowseQuery`), consumed by Browse. */
    private val _pendingBrowseQuery = MutableStateFlow<String?>(null)
    val pendingBrowseQuery: StateFlow<String?> = _pendingBrowseQuery

    /** "Can't open that" alert body; the shell shows it and calls [clearMessage]. */
    private val _routeMessage = MutableStateFlow<String?>(null)
    val routeMessage: StateFlow<String?> = _routeMessage

    fun post(route: ShellRoute) {
        slot.set(route)
        _signal.value = route
    }

    /** Atomically take the pending route, or null if none / already taken. */
    fun take(): ShellRoute? {
        val taken = slot.getAndSet(null)
        if (taken != null) _signal.compareAndSet(taken, null)
        // A concurrent post may have landed between getAndSet and the CAS; re-publish it.
        _signal.value = slot.get()
        return taken
    }

    fun setPendingBrowseQuery(query: String?) {
        _pendingBrowseQuery.value = query
    }

    fun takePendingBrowseQuery(): String? = _pendingBrowseQuery.getAndUpdate { null }

    fun postMessage(text: String) {
        _routeMessage.value = text
    }

    fun clearMessage() {
        _routeMessage.value = null
    }

    /** Test seam. */
    internal fun reset() {
        slot.set(null)
        _signal.value = null
        _pendingBrowseQuery.value = null
        _routeMessage.value = null
    }
}
