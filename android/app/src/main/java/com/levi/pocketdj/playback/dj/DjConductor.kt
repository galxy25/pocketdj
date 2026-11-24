package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.mix.nowplaying.DjIncoming
import com.levi.pocketdj.mix.nowplaying.DjPhase
import com.levi.pocketdj.mix.nowplaying.DjTransitionSpec
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

/**
 * DJ MODE's CONDUCTOR (iOS `SetlistPlayer.applyDJOnTrackStart` / `armDJ` / `djMakeTransition` / `djAdvanceAtFadeStart` /
 * `djIncomingEngaged` / `djIncomingFailed`; docs/architecture/android-parity2.md 6.3). It sits between the sequencer and the
 * two-deck [com.levi.pocketdj.mix.nowplaying.DjTransitionEngine]:
 *
 *  - **Track start** (the last step of the locks-on-track-start chain): re-plan, engage the DSP on the playing local row,
 *    ARM the engine's lead-window watch with [buildTransition]; a row the DSP cannot own just ends with today's advance.
 *  - **Decide** ([buildTransition]): ONE decline list ([DjDecline]), then the plan: `advancePlan(secondsLeft x
 *    min(1, 1.12/outRate), fade, glide, fxGlide: effectSweeps, mixGlide: tempo||key)`; glide only with Tempo/Key on,
 *    texture only with Effect sweeps, incoming gain only with Volume leveling on. null declines (logged once per song +
 *    reason): the song plays on and ends normally.
 *  - **Fade start** ([onFadeStart]): the SEQUENCER ADVANCES (no reload) while the outgoing fades out; the same decline
 *    list is re-checked and a refusal (the queue moved, a repeat count set ...) makes the engine put the outgoing back.
 *    The row's audio is handed to the DSP owner ([Env.adoptIncoming]: ExoPlayer idle, one audio owner, one card writer),
 *    the Stem / FX Lock go onto the incoming and the conductor re-arms and re-plans.
 *  - **Never delays playback**: an incoming the DSP cannot take after the advance plays the plain way
 *    ([onIncomingFailed]); a cut hands the outgoing back at its playhead.
 *
 * Everything outside (sequencer, DSP engine, host, catalog) is behind [Env], so the logic is JVM-testable. Main thread.
 */
class DjConductor(private val env: Env, private val scope: CoroutineScope) : DjEngineHooks {

    /** A complete local file the DSP can open for a row: the file, its window inside it (a shared album side) and its beat grid. */
    data class LocalSource(
        val file: File,
        val startMs: Long = 0,
        val lengthMs: Long = 0,
        val beat: com.levi.pocketdj.playback.dj.AutoTransition.BeatRef = AutoTransition.BeatRef(null),
    )

    /** What the catalog (plus the analysis fallback) knows about a song's tempo and key. */
    data class Facts(val bpm: Double? = null, val camelot: String? = null)

    interface Env {
        // ---- the session (sequencer) ----
        /** DJ Mode is on AND allowed to act (not held, no Mix tab, no Remote session). */
        val djActive: Boolean
        val running: Boolean
        val held: Boolean
        fun currentItem(): QueueItem?
        fun nextItem(): QueueItem?
        val queueCount: Int
        val repeatOne: Boolean
        val repeatAll: Boolean
        val playsRemaining: Int
        val halted: Boolean
        fun settings(): DJModeSettings
        fun timings(): DjMode.Timings

        /** The current row plays through a shared album side and the record's next song follows. */
        fun currentInAlbumRun(): Boolean

        /** The NEXT row starts an in-order run of its album side. */
        fun nextStartsAlbumRun(): Boolean

        /** The row's COMPLETE local file (burned / studio / profile), null = not local (yet). May touch disk: not for the UI thread's hot path. */
        fun localSource(item: QueueItem): LocalSource?
        fun facts(songId: String): Facts?

        /** Loudness leveling gain (dB) for the incoming; 0 = unknown. P2-DJ-11 binds the real one. */
        fun levelDb(songId: String, src: LocalSource): Double = 0.0

        /** Byte progress (0..1) of the next row becoming local; null = nothing is buffering for it. */
        fun nextBufferFraction(): Double? = null

        // ---- the DSP ----
        val dspEngaged: Boolean
        val dspEngagedSongId: String?
        val dspRate: Double
        val dspSecondsLeft: Double
        val dspPhase: DjPhase

