package com.levi.pocketdj.di

/**
 * ANS-SHELL-1 (Q98): which process-start work belongs to which kind of start.
 *
 * - [StartTier.CORE]: every cold start, including a WorkManager / receiver wake. Settings, secrets, http, endpoint
 *   config, rips, collections: data seams only, NO recurring loops.
 * - [StartTier.PLAYBACK]: the PlaybackService / Android Auto / widget-driven playback. Adds the sequencer wiring,
 *   play stats, the Now Playing DSP, the widget bridge.
 * - [StartTier.INTERACTIVE]: the first foreground (MainActivity). Adds the rec-engine flush loop.
 *
 * Tiers are cumulative. This file is pure (no Android types) so the plan is JVM-testable.
 */
enum class StartTier { CORE, PLAYBACK, INTERACTIVE }

enum class StartStep(val tier: StartTier, val ownsLoop: Boolean = false) {
    ENDPOINTS(StartTier.CORE),
    BROWSE_SESSION(StartTier.CORE),
    SECRET_MIGRATION(StartTier.CORE),
    FAVORITE_SEAM(StartTier.CORE),
    BURN_RECONCILE(StartTier.CORE),
    INTENT_SINK(StartTier.CORE),

    /** Sequencer seams + the (run-gated) 1 Hz session tick. */
    PLAYBACK_WIRE(StartTier.PLAYBACK, ownsLoop = true),
    MIX_ORPHANS(StartTier.PLAYBACK),
    /** Now Playing DSP; its 4 Hz heartbeat runs only while engaged / a run exists / Mix runs. */
    NP_DSP(StartTier.PLAYBACK, ownsLoop = true),
    STUDIO_WIRE(StartTier.PLAYBACK),
    PLAY_STATS(StartTier.PLAYBACK),
    JUKEBOX_BOOTSTRAP(StartTier.PLAYBACK),
    /** Widget bridge: snapshot sync is flow-driven (SessionSwitchboard.onChange), no poll. */
    WIDGETS(StartTier.PLAYBACK, ownsLoop = true),

    /** Rec-engine auto-flush loop + release feed. */
    RECS(StartTier.INTERACTIVE, ownsLoop = true),
}

object StartupPlan {
    /** The steps a start of [tier] runs, in declaration (= dependency) order. */
    fun steps(tier: StartTier): List<StartStep> = StartStep.entries.filter { it.tier.ordinal <= tier.ordinal }

    /** The steps that own a recurring loop or observer; a background wake must never include any. */
    fun loopSteps(tier: StartTier): List<StartStep> = steps(tier).filter { it.ownsLoop }
}

/** Runs each step at most once per process; [ensure] is idempotent and thread-safe. A failing step never blocks the rest. */
class StartupLedger(
    private val onError: (StartStep, Throwable) -> Unit = { _, _ -> },
    private val run: (StartStep) -> Unit,
) {
    private val done = LinkedHashSet<StartStep>()

    @Synchronized fun ensure(tier: StartTier) {
        for (s in StartupPlan.steps(tier)) {
            if (!done.add(s)) continue
            try { run(s) } catch (t: Throwable) { onError(s, t) }
        }
    }

    @Synchronized fun hasRun(step: StartStep): Boolean = step in done
    @Synchronized fun ran(): List<StartStep> = done.toList()
}

/** ANS-SHELL-1: when the Now Playing DSP 4 Hz heartbeat should run (pure). */
object NpHeartbeatGate {
    fun shouldBeat(engaged: Boolean, runExists: Boolean, mixRunning: Boolean): Boolean = engaged || runExists || mixRunning
}
