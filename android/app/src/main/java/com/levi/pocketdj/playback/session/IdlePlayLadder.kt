package com.levi.pocketdj.playback.session

/** What an idle-player remote ▶ resolves to. */
enum class IdlePlayVerdict(val token: String) {
    RESUME_HELD("resumeHeld"),
    START_IN_FLIGHT("startInFlight"),
    START_CURRENT("startCurrent"),
    LATCHED("latched"),
}

/**
 * The idle-play ladder (iOS onIdlePlay), called with an engine that holds no item: a deck that is
 * running -> held resumes, an in-flight start is ignored, otherwise the current row starts (a
 * cascade-halted / stopped / errored deck included). Only a deck that is not running latches.
 */
object IdlePlayLadder {
    fun decide(runExists: Boolean, held: Boolean, startPending: Boolean): IdlePlayVerdict = when {
        !runExists -> IdlePlayVerdict.LATCHED
        held -> IdlePlayVerdict.RESUME_HELD
        startPending -> IdlePlayVerdict.START_IN_FLIGHT
        else -> IdlePlayVerdict.START_CURRENT
    }
}

/** `pendingRemotePlayAt`: a remote ▶ with nothing to play, consumed by a restore within [windowMs]. */
class RemotePlayLatch(
    private val clock: () -> Long = System::currentTimeMillis,
    private val windowMs: Long = WINDOW_MS,
) {
    @Volatile private var armedAt: Long? = null

    fun arm() { armedAt = clock() }

    /** A fresh play happened: whatever was latched is moot. */
    fun clear() { armedAt = null }

    /** True (and clears) when armed within the window; a stale latch is dropped. */
    fun consume(): Boolean {
        val at = armedAt ?: return false
        armedAt = null
        return clock() - at <= windowMs
    }

    val isArmed: Boolean get() = armedAt != null

    companion object { const val WINDOW_MS = 15_000L }
}