        /** ExoPlayer has LOADED the playing row and is sounding it (or the listener paused it): the DSP can take over at its playhead. */
        fun currentReadyToEngage(): Boolean = true

        /** The playing row CAN be handed to the DSP (a local file, not Apple Music / a live capture / a growing stream). */
        fun currentMixable(): Boolean

        /** Engage the DSP on the playing row. [liveClock]: at ExoPlayer's playhead; false = from the start. */
        suspend fun engageCurrent(liveClock: Boolean): Boolean
        fun arm(lead: Double, build: () -> DjTransitionSpec?)
        fun disarm()

        // ---- the advance ----
        /**
         * The sequencer advance onto [songId] (no load) with every host seam it needs staged first: the card's metadata, the
         * Stem / FX Lock carry. False = nothing advanced (halted / not running): the engine puts the outgoing back.
         */
        fun advanceAtFadeStart(songId: String): Boolean

        /** Play [item] the plain way (a normal start; its History play was already recorded by the advance). */
        fun playPlain(item: QueueItem)

        // ---- seams of later packages ----
        /** The selector re-plans what comes next (P2-DJ-10). */
        fun replan(reason: String) {}

        /** Level the playing row (P2-DJ-11). */
        fun applyLeveling(ramp: Boolean) {}

        /** Analyse what is coming up (P2-DJ-11). */
        fun analyzeUpcoming() {}
        fun levelToZero() {}

        fun log(line: String)
    }

    private var rng = AutoTransition.Rng(0u)
    private var seeded = false
    private var texture: AutoTransition.Texture? = null
    private var textureLeft = 0
    private var lastDecline: Pair<String, String>? = null
    private var engineDecline: Pair<String, String>? = null

    /** The row id a track start asked us to arm once the DSP can own it (see [poll]). */
    private var pendingArm: String? = null
    private var engaging = false

    /** Transitions that reached the advance this session (diagnostics / tests). */
    var transitionCount = 0; private set

    // ================================================================ track start

    /** A row started (every start path). DJ arms it as soon as the DSP can own it: [poll] (the 4 Hz heartbeat) finishes the job. */
    fun onTrackStarted(songId: String) {
        pendingArm = songId
        engineDecline = null
        poll()
    }

    /** Heartbeat: apply a pending track-start arm once the row is loaded. Cheap when nothing is pending. */
    fun poll() {
        val id = pendingArm ?: return
        val cur = env.currentItem()
        if (cur == null || !cur.matches(id) || !env.running) { pendingArm = null; return }
        if (!env.djActive) return          // suspended / held: applyOnTrackStart re-engages on resume
        if (env.dspEngaged && env.dspEngagedSongId != null && cur.matches(env.dspEngagedSongId!!)) {
            pendingArm = null
            armNow(liveClock = true)
            return
        }
        if (engaging) return
        applyOnTrackStart(liveClock = true)
    }

    override fun applyOnTrackStart(liveClock: Boolean) {
        val cur = env.currentItem()
        if (!env.running || env.held || cur == null) return
        if (!env.djActive) { env.log("track song=${cur.id} -> SUSPENDED"); return }
        env.replan("track")
        if (env.dspEngaged && env.dspEngagedSongId?.let { cur.matches(it) } == true) { pendingArm = null; armNow(liveClock); return }
        if (env.currentInAlbumRun()) {
            pendingArm = null
            env.log("track song=${cur.id} -> album run (the side plays through on the record)")
            return
        }
        if (!env.currentMixable()) {
            pendingArm = null
            env.log("track song=${cur.id} -> plain (not a local file / Apple Music / live) - its end is a normal advance")
            return
        }
        if (!env.currentReadyToEngage()) { pendingArm = cur.id; return }   // [poll] (4 Hz) retries once the row sounds
        if (engaging) return
        engaging = true
        scope.launch {
            val ok = try { env.engageCurrent(liveClock) } finally { engaging = false }
            val now = env.currentItem()
            if (now == null || !now.matches(cur.id)) return@launch   // the row moved on while engaging: its own start re-arms
            pendingArm = null
            if (!ok) { env.log("track song=${cur.id} -> plain (DSP refused the file)"); return@launch }
            armNow(liveClock)
        }
    }

    private fun armNow(liveClock: Boolean) {
        if (!env.djActive || !env.dspEngaged) return
        env.arm(env.timings().lead) { buildTransition() }
        env.applyLeveling(ramp = liveClock)
        env.analyzeUpcoming()
    }

    override fun disarm() {
        pendingArm = null
        env.disarm()
    }

