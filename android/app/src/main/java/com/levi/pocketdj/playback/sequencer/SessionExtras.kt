package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.durable.SessionDjMode
import com.levi.pocketdj.playback.durable.SessionFxLock
import com.levi.pocketdj.playback.durable.SessionNpMixMode
import com.levi.pocketdj.playback.durable.SnapshotExtras

/**
 * A typed key of the durable snapshot's optional session state (the P2-DATA-1 DTOs): how a value of type [T]
 * is read out of / put into [SnapshotExtras].
 */
class SessionExtraKey<T : Any>(
    val name: String,
    internal val read: (SnapshotExtras) -> T?,
    internal val put: (SnapshotExtras, T) -> SnapshotExtras,
) {
    override fun toString() = name

    companion object {
        val NP_MIX_MODE = SessionExtraKey<SessionNpMixMode>("npMixMode", { it.npMixMode }, { e, v -> e.copy(npMixMode = v) })
        val FX_LOCK = SessionExtraKey<SessionFxLock>("fxLock", { it.fxLock }, { e, v -> e.copy(fxLock = v) })
        val DJ_MODE = SessionExtraKey<SessionDjMode>("djMode", { it.djMode }, { e, v -> e.copy(djMode = v) })
    }
}

/**
 * A feature's side of the durable session (Mix Mode, FX Lock, DJ Mode).
 *
 *  - [write] is read by the session writer on every snapshot save. Return the value to persist, or null to leave
 *    whatever is already stored untouched (a feature that is OFF should return its `enabled = false` DTO, not
 *    null, if it wants the off state stored).
 *  - [restoreHeld] receives the stored value when a session is restored HELD. It must NOT arm anything: no
 *    planning, analysis, buffering or audio before the first play (the sequencer fires `onResumedFromHold`).
 */
interface SessionExtra<T : Any> {
    val key: SessionExtraKey<T>
    fun write(): T?
    fun restoreHeld(value: T)
}

/**
 * Registry of [SessionExtra]s. The sequencer owns one; the session writer reads it on save, and the held
 * restore delivers into it. Main-thread only, like the rest of the sequencer.
 */
class SessionExtras {
    private val extras = LinkedHashMap<String, SessionExtra<*>>()

    /** Set by the session writer: a feature changed its state, persist now. */
    @Volatile var onChanged: () -> Unit = {}

    /** The stored values of the held restore still waiting for its first play; a late registrant is handed them. */
    private var heldStored: SnapshotExtras? = null

    /** Registering a key twice replaces the earlier registration. A held restore already delivered reaches a late registrant too. */
    fun register(extra: SessionExtra<*>) {
        extras[extra.key.name] = extra
        heldStored?.let { deliver(extra, it) {} }
    }

    /** The held deck left hold / the run ended or was replaced: nothing is pending delivery any more. */
    fun clearHeld() { heldStored = null }
    fun unregister(key: SessionExtraKey<*>) { extras.remove(key.name) }
    val registeredKeys: Set<String> get() = extras.keys.toSet()

    /** A feature toggled: ask the writer to persist the new value. */
    fun notifyChanged() = onChanged()

    /** [base] with every registered feature's [SessionExtra.write] applied (a throwing feature keeps its stored value). */
    fun collect(base: SnapshotExtras, log: (String) -> Unit = {}): SnapshotExtras {
        var out = base
        for (e in extras.values) out = write(e, out, log)
        return out
    }

    private fun <T : Any> write(e: SessionExtra<T>, base: SnapshotExtras, log: (String) -> Unit): SnapshotExtras {
        val v = try { e.write() } catch (t: Exception) { log("[session] extra ${e.key} write threw ${t.message}"); null }
        return if (v == null) base else e.key.put(base, v)
    }

    /** Deliver the stored values of a restored snapshot to the registered features (HELD: nothing is armed). */
    fun restoreHeld(stored: SnapshotExtras, log: (String) -> Unit = {}) {
        heldStored = stored
        for (e in extras.values) deliver(e, stored, log)
    }

    private fun <T : Any> deliver(e: SessionExtra<T>, stored: SnapshotExtras, log: (String) -> Unit) {
        val v = e.key.read(stored) ?: return
        try { e.restoreHeld(v) } catch (t: Exception) { log("[session] extra ${e.key} restoreHeld threw ${t.message}") }
    }
}
