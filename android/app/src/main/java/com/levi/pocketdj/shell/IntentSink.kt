package com.levi.pocketdj.shell

import android.content.Intent

/**
 * MainActivity forwards EVERY launch intent and onNewIntent here and is never edited again
 * (decision D3). Handlers come from `FeatureModule.deepLinkHandlers` (installed by AppGraph)
 * or are registered directly. The first handler to return true consumes the intent.
 *
 * Intents that arrive before any handler is installed (cold start racing graph wiring)
 * are parked and replayed on the next [install].
 */
object IntentSink {
    private val lock = Any()
    private var handlers: List<DeepLinkHandler> = emptyList()
    private val parked = ArrayDeque<Intent>()

    /** Replace the handler list (AppGraph passes the aggregated list) and replay parked intents. */
    fun install(newHandlers: List<DeepLinkHandler>) {
        val replay: List<Intent>
        synchronized(lock) {
            handlers = newHandlers
            replay = if (newHandlers.isEmpty()) emptyList() else parked.toList().also { parked.clear() }
        }
        replay.forEach { dispatch(it) }
    }

    /** Offer [intent] to the handlers. @return true if one consumed it. */
    fun dispatch(intent: Intent): Boolean {
        val snapshot = synchronized(lock) {
            if (handlers.isEmpty()) {
                // Park only meaningful intents (data, extras, or a non-MAIN action) and keep just the
                // newest: a plain launcher intent carries nothing to replay later.
                if (intent.data != null || (intent.action != null && intent.action != Intent.ACTION_MAIN) ||
                    intent.extras?.isEmpty == false
                ) {
                    parked.clear()
                    parked.addLast(intent)
                }
                return false
            }
            handlers
        }
        return snapshot.any {
            runCatching { it.handle(intent) }
                .onFailure { e -> android.util.Log.e("PocketDJ", "[intent] handler failed for ${intent.action}", e) }
                .getOrDefault(false)
        }
    }

    internal fun reset() = synchronized(lock) {
        handlers = emptyList()
        parked.clear()
    }
}
