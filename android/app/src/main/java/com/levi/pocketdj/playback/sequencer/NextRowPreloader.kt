package com.levi.pocketdj.playback.sequencer

/**
 * PB-10: the bookkeeping + decision half of the gapless preload window. ExoPlayer's playlist is NOT
 * the queue; the sequencer keeps ownership and this class only decides which single row (if any)
 * sits in window slot 1 behind the current one, and remembers what the engine was told.
 *
 * Pure (no Android, no coroutines) so the add / replace / remove / AUTO-transition rules are JVM
 * testable. When [enabled] is false every decision is "nothing in the window" = PB-3 behaviour.
 */
class NextRowPreloader(var enabled: Boolean = true) {

    /** The queue row that should sit in slot 1 and its index in the queue. */
    data class Target(val index: Int, val item: QueueItem)

    /** What the engine holds in slot 1. */
    data class Slot(val uid: String, val songId: String, val resolveId: String, val source: RowSource) {
        fun matches(observedId: String): Boolean = observedId == songId || observedId == resolveId
    }

    sealed interface Plan {
        data object None : Plan
        data object Keep : Plan
        data object Remove : Plan
        data class Add(val target: Target, val source: RowSource) : Plan
        data class Replace(val target: Target, val source: RowSource) : Plan
    }

    var slot: Slot? = null
        private set

    /**
     * Which row plays after the current one by NATURAL end, when that boundary may be handed to the
     * engine. Null when the next play is a replay (repeat ONE, remaining repeatCount passes, a
     * duplicate consecutive row), when there is no next, or when the boundary reshuffles
     * (repeat ALL wrap under shuffle) so the next row is not known yet.
     */
    fun target(
        queue: List<QueueItem>,
        index: Int,
        repeat: RepeatMode,
        shuffle: Boolean,
        playsRemaining: Int,
        active: Boolean,
    ): Target? {
        if (!enabled || !active) return null
        val cur = queue.getOrNull(index) ?: return null
        if (repeat == RepeatMode.ONE || playsRemaining > 1) return null
        var n = index + 1
        if (n >= queue.size) {
            if (repeat == RepeatMode.ALL && !shuffle && queue.size > 1) n = 0 else return null
        }
        val next = queue[n]
        if (next.cleanOnlySkip) return null // never loaded, never preloaded
        if (next.uid == cur.uid || next.id == cur.id) return null // replay path: seek to start, no duplicate item
        return Target(n, next)
    }

    /** Only a local file or a manifest rip stream may be pre-added; AM / rip-on-demand / unplayable never. */
    fun eligible(source: RowSource?): Boolean = source is LocalFileSource || source is StreamSource

    /** Reconcile the window with the desired [target] + its resolved [source]. */
    fun decide(target: Target?, source: RowSource?): Plan {
        val s = slot
        if (!enabled || target == null || !eligible(source)) return if (s != null) Plan.Remove else Plan.None
        return when {
            s == null -> Plan.Add(target, source!!)
            s.uid == target.item.uid && s.source == source -> Plan.Keep
            else -> Plan.Replace(target, source!!)
        }
    }

    /** The cheap, synchronous part: does the slot hold a row that is no longer the next one? */
    fun isStale(target: Target?): Boolean {
        val s = slot ?: return false
        return !enabled || target == null || s.uid != target.item.uid
    }

    fun noteInstalled(item: QueueItem, source: RowSource) {
        slot = Slot(item.uid, item.id, item.resolveId, source)
    }

    fun noteCleared() { slot = null }

    /**
     * The engine auto-transitioned onto [observedId]. Returns the slot when it is the preloaded row
     * (and consumes it - the window is empty until the next reconcile), else null.
     */
    fun consumeAutoTransition(observedId: String): Slot? {
        val s = slot ?: return null
        if (!s.matches(observedId)) return null
        slot = null
        return s
    }
}
