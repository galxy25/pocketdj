package com.levi.pocketdj.playback.session

/** What an idle-player remote ▶ resolves to. */
enum class IdlePlayVerdict(val token: String) {
    RESUME_HELD("resumeHeld"),
    START_IN_FLIGHT("startInFlight"),
    START_CURRENT("startCurrent"),
    LATCHED("latched"),
}

/** The idle-play ladder (iOS onIdlePlay): held -> resume; start pending -> ignore; never sounded -> start; else latch. */
object IdlePlayLadder {
    fun decide(held: Boolean, startPending: Boolean, currentNeverSounded: Boolean): IdlePlayVerdict = when {
        held -> IdlePlayVerdict.RESUME_HELD
        startPending -> IdlePlayVerdict.START_IN_FLIGHT
        currentNeverSounded -> IdlePlayVerdict.START_CURRENT
        else -> IdlePlayVerdict.LATCHED
    }
}

/** `pendingRemotePlayAt`: a remote ▶ with nothing to play, consumed by a restore within [windowMs]. */
class RemotePlayLatch(
    private val clock: () -> Long = System::currentTimeMillis,
    private val windowMs: Long = WINDOW_MS,
) {
    @Volatile private var armedAt: Long? = null

    fun arm() { armedAt = clock() }

    /** True (and clears) when armed within the window; a stale latch is dropped. */
    fun consume(): Boolean {
        val at = armedAt ?: return false
        armedAt = null
        return clock() - at <= windowMs
    }

    val isArmed: Boolean get() = armedAt != null

    companion object { const val WINDOW_MS = 15_000L }
}
