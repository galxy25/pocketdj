package com.levi.pocketdj.playback.health

import com.levi.pocketdj.diag.NPLog
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * "KEEP PLAYING" SUPERVISOR - the setlist lane (iOS `PlaybackSupervisor`). A 1 Hz watchdog over the one
 * invariant the drive logs kept breaking: while the listener wants the set playing, something is audibly
 * playing. Every tick the [Shell] builds a [Probe] and feeds it to the pure [Core], which decides whether to
 * log and which recovery step (if any) to take.
 *
 * SAFETY RULES: never acts while the listener paused ([Probe.intentPlaying] false / [Probe.userPaused]),
 * during an interruption, on a HELD restore, or after the cascade breaker halted the set. It does NOT fight
 * the start watchdog: while a start window is open ([Probe.startPending]) it only COUNTS dead air. The Apple
 * Music lane is DETECTOR-ONLY. A track that already signalled its end is detector-only.
 *
 * Ladder (timers reset on proof; anchored when the start window closes):
 * L0 silent -> log; L1 @3 s re-kick in place; L2 @+12 s retry the row in place (<= 2 per song); L3 @+8 s escalate.
 * Every 60 s with dead air it logs the running `dead-air total`.
 */
object PlaybackSupervisor {

    enum class Lane(val raw: String) { IDLE("idle"), LOCAL("local"), APPLE_MUSIC("appleMusic") }

    data class Probe(
        val lane: Lane = Lane.IDLE,
        /** The listener's last request was "play". */
        val intentPlaying: Boolean = false,
        /** The current item was paused ON PURPOSE. */
        val userPaused: Boolean = false,
        val interruptionOpen: Boolean = false,
        val held: Boolean = false,
        val cascadeHalted: Boolean = false,
        /** A track start window is open (owned by the start watchdog). */
        val startPending: Boolean = false,
        /** The current item already signalled its end (the sequencer's advance owns it). */
        val trackEnded: Boolean = false,
        /** Proof of sound this tick. */
        val audible: Boolean = false,
        val songId: String? = null,
    )

    enum class Action { REKICK, RETRY_IN_PLACE, ESCALATE }

    data class Config(
        val l1Seconds: Double = 3.0,
        val l2Seconds: Double = 12.0,
        val l3Seconds: Double = 8.0,
        /** L2 retries allowed per song before the ladder goes straight to escalation. */
        val maxRetriesPerSong: Int = 2,
        val reportWindowSeconds: Double = 60.0,
    )

    data class Step(val action: Action?, val lines: List<String>)

    /** The pure state machine; table-driven tests drive it with a fake clock (epoch ms). */
    class Core(private val config: Config = Config()) {
        private var silentSince: Long? = null
        private var ladderAnchor: Long? = null
        var stage = 0
            private set

        var deadAirTotal = 0.0
            private set

        /** Seconds the lane was ENGAGED (listener wants sound, lane owned) - dead air's denominator. */
        var activeTotal = 0.0
            private set

        /** The share of [deadAirTotal] spent inside a track start / after the track ended. */
        var transitionDeadTotal = 0.0
            private set

        private var windowDeadAir = 0.0
        private var windowStart: Long? = null
        private var lastTick: Long? = null
        private var haltedLogged = false
        private val retries = HashMap<String, Int>()

