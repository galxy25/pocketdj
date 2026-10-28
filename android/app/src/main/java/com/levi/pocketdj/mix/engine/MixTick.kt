package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Production [TickDriver]: a coroutine on the supplied (Main) scope, `delay(interval)` between fires. */
class CoroutineTickDriver(private val scope: CoroutineScope) : TickDriver {
    override fun start(intervalMs: Long, block: () -> Boolean): AutoCloseable {
        val job: Job = scope.launch {
            while (isActive) {
                delay(intervalMs)
                if (!isActive || !block()) break
            }
        }
        return AutoCloseable { job.cancel() }
    }
}

/**
 * The ~10 Hz engine tick (iOS `tickFire`): advances playheads at rate x wall time with dt clamped
 * to 0.5 s, retires decks that reach their end outside a RUNNING auto mix, runs the watchdog when
 * the mix wants audio but the sink is not rendering, steps the Auto-DJ, throttles playhead writes
 * into the durable session, and stops itself when fully idle.
 */
internal class MixTick(private val e: MixEngine, private val driver: TickDriver) {
    private var handle: AutoCloseable? = null
    private var lastTickAt = 0L
    private var lastHeartbeatAt = 0L
    private var lastWatchdogAt = Long.MIN_VALUE / 2
    private var lastRendering: Boolean? = null

    val isTicking: Boolean get() = handle != null

    fun startIfNeeded() {
        if (handle != null) return
        lastTickAt = e.nowMs()
        handle = driver.start(INTERVAL_MS) { fire() }
    }

    fun stop() { handle?.close(); handle = null }

    /** One tick. Returns false (-> the driver stops) when fully idle. */
    fun fire(): Boolean {
        val now = e.nowMs()
        // A suspension or stopped-engine stall must not teleport playheads to end-of-track.
        val dt = (((now - lastTickAt).coerceAtLeast(0)) / 1000.0).coerceAtMost(MAX_DT)
        lastTickAt = now
        val rendering = e.isRendering
        if (lastRendering != rendering) {
            e.diag("render ${lastRendering ?: "nil"}->$rendering")
            lastRendering = rendering
        }
        heartbeat(now, rendering)

        if (rendering) {
            for (d in Deck.entries) if (e.deckState(d).isPlaying) advance(d, dt)
        } else if (e.mixWantsAudio) {
            // WATCHDOG (only while the mix WANTS audio): the system stopped the sink under a live
            // mix. Positions deliberately do NOT advance: nothing is rendering. ~1 try/s.
            if (now - lastWatchdogAt >= WATCHDOG_MS) {
                lastWatchdogAt = now
                e.watchdogRecover()
            }
        }
        e.refreshTransport()
        if (rendering) e.autoDj?.takeIf { it.isMixing }?.fire(now)
        e.persistPositions()
        val active = e.deckState(Deck.A).isPlaying || e.deckState(Deck.B).isPlaying || e.autoMixing
        if (!active) { handle = null; return false }
        return true
    }

    private fun advance(d: Deck, dt: Double) {
        val st = e.deckState(d)
        val dur = e.duration(d)
        if (dur <= 0) {                 // nothing / zero-length loaded: don't run the playhead forever
            if (!e.autoMixing) { e.setPlaying(d, false); e.controller(d).pause() }
            return
        }
        if (e.streamHeld(d)) {          // streaming: waiting for bytes, the playhead is frozen
            e.autoDj?.onDeckHeld(d, dt)
            return
        }
        val loop = e.loopWindow(d)
        if (loop != null) {
            var p = e.position(d) + dt * st.rate
            if (p >= loop.second) p = loop.first + (p - loop.first) % (loop.second - loop.first)
            e.setPosition(d, p)
            return
        }
        val pos = minOf(e.position(d) + dt * st.rate, dur)   // source advances at rate x wall time
        e.setPosition(d, pos)
        val autoRunning = e.autoMixing && e.autoDj?.isPaused != true
        if (pos >= dur && !autoRunning) {
            // A SUSPENDED machine never transitions, so a deck reaching its end retires like a
            // manual deck; otherwise it "plays" at dur forever.
            e.setPlaying(d, false)
            e.controller(d).pause()
        }
    }

    /** One liveness line per second while anything plays: which layer is alive (iOS `mixdiag`). */
    private fun heartbeat(now: Long, rendering: Boolean) {
        val a = e.deckState(Deck.A); val b = e.deckState(Deck.B)
        if (!a.isPlaying && !b.isPlaying) return
        if (now - lastHeartbeatAt < 1000) return
        lastHeartbeatAt = now
        e.diag(
            "hb render=${if (rendering) 1 else 0} tapAge=${String.format(java.util.Locale.US, "%.2f", e.tapAgeSeconds(false))} " +
                "sigAge=${String.format(java.util.Locale.US, "%.2f", e.tapAgeSeconds(true))} A=${deckBeat(Deck.A)} B=${deckBeat(Deck.B)} " +
                "auto=${if (e.autoMixing) 1 else 0}/${if (e.autoDj?.isPaused == true) 1 else 0}",
        )
    }

    private fun deckBeat(d: Deck): String =
        "(${if (e.deckState(d).isPlaying) 1 else 0},${if (e.controller(d).isVoicePlaying) 1 else 0}," +
            String.format(java.util.Locale.US, "%.1f", e.position(d)) + ")"

    companion object {
        const val INTERVAL_MS = 100L
        const val MAX_DT = 0.5
        const val WATCHDOG_MS = 1000L
    }
}