    override fun levelToZero() = env.levelToZero()

    override fun plannerSeeded(seed: ULong) {
        rng = AutoTransition.Rng(seed)
        seeded = true
        texture = null
        textureLeft = 0
    }

    /** The chip: what happens at the END of the playing song (null = the engine's default). */
    override fun indicator(): DjMode.Indicator? {
        val cur = env.currentItem() ?: return null
        if (env.dspPhase != DjPhase.IDLE) return DjMode.Indicator.Mixing
        decide(forSkip = false, withLocal = false)?.let { return it.indicator }
        engineDecline?.takeIf { it.first == cur.id }?.let { return DjMode.Indicator.NoMix(DjDecline.engineWords(it.second)) }
        if (env.nextItem() == null) return null
        if (lastDecline?.let { it.first == cur.id && it.second == DjDecline.Reason.NEXT_NOT_LOCAL.raw } == true) {
            env.nextBufferFraction()?.let { return DjMode.Indicator.BufferingNext(it) }
            return DjMode.Indicator.BufferingNext(null)
        }
        return DjMode.Indicator.NextReady
    }

    // ================================================================ the decision

    /** The shared decline list over the live state (see [DjDecline]). */
    fun decide(forSkip: Boolean, withLocal: Boolean): DjDecline.Reason? {
        val cur = env.currentItem()
        val next = env.nextItem()
        val nextLocal = if (withLocal && next != null) env.localSource(next) != null else null
        return DjDecline.reason(
            DjDecline.Inputs(
                hasCurrent = cur != null,
                transitionsOn = env.settings().transitions,
                repeatOne = env.repeatOne,
                playsRemaining = env.playsRemaining,
                halted = env.halted,
                hasNext = next != null,
                repeatAll = env.repeatAll,
                albumRunPlaying = cur != null && env.currentInAlbumRun(),
                nextStartsAlbumRun = next != null && env.nextStartsAlbumRun(),
                dspEngaged = env.dspEngaged,
                nextLocal = nextLocal,
            ),
            forSkip,
        )
    }

    private fun declined(songId: String, reason: String, forSkip: Boolean = false) {
        val words = DjDecline.logWords(reason, forSkip)
        if (lastDecline == songId to reason) return
        lastDecline = songId to reason
        env.log("declined reason=$words song=$songId -> normal advance")
    }

    private fun nextTexture(): AutoTransition.Texture {
        if (!seeded) { rng = AutoTransition.Rng(AutoTransition.fxSeed(env.currentItem()?.id, env.queueCount)); seeded = true }
        if (textureLeft <= 0 || texture == null) {
            texture = AutoTransition.rollTexture(rng)
            textureLeft = texture!!.run
        }
        textureLeft--
        return texture!!
    }

    /**
     * The transition out of the playing row into the next (the engine's lead-window watch asks, once a second). null
     * declines (logged once per song + reason): the song plays on and ends with today's normal advance.
     */
    fun buildTransition(skipFade: Double? = null): DjTransitionSpec? {
        if (!env.djActive || !env.running || env.held || !env.dspEngaged) return null
        val cur = env.currentItem() ?: return null
        val forSkip = skipFade != null
        decide(forSkip, withLocal = false)?.let { declined(cur.id, it.raw, forSkip); return null }
        val next = env.nextItem() ?: return null
        val src = env.localSource(next)
        if (src == null) { declined(cur.id, DjDecline.Reason.NEXT_NOT_LOCAL.raw, forSkip); return null }
        val cfg = env.settings()
        val t = env.timings()
        val mixGlide = cfg.tempoMatch || cfg.keyMatch
        val fa = env.facts(cur.id)
        val fb = env.facts(next.id)
        val curSrc = env.localSource(cur)
        val ba = beatOf(curSrc?.beat, fa)
        val bb = beatOf(src.beat, fb)
        // The outgoing's EFFECTIVE tempo (the listener may have moved its rate) meets the incoming's.
        val g = if (mixGlide) {
            AutoTransition.glideParams(
                fromCamelot = if (cfg.keyMatch) fa?.camelot else null,
                toCamelot = if (cfg.keyMatch) fb?.camelot else null,
                fromBPM = if (cfg.tempoMatch) ba.bpm?.let { it * env.dspRate } else null,
                toBPM = if (cfg.tempoMatch) bb.bpm else null,
            )
        } else AutoTransition.identityGlide
        // advancePlan's 1.12 headroom assumes the outgoing speeds up <= 12 %: a bigger tempo meet eats the runway faster.
        val runway = env.dspSecondsLeft * minOf(1.0, AutoTransition.GLIDE_TEMPO_HEADROOM / maxOf(1.0, g.outRate))
        val plan = if (skipFade != null) {
            AutoTransition.immediatePlan(
                fade = minOf(skipFade, maxOf(1.0, runway - 0.5)), baselineFade = t.fade, glide = t.glide,
                fxGlide = cfg.effectSweeps, mixGlide = mixGlide,
            )
        } else {
            AutoTransition.advancePlan(runway, t.fade, t.glide, fxGlide = cfg.effectSweeps, mixGlide = mixGlide)
        }
        val level = if (cfg.volumeLeveling) env.levelDb(next.id, src) else 0.0
        val spec = DjTransitionSpec(
            plan = plan, glide = g, texture = if (cfg.effectSweeps) nextTexture() else null, outgoingBeat = ba,
            incoming = DjIncoming(next.id, src.file, src.startMs, src.lengthMs, bb, level),
        )
        env.log(
            "transition from=${cur.id} to=${next.id} plan=" + String.format(
                Locale.US, "pre=%.1fs fade=%.1fs post=%.1fs glide=%s fx=%s level=%.1fdB left=%.1fs", plan.preRollSeconds, plan.fadeSeconds,
                if (plan.hasPostRoll) plan.postRollSeconds else 0.0, plan.isGlide, spec.texture?.effect?.raw ?: "none", level, env.dspSecondsLeft,
            ),
        )
        lastDecline = null
        return spec
    }

