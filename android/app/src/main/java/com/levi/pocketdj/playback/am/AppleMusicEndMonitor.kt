package com.levi.pocketdj.playback.am

/**
 * WHY an Apple Music track ended (iOS `AppleMusicPlaybackProvider.EndReason`). The set reacts differently:
 * only [NATURAL] honours repeat-one / per-track repeat; [SYSTEM_SKIP] advances exactly like the in-app
 * next (never replays under repeat-one); [NEVER_STARTED] is a dead source (advance, never replay).
 */
enum class EndReason { NATURAL, SYSTEM_SKIP, NEVER_STARTED }

/** The SDK's three playback states (+ BUFFERING, which the monitor reads as "not playing yet"). */
enum class AmStatus { STOPPED, PLAYING, PAUSED, BUFFERING }

/**
 * Pure verdicts, ported 1:1 from the iOS provider (`trackEnded` / `endReason` / `trackRestarted` /
 * `neverStarted` / `stoppedByInterruption`). Times are SECONDS, like iOS.
 *
 * Why these exist: the OS (lock screen / Android Auto / a headset) can drive the SDK's player
 * directly, "skipping" past its ONE-SONG queue and parking it paused at ~0 or pinned at the end. A
 * listener pause mid-song never lands there, so the parked shapes count as ended.
 */
object EndVerdicts {
    /**
     * Seconds a play the SDK accepted may take to reach PLAYING before it counts as dead. NOTE: in production
     * `AppleMusicBackend.play` already waits (10 s confirm timeout) and returns false, so a never-started row
     * fails the LOAD before the monitor is armed; this path covers a monitor armed on an already-accepted play.
     */
    const val START_TIMEOUT_SECONDS = 12.0

    /** A STOPPED this far short of the track's length is an interruption, not the natural end. */
    const val INTERRUPTION_GRACE_SECONDS = 10.0

    /** null => not ended. */
    fun endReason(
        stopped: Boolean,
        paused: Boolean,
        playbackTime: Double,
        expectedDuration: Double,
        maxObserved: Double,
        intentionalPause: Boolean,
    ): EndReason? {
        if (stopped) return EndReason.NATURAL
        val atEnd = expectedDuration > 0 && playbackTime >= expectedDuration - 0.5
        if (paused) {
            if (atEnd) return EndReason.NATURAL
            if (playbackTime <= 1.0) {
                // 1. A hard backward reset to the top after real progress can only be the system skip,
                //    even when a pause was requested moments earlier (pause 0:30 -> car next -> park at 0).
                if (maxObserved >= 2.0) return EndReason.SYSTEM_SKIP
                // 2. Our own pause landed near the top (skip storm then pause). Sticky until resume.
                if (intentionalPause) return null
                // 3. Parked at the top from outside with no progress to reset from (rapid storm).
                return EndReason.SYSTEM_SKIP
            }
            return null
        }
        return if (atEnd) EndReason.NATURAL else null
    }

    fun trackEnded(
        stopped: Boolean,
        paused: Boolean,
        playbackTime: Double,
        expectedDuration: Double,
        maxObserved: Double,
        intentionalPause: Boolean,
    ): Boolean = endReason(stopped, paused, playbackTime, expectedDuration, maxObserved, intentionalPause) != null

    /** A still-PLAYING track restarted from outside (system previous rewinds the one-song queue). */
    fun trackRestarted(playbackTime: Double, maxObserved: Double): Boolean =
        playbackTime < 2.0 && maxObserved > 10.0

    /** Accepted-but-never-playing: a listener pause before audio started is not a dead source. */
    fun neverStarted(everPlayed: Boolean, waitedSeconds: Double, intentionalPause: Boolean): Boolean =
        !everPlayed && !intentionalPause && waitedSeconds >= START_TIMEOUT_SECONDS

    /** A STOPPED poll that is an external interruption (another player took over). Unknown length => never. */
    fun stoppedByInterruption(stopped: Boolean, expectedDuration: Double, playedSeconds: Double): Boolean =
        stopped && expectedDuration > 0 && playedSeconds < expectedDuration - INTERRUPTION_GRACE_SECONDS
}

/**
 * iOS `AppleMusicPlaybackProvider.reconcilePoll` / `advancedDespiteReportedPause` / `nearEnd`, pure.
 * The SDK's status can freeze at "paused" while the position keeps moving (the frozen-false field bug);
 * the monitor self-heals from the position, which cannot lie.
 */
object PollReconcile {
    /** Position must advance this many seconds between two polls to override a reported pause. */
    const val ADVANCE_EPSILON_SECONDS = 0.25

    /** Seconds before the end `NearEnd` fires (iOS `nearEndLeadSeconds`). */
    const val NEAR_END_LEAD_SECONDS = 8.0