        fun step(p: Probe, now: Long): Step {
            val lines = ArrayList<String>()
            val dt = lastTick?.let { ((now - it) / 1000.0).coerceIn(0.0, 5.0) } ?: 0.0
            lastTick = now
            if (windowStart == null) windowStart = now
            val ws = windowStart!!
            if ((now - ws) / 1000.0 >= config.reportWindowSeconds) {
                if (windowDeadAir >= 1) {
                    lines += "dead-air total=${deadAirTotal.roundToInt()}s last60=${windowDeadAir.roundToInt()}s"
                }
                windowDeadAir = 0.0
                windowStart = now
            }
            val engaged = p.lane != Lane.IDLE && p.intentPlaying && !p.userPaused && !p.held && !p.interruptionOpen
            if (!engaged) {
                reset()
                haltedLogged = false
                return Step(null, lines)
            }
            if (p.cascadeHalted) {
                if (!haltedLogged) {
                    lines += "halted lane=${p.lane.raw} song=${p.songId ?: "?"} (cascade breaker) — holding"
                    haltedLogged = true
                }
                reset()
                return Step(null, lines)
            }
            haltedLogged = false
            activeTotal += dt
            if (p.audible) {
                silentSince?.let {
                    lines += "ok after=${((now - it) / 1000.0).roundToInt()}s lane=${p.lane.raw} stage=L$stage"
                }
                reset()
                return Step(null, lines)
            }
            // SILENT while the listener wants sound - dead air.
            deadAirTotal += dt
            windowDeadAir += dt
            if (p.startPending || p.trackEnded) transitionDeadTotal += dt
            if (silentSince == null) {
                silentSince = now
                lines += "silent owner=${if (p.lane == Lane.APPLE_MUSIC) "AppleMusic" else "PlayerEngine"} lane=${p.lane.raw} " +
                    "song=${p.songId ?: "?"} since=0s startPending=${if (p.startPending) 1 else 0} ended=${if (p.trackEnded) 1 else 0}"
            }
            // Detector-only states: the start watchdog / sequencer / AM provider own these.
            if (p.startPending || p.trackEnded || p.lane == Lane.APPLE_MUSIC) {
                ladderAnchor = null
                stage = 0
                return Step(null, lines)
            }
            if (ladderAnchor == null) ladderAnchor = now
            val elapsed = (now - ladderAnchor!!) / 1000.0
            val since = ((now - silentSince!!) / 1000.0).roundToInt()
            val song = p.songId ?: "?"
            if (stage == 0 && elapsed >= config.l1Seconds) {
                stage = 1
                lines += "step=L1 action=rekick song=$song silent=${since}s"
                return Step(Action.REKICK, lines)
            }
            if (stage == 1 && elapsed >= config.l1Seconds + config.l2Seconds) {
                stage = 2
                val n = retries[song] ?: 0
                if (n < config.maxRetriesPerSong) {
                    retries[song] = n + 1
                    lines += "step=L2 action=retryInPlace song=$song silent=${since}s retry=${n + 1}"
                    return Step(Action.RETRY_IN_PLACE, lines)
                }
                stage = 3
                lines += "step=L3 action=escalate song=$song silent=${since}s (retries exhausted)"
                return Step(Action.ESCALATE, lines)
            }
            if (stage == 2 && elapsed >= config.l1Seconds + config.l2Seconds + config.l3Seconds) {
                stage = 3
                lines += "step=L3 action=escalate song=$song silent=${since}s"
                return Step(Action.ESCALATE, lines)
            }
            return Step(null, lines)
        }

        private fun reset() {
            silentSince = null
            ladderAnchor = null
            stage = 0
        }
    }

    /**
     * Live engines -> probe; actions -> engines. [tick] is public so tests drive it directly; [start] runs it
     * at 1 Hz and [stopTicking] cancels it (the sequencer ticks only while a run exists).
     */
    class Shell(
        private val scope: CoroutineScope,
        private val probe: () -> Probe,
        private val perform: (Action) -> Unit,
        private val nowMs: () -> Long = System::currentTimeMillis,
        private val log: (String) -> Unit = { NPLog.lane(NPLog.SUPERVISOR, it) },
        /** Where each tick's active / dead seconds roll up (null in shell tests). */
        var meter: DeadAirMeter? = null,
        config: Config = Config(),
        private val periodMs: Long = 1_000,
    ) {
        val core = Core(config)
        private var ticker: Job? = null

        /** Actions taken (diagnostics + tests). */
        val actionsTaken = ArrayList<Action>()

        val isTicking: Boolean get() = ticker?.isActive == true

        fun start() {
            if (isTicking) return
            ticker = scope.launch {
                while (isActive) {
                    delay(periodMs)
                    tick()
                }
            }
        }

        fun stopTicking() {
            ticker?.cancel()
            ticker = null
        }

        fun tick() {
            val p = probe()
            val at = nowMs()
            val before = Triple(core.activeTotal, core.deadAirTotal, core.transitionDeadTotal)
            val step = core.step(p, at)
            step.lines.forEach(log)
            meter?.let { m ->
                m.accumulate(
                    active = core.activeTotal - before.first,
                    dead = core.deadAirTotal - before.second,
                    transitionDead = core.transitionDeadTotal - before.third,
                    nowMs = at,
                )
                // The listener paused / a call / a held restore mid-start: that silence is theirs.
                if (!p.intentPlaying || p.userPaused || p.held || p.interruptionOpen) {
                    m.transitionAbandoned(if (p.interruptionOpen) "interruption" else if (p.held) "held" else "paused")
                }
            }
            step.action?.let {
                actionsTaken += it
                perform(it)
            }
        }
    }
}