    /** The BPM to beat-match on: the measured grid's, else the catalog's. */
    private fun beatOf(grid: AutoTransition.BeatRef?, facts: Facts?): AutoTransition.BeatRef {
        val gb = grid?.bpm?.takeIf { it > 0 }
        val bpm = gb ?: facts?.bpm?.takeIf { it > 0 }
        return AutoTransition.BeatRef(bpm, grid?.firstDownbeatMs, grid?.beatsMs)
    }

    // ================================================================ engine callbacks

    /**
     * FADE START: the advance. Refuses (the outgoing carries on) when the queue moved under the transition or anything the
     * decision checked changed during the pre-roll (a repeat count, the cascade halt, Transitions off, DJ suspended).
     */
    fun onFadeStart(songId: String): Boolean {
        val cur = env.currentItem()
        val next = env.nextItem()
        if (!env.djActive || !env.running || env.held || !env.dspEngaged || cur == null || next == null || !next.matches(songId)) {
            env.log("fade start -> $songId refused (the queue moved under the transition)")
            return false
        }
        decide(forSkip = false, withLocal = false)?.let {
            env.log("fade start -> $songId refused (${it.raw} since the transition began)")
            return false
        }
        if (!env.advanceAtFadeStart(songId)) {
            env.log("fade start -> $songId refused (the sequencer did not advance)")
            return false
        }
        transitionCount++
        env.log("advance at fade start from=${cur.id} to=${next.id} (no reload; the DSP owns the audio)")
        engineDecline = null
        lastDecline = null
        pendingArm = null
        // The incoming is the DSP's now: re-arm its own end, re-plan what comes next, level it.
        armNow(liveClock = true)
        env.replan("track")
        return true
    }

    /**
     * The incoming could not be taken by the DSP after the advance (ExoPlayer would not go idle / the engine let go): play it
     * the plain way. Never a dead end: the row is the sequencer's current one.
     */
    fun onIncomingFailed(songId: String) {
        val cur = env.currentItem() ?: return
        if (!cur.matches(songId)) return
        env.log("incoming song=$songId refused by the engine -> plain start")
        env.playPlain(cur)
    }

    /** A begin the lead-window watch tried was declined by the ENGINE (the reason is `DjEngineDecline`'s). */
    fun onEngineDeclined(reason: String) {
        val cur = env.currentItem() ?: return
        engineDecline = cur.id to reason
        declined(cur.id, reason)
    }

    fun onTransitionEnded(songId: String?, how: String) {
        env.log("transition end ${songId?.let { "song=$it " } ?: ""}how=$how")
        if (songId == null) engineDecline = null
    }

    /** A cut before the advance handed the outgoing back at its playhead: nothing else to do, the song plays on and re-arms. */
    fun onHandBack(atSec: Double) {
        env.log(String.format(Locale.US, "hand back at %.1fs (the song plays on)", atSec))
    }
}