    enum class Transition { RESUMED, SELF_HEALED, PAUSED }

    /** [isPlaying] = what the monitor should believe after this poll; [transition] only on a flip. */
    data class Verdict(val isPlaying: Boolean, val transition: Transition?)

    fun advancedDespiteReportedPause(playbackTime: Double, lastPollPlaybackTime: Double): Boolean =
        playbackTime - lastPollPlaybackTime > ADVANCE_EPSILON_SECONDS

    fun reconcile(reportedPlaying: Boolean, currentlyPlaying: Boolean, playbackTime: Double, lastPollPlaybackTime: Double): Verdict {
        // The self-heal PREEMPTS the paused-status read: a status that says paused while position moves is wrong.
        val really = reportedPlaying || advancedDespiteReportedPause(playbackTime, lastPollPlaybackTime)
        if (really == currentlyPlaying) return Verdict(currentlyPlaying, null)
        return if (really) Verdict(true, if (reportedPlaying) Transition.RESUMED else Transition.SELF_HEALED)
        else Verdict(false, Transition.PAUSED)
    }

    /** Inside the last [NEAR_END_LEAD_SECONDS] of a known length (too-short tracks never fire). */
    fun nearEnd(playbackTime: Double, expectedDuration: Double): Boolean =
        expectedDuration > NEAR_END_LEAD_SECONDS + 1 && playbackTime >= expectedDuration - NEAR_END_LEAD_SECONDS
}

/** One poll of the SDK. */
data class AmObservation(val status: AmStatus, val positionMs: Long)

/** What a tick concluded. */
sealed interface AmEvent {
    /** First PLAYING after [AppleMusicEndMonitor.arm] (closes the start window). */
    data object FirstAudio : AmEvent
    data class Ended(val reason: EndReason) : AmEvent

    /** System previous: the one-song queue rewound while still playing. */
    data object Restarted : AmEvent

    /** Stopped far short of the end (another player took over): hold, do not advance. */
    data class Interrupted(val atSeconds: Double) : AmEvent

    /** Back on air after an [Interrupted] hold. */
    data object Resumed : AmEvent

    /** ONCE per arm, inside the last 8 s while PLAYING: the sequencer may warm the next row (iOS `onNearEnd`). */
    data object NearEnd : AmEvent
}

/**
 * Per-row end detector (iOS `startStateMonitor`, reduced to its verdict core). The driver polls
 * [tick] every [POLL_MS] with the SDK's cold state; the SDK's `onItemEnded` calls [onSdkItemEnded].
 * One terminal event ([AmEvent.Ended]) per [arm]; the monitor is then finished until re-armed.
 *
 * Single-threaded by contract (Main).
 */
class AppleMusicEndMonitor(private val nowMs: () -> Long = System::currentTimeMillis) {
    private var armedAtMs = 0L
    private var lastTickMs = 0L
    private var lastStatus = AmStatus.STOPPED
    private var everPlayed = false
    private var finished = true
    private var expectedSeconds = 0.0
    private var maxObserved = 0.0
    private var wallPlayed = 0.0
    private var interruptedAt: Double? = null
    private var believedPlaying = false
    private var lastReported = AmStatus.STOPPED
    private var lastPollSeconds = 0.0
    private var nearEndFired = false

    /** Diagnostic hook for the self-heal / external pause lines (NPLog in production). */
    var trace: ((String) -> Unit)? = null

    /** Self-heals so far this arm (status said not-playing while position advanced). */
    var selfHealCount: Int = 0
        private set

    /** Sticky: OUR pause (button / adapter), cleared on resume. Distinguishes it from a parked skip. */
    @Volatile var intentionalPause: Boolean = false
        private set

    val isFinished: Boolean get() = finished
    val isInterrupted: Boolean get() = interruptedAt != null

    /** Where the interruption cut the track off (seconds), or null when not interrupted. */
    val interruptedAtSeconds: Double? get() = interruptedAt

    /** Begin watching a new row. [expectedDurationMs] is the catalog length (0/null => unknown). */
    fun arm(expectedDurationMs: Long?) {
        armedAtMs = nowMs()
        lastTickMs = armedAtMs
        lastStatus = AmStatus.STOPPED
        everPlayed = false
        finished = false
        expectedSeconds = (expectedDurationMs ?: 0L).coerceAtLeast(0L) / 1000.0
        maxObserved = 0.0
        wallPlayed = 0.0
        interruptedAt = null
        intentionalPause = false
        believedPlaying = false
        lastReported = AmStatus.STOPPED
        lastPollSeconds = 0.0
        nearEndFired = false
        selfHealCount = 0
    }

