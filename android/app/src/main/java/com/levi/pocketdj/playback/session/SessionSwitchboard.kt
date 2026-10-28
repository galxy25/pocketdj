package com.levi.pocketdj.playback.session

import androidx.media3.common.Player

/**
 * The one-owner arbiter. Last-STARTED owns; a restored-never-sounded engine is not a remote
 * target; starting one owner pauses the other. [onChange] fires on every ownership change (the
 * service swaps the MediaSession player there).
 */
class SessionSwitchboard(
    private val log: (String) -> Unit = { TransportLog.sink(it) },
) {
    private val lock = Any()
    private var owner: TransportOwner? = null
    private var preferred: TransportOwner? = null
    private val registered = mutableListOf<TransportOwner>()

    /** Called (outside the lock) with the new owner, or null when ownership was resigned away. */
    @Volatile var onChange: (TransportOwner?) -> Unit = {}

    val current: TransportOwner? get() = synchronized(lock) { owner }

    fun register(o: TransportOwner) = synchronized(lock) { if (o !in registered) registered += o }

    /** [o] is gone for good (service destroyed): forget it entirely so nothing pauses a dead engine. */
    fun unregister(o: TransportOwner) {
        resign(o)
        synchronized(lock) {
            registered.remove(o)
            if (preferred === o) preferred = null
        }
    }

    /** [o] started producing audio: it owns the session; every other registered engine is paused. */
    fun setOwner(o: TransportOwner) {
        val others: List<TransportOwner>
        val changed: Boolean
        synchronized(lock) {
            register(o)
            changed = owner !== o
            owner = o
            if (preferred === o) preferred = null
            others = registered.filter { it !== o }
        }
        if (changed) log("switchboard owner=${o.engine}")
        others.forEach { it.pauseForHandoff() }
        if (changed) onChange(o)
    }

    /** After a restore: [o] answers the next remote command although nothing has sounded yet. */
    fun prefer(o: TransportOwner) = synchronized(lock) {
        register(o)
        preferred = o
    }

    /** [o] is done (stopped / released): the next-most-recent registered engine may claim; ExoPlayer is the fallback. */
    fun resign(o: TransportOwner) {
        val changed: Boolean
        synchronized(lock) {
            if (preferred === o) preferred = null
            changed = owner === o
            if (changed) owner = null
        }
        if (changed) {
            log("switchboard resign=${o.engine}")
            onChange(null)
        }
    }

    /** True when [o] is the engine that should answer a remote command right now. */
    fun isActive(o: TransportOwner): Boolean = synchronized(lock) {
        val target = owner ?: preferred
        target === o
    }

    /**
     * The engine a remote command goes to, or null when refused: a restored engine that never
     * sounded is not a target unless it was explicitly preferred.
     */
    fun remoteTarget(): TransportOwner? = synchronized(lock) {
        val o = owner ?: preferred ?: return null
        if (!o.hasSounded && preferred !== o && owner === o) return null
        o
    }

    /** Remote play against the current owner: logs refusal. Returns the target or null. */
    fun routeRemotePlay(): TransportOwner? {
        val t = remoteTarget()
        if (t == null) {
            val e = current?.engine ?: "none"
            TransportLog.rc(TransportLog.Cmd.PLAY, e, TransportLog.Verdict.REFUSED_IDLE)
        }
        return t
    }

    /** The Player the session should drive (the owner's, else [fallback] = ExoPlayer). */
    fun sessionPlayer(fallback: Player): Player = synchronized(lock) { (owner ?: preferred)?.sessionPlayer ?: fallback }

    companion object {
        /** Process-wide arbiter (service and controller share a process). */
        val shared = SessionSwitchboard()
    }
}
