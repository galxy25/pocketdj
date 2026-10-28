package com.levi.pocketdj.screens.nowplaying

/** What ⏯ resolved to (iOS `togglePlayPause` ladder). */
enum class TransportVerdict(val token: String) {
    RESUME_FROM_HOLD("resumeFromHold"),
    START_CURRENT("startCurrent"),
    APPLE_MUSIC_TOGGLE("amToggle"),
    IGNORED_START_IN_FLIGHT("ignoredStartInFlight"),
    TOGGLE("toggle"),
}

/** Everything the ladder reads, as plain values (the test seam). */
data class TransportInputs(
    /** Restored session waiting for its first explicit play. */
    val held: Boolean,
    /** Running deck whose current row never sounded (cascade-halted / never started). */
    val pausedByCascade: Boolean,
    /** Apple Music owns audio. */
    val appleMusicActive: Boolean,
    /** The audio engine holds no item. */
    val engineIdle: Boolean,
    /** The sequencer's start of the current row is still in flight. */
    val startPending: Boolean,
)

/** The side effects the ladder drives. */
interface TransportPort {
    fun resumeFromHold()
    fun startCurrent()
    fun toggleAppleMusic()
    fun togglePlayPauseEngine()
    fun log(line: String)
}

object NowPlayingTransport {
    const val IGNORED_LOG = "[playback] ▶ ignored: start in flight"

    /** Pure decision: held -> cascade -> AM -> idle(pending ignored | start) -> toggle. */
    fun decide(i: TransportInputs): TransportVerdict = when {
        i.held -> TransportVerdict.RESUME_FROM_HOLD
        i.pausedByCascade -> TransportVerdict.START_CURRENT
        i.appleMusicActive -> TransportVerdict.APPLE_MUSIC_TOGGLE
        i.engineIdle && i.startPending -> TransportVerdict.IGNORED_START_IN_FLIGHT
        i.engineIdle -> TransportVerdict.START_CURRENT
        else -> TransportVerdict.TOGGLE
    }

    fun togglePlayPause(inputs: TransportInputs, port: TransportPort): TransportVerdict {
        val verdict = decide(inputs)
        when (verdict) {
            TransportVerdict.RESUME_FROM_HOLD -> port.resumeFromHold()
            TransportVerdict.START_CURRENT -> port.startCurrent()
            TransportVerdict.APPLE_MUSIC_TOGGLE -> port.toggleAppleMusic()
            TransportVerdict.IGNORED_START_IN_FLIGHT -> port.log(IGNORED_LOG)
            TransportVerdict.TOGGLE -> port.togglePlayPauseEngine()
        }
        return verdict
    }
}