    fun disarm() {
        finished = true
    }

    fun noteIntentionalPause(paused: Boolean) {
        intentionalPause = paused
    }

    /** A seek we performed: re-base the progress high-water so a deliberate backward seek is not a system restart. */
    fun noteSeek(positionMs: Long) {
        maxObserved = positionMs / 1000.0
    }

    /** The SDK reported the item ended: a NATURAL end (once per arm). */
    fun onSdkItemEnded(): AmEvent? {
        if (finished || !everPlayed) return null
        finished = true
        return AmEvent.Ended(EndReason.NATURAL)
    }

    fun tick(obs: AmObservation): AmEvent? {
        if (finished) return null
        val now = nowMs()
        val dtSec = ((now - lastTickMs).coerceAtLeast(0L)) / 1000.0
        val t = obs.positionMs / 1000.0
        var status = obs.status

        if (!everPlayed) {
            if (status == AmStatus.PLAYING) {
                everPlayed = true
                lastTickMs = now
                lastStatus = status
                maxObserved = t
                believedPlaying = true
                lastReported = status
                lastPollSeconds = t
                return AmEvent.FirstAudio
            }
            lastTickMs = now
            val waited = (now - armedAtMs) / 1000.0
            if (EndVerdicts.neverStarted(everPlayed = false, waitedSeconds = waited, intentionalPause = intentionalPause)) {
                finished = true
                return AmEvent.Ended(EndReason.NEVER_STARTED)
            }
            return null
        }

        // iOS reconcilePoll: once we have genuinely played, a "paused" status over an advancing position is the
        // frozen-false bug - heal to PLAYING (the position cannot lie) so a parked-skip verdict never misfires.
        // A STOPPED/BUFFERING read is left alone (those carry their own verdicts).
        if (interruptedAt == null) {
            val reported = status == AmStatus.PLAYING
            val advanced = PollReconcile.advancedDespiteReportedPause(t, lastPollSeconds)
            if (status == AmStatus.PAUSED && advanced && lastReported != AmStatus.PLAYING) {
                // Two consecutive non-playing reads over an advancing position: frozen status, not a fresh pause.
                selfHealCount++
                trace?.invoke("AM monitor: self-heal - playbackTime advanced %.1fs while reported paused, correcting".format(t - lastPollSeconds))
                status = AmStatus.PLAYING
                intentionalPause = false
                believedPlaying = true
            } else {
                val v = PollReconcile.reconcile(reported, believedPlaying, t, lastPollSeconds)
                when (v.transition) {
                    PollReconcile.Transition.RESUMED, PollReconcile.Transition.SELF_HEALED -> { believedPlaying = true; intentionalPause = false; trace?.invoke("AM monitor: external RESUME at ${t.toInt()}s") }
                    PollReconcile.Transition.PAUSED -> { believedPlaying = false; trace?.invoke("AM monitor: external PAUSE at ${t.toInt()}s") }
                    null -> Unit
                }
            }
        }
        lastPollSeconds = t
        lastReported = obs.status

        // Wall-clock play time (frozen across pauses): our clock, since the SDK resets position on stop.
        if (lastStatus == AmStatus.PLAYING) wallPlayed += dtSec
        lastTickMs = now
        lastStatus = status

        interruptedAt?.let {
            if (status == AmStatus.PLAYING) {
                interruptedAt = null
                maxObserved = t // the re-queued item may read 0:00 before the resume seek lands
                intentionalPause = false
                return AmEvent.Resumed
            }
            return null
        }

        val stopped = status == AmStatus.STOPPED
        val played = maxOf(wallPlayed, maxObserved)
        if (EndVerdicts.stoppedByInterruption(stopped, expectedSeconds, played)) {
            interruptedAt = played
            return AmEvent.Interrupted(played)
        }
        if (t > maxObserved) maxObserved = t
        if (status == AmStatus.PLAYING && EndVerdicts.trackRestarted(t, maxObserved)) {
            maxObserved = t
            return AmEvent.Restarted
        }
        val reason = EndVerdicts.endReason(
            stopped = stopped,
            paused = status == AmStatus.PAUSED,
            playbackTime = t,
            expectedDuration = expectedSeconds,
            maxObserved = maxObserved,
            intentionalPause = intentionalPause,
        )
        if (reason != null) {
            finished = true
            return AmEvent.Ended(reason)
        }
        if (!nearEndFired && status == AmStatus.PLAYING &&
            PollReconcile.nearEnd(maxOf(t, wallPlayed), expectedSeconds)
        ) {
            nearEndFired = true
            return AmEvent.NearEnd
        }
        return null
    }

    companion object {
        const val POLL_MS = 400L
    }
}
