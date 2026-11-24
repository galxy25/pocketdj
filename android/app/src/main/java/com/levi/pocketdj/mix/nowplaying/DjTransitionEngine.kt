package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.playback.dj.AutoTransition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/** The incoming song a DJ transition mixes into (built by the host). */
data class DjIncoming(
    val songId: String,
    val file: File,
    /** The song's start within a shared analog album file (0 for a per-song file). */
    val startMs: Long = 0,
    val lengthMs: Long = 0,
    val beat: AutoTransition.BeatRef = AutoTransition.BeatRef(null),
    /** The incoming's leveling gain (dB; 0 = unknown / leveling off). */
    val levelDb: Double = 0.0,
)

/** One DJ transition, every decision already made by `AutoTransition` (iOS `DJTransition`). */
data class DjTransitionSpec(
    val plan: AutoTransition.Plan,
    /** Glide targets: rate MULTIPLIERS / pitch semitones ADDED on top of the listener's controls. */
    val glide: AutoTransition.GlideTargets = AutoTransition.identityGlide,
    /** The FX texture swept through the transition (null = effect sweeps off). */
    val texture: AutoTransition.Texture? = null,
    val outgoingBeat: AutoTransition.BeatRef = AutoTransition.BeatRef(null),
    val incoming: DjIncoming,
)

enum class DjPhase { IDLE, PREROLL, FADING, POSTROLL }

/** The engine's own decline reasons (iOS strings). The sequencer-side reasons live with the conductor. */
object DjEngineDecline {
    const val IN_FLIGHT = "transition in flight"
    const val NOT_PLAYING = "not playing"
    const val GROWING = "outgoing not complete to its end"
    const val STEM_HANDOVER = "stem handover in flight"
    const val STEMS_MUTED = "stems-muted"
    const val INCOMING_UNREADABLE = "incoming unreadable"
    const val TOO_CLOSE = "too close to the end"

    /** Below this much audio left a transition isn't begun (the song just ends). */
    const val MIN_SECONDS_LEFT = 0.3

    data class Inputs(
        val inFlight: Boolean, val engaged: Boolean, val playing: Boolean, val buffering: Boolean,
        val growing: Boolean, val stemHandoverInFlight: Boolean, val mutedStems: Boolean,
        val incomingReadable: Boolean, val secondsLeft: Double,
    )

    /** The first reason the engine refuses, null = it may begin. Pure: the order is the contract. */
    fun check(i: Inputs): String? = when {
        i.inFlight -> IN_FLIGHT
        !i.engaged || !i.playing || i.buffering -> NOT_PLAYING
        i.growing -> GROWING
        i.stemHandoverInFlight -> STEM_HANDOVER
        i.mutedStems -> STEMS_MUTED
        !i.incomingReadable -> INCOMING_UNREADABLE
        !(i.secondsLeft >= MIN_SECONDS_LEFT) -> TOO_CLOSE
        else -> null
    }
}

/**
 * DJ Mode's two-deck transition engine, owned by [NowPlayingDspEngine] (design: docs/architecture/android-parity2.md
 * 6.3, "ping-pong decks"). The incoming song is opened on the IDLE deck of the private MixGraph; the graph's
 * equal-power crossfader is the fade; at the fade start the engine's per-song state (and with it the listener's
 * controls) moves onto the incoming deck, and the outgoing becomes the tail until the fade lands. Each deck's
 * `trimDb` carries leveling. Ramps are driven by [step] at >= 50 Hz, only while a transition (or a hand-back ease)
 * runs; [NowPlayingDspEngine.tick] (4 Hz) only watches the lead window.
 *
 * ```
 * IDLE -arm-> (armed) -lead window-> PREROLL -> FADING (onFadeStart) -> POSTROLL -> IDLE (onTransitionEnded)
 * cut before the advance -> hand back (onHandBack, glide eased 0.5 s) ; after the advance -> the tail goes
 * ```
 */
class DjTransitionEngine internal constructor(
    private val np: NowPlayingDspEngine,
    private val scope: CoroutineScope,
    private val clock: () -> Double,
    private val tickerEnabled: Boolean,
) {
    /** FADE START: the host advances onto [songId] (card, queue, meter, FX Lock stamp). false refuses: the outgoing goes back. */
    var onFadeStart: ((songId: String) -> Boolean)? = null
    /** A transition ended: the incoming song id (null before the advance) and how (complete / listener / cut reason). */
    var onTransitionEnded: ((songId: String?, how: String) -> Unit)? = null
    /** A cut before the advance handed the outgoing back at its playhead (song seconds). */
    var onHandBack: ((atSec: Double) -> Unit)? = null
    /** A begin the lead-window watch tried was declined here (the reason). */
    var onDeclined: ((reason: String) -> Unit)? = null

    var phase: DjPhase = DjPhase.IDLE; private set
    val isTransitioning: Boolean get() = phase != DjPhase.IDLE
    val isArmed: Boolean get() = arm != null
    /** A hand-back (or listener-released) glide is easing out to identity. */
    val isEasing: Boolean get() = ease != null
    /** 0..1 progress of the crossfade (0 before the fade, 1 after). */
    var fadeProgress = 0.0; private set
    var glideDropped = false; private set
    val incomingSongId: String? get() = spec?.incoming?.songId

    private class Arm(val lead: Double, val begin: () -> DjTransitionSpec?)
    private class Tail(val state: NowPlayingDspEngine.LiveState, val controls: NowPlayingDspEngine.ControlSnap, var overlay: GlideOverlay)
    private class Ease(val from: GlideOverlay, var elapsed: Double = 0.0)

    private var arm: Arm? = null
    private var nextTry = 0.0
    private var spec: DjTransitionSpec? = null
    private var inc: NowPlayingDspEngine.IncomingDeck? = null
    private var tail: Tail? = null
    private var phaseElapsed = 0.0
    private var lastClock = 0.0
    private var ease: Ease? = null
    private var cutting = false
    private var cutFrom = 0.0
    private var cutElapsed = 0.0
    private var ticker: Job? = null

    // ================================================================ arm (the lead-window watch)

    /**
     * Arm the CURRENT song: once it has [lead] seconds (or fewer) left, [begin] is asked for the transition (the
     * host re-validates the next row then; null declines) and it starts. A declined attempt retries every
     * [RETRY_SECONDS] until [DjEngineDecline.MIN_SECONDS_LEFT]. A disengage disarms.
     */
    fun armDj(lead: Double, begin: () -> DjTransitionSpec?) { arm = Arm(lead, begin); nextTry = 0.0 }
    fun disarmDj() { arm = null }

    internal fun watchTick() {
        val a = arm ?: return
        if (phase != DjPhase.IDLE || ease != null || !np.isEngaged || !np.djPlayWanted || np.isBuffering || np.durationSec <= 0.0) return
        val left = np.djSecondsLeft()
        if (!AutoTransition.inLeadWindow(left, a.lead) || left < DjEngineDecline.MIN_SECONDS_LEFT) return
        val now = clock()
        if (now < nextTry) return
        nextTry = now + RETRY_SECONDS
        val s = a.begin() ?: return
        beginTransition(s)?.let { onDeclined?.invoke(it) }
    }

    // ================================================================ begin

    /**
     * Start [spec] now. null = it began; else the decline reason (nothing touched; the song plays on and ends with
     * today's normal advance).
     */
    fun beginTransition(spec: DjTransitionSpec): String? {
        val readyChecks = DjEngineDecline.Inputs(
            inFlight = phase != DjPhase.IDLE || ease != null,
            engaged = np.isEngaged, playing = np.djPlayWanted, buffering = np.isBuffering,
            growing = np.isStreaming, stemHandoverInFlight = np.djStemHandoverInFlight,
            mutedStems = np.djHasMutedStems, incomingReadable = true,
            secondsLeft = if (np.isEngaged) np.djSecondsLeft() else 0.0,
        )
        DjEngineDecline.check(readyChecks)?.let { return it }
        val i = spec.incoming
        val opened = np.djOpenIncoming(i.songId, i.file, i.startMs, i.lengthMs, i.levelDb)
            ?: return DjEngineDecline.INCOMING_UNREADABLE
        this.spec = spec
        inc = opened
        glideDropped = false
        cutting = false
        fadeProgress = 0.0
        phaseElapsed = 0.0
        lastClock = clock()
        phase = DjPhase.PREROLL
        np.djSetCrossfader(np.djCrossfaderEnd(np.liveDeck))
        if (spec.plan.isGlide) {
            np.djPublishOverlay(opened.deck, null, incOverlay(0.0))
            np.djSetOwnOverlay(outOverlay(0.0))
        }
        if (!spec.plan.hasPreRoll) fadeStart() else ensureTicker()
        return null
    }

    // ================================================================ timeline

    /** One ticker step (>= 50 Hz while a transition or an ease runs). Time only advances while the audio plays. */
    internal fun step() {
        val now = clock()
        val dt = (now - lastClock).coerceIn(0.0, 0.25)
        lastClock = now
        val live = if (np.djPlayWanted) dt else 0.0
        stepEase(dt)
        val sp = spec ?: return
        when (phase) {
            DjPhase.IDLE -> Unit
            DjPhase.PREROLL -> {
                phaseElapsed += live
                // the outgoing ran out of road (a late tick): the fade starts now, whatever is left of the pre-roll
                if (np.djSecondsLeft() < 0.05) { fadeStart(); return }
                val p = (phaseElapsed / maxOf(AutoTransition.MIN_RAMP_SECONDS, sp.plan.preRollSeconds)).coerceAtMost(1.0)
                if (!glideDropped && sp.plan.isGlide) np.djSetOwnOverlay(outOverlay(p))
                if (p >= 1.0) fadeStart()
            }
            DjPhase.FADING -> {
                val fade = maxOf(0.05, sp.plan.fadeSeconds)
                val p: Double
                if (cutting) {
                    cutElapsed += dt
                    p = cutFrom + (1 - cutFrom) * (cutElapsed / CUT_FADE_SECONDS).coerceAtMost(1.0)
                } else {
                    phaseElapsed += live
                    p = (phaseElapsed / fade).coerceAtMost(1.0)
                }
                setFade(p)
                if (p >= 1.0) endFade()
            }
            DjPhase.POSTROLL -> {
                phaseElapsed += live
                val p = (phaseElapsed / maxOf(AutoTransition.MIN_RAMP_SECONDS, sp.plan.postRollSeconds)).coerceAtMost(1.0)
                np.djSetOwnOverlay(incOverlay(p))
                if (p >= 1.0) { np.djClearOwnOverlay(); finish("complete") }
            }
        }
    }

    private fun setFade(p: Double) {
        fadeProgress = p
        // the incoming is the (post-flip) live deck: B heard = crossfader 1, A heard = crossfader 0
        val x = if (np.liveDeck == Deck.B) p.toFloat() else (1 - p).toFloat()
        np.djSetCrossfader(x)
    }

    private fun fadeStart() {
        val sp = spec ?: return
        val incoming = inc ?: return
        val sr = np.djSampleRate
        val outPos = np.djPosition()
        val offset = alignOffset(sp, outPos)
        var startFrame = incoming.windowStart + Math.round(offset * sr)
        if (incoming.windowEnd != Long.MAX_VALUE) startFrame = minOf(startFrame, maxOf(incoming.windowStart, incoming.windowEnd - 1))
        if (startFrame != incoming.startFrame) incoming.voice.seek(startFrame)

        val outgoing = np.djCaptureLive()
        val controls = np.djCaptureControls()
        val glide = sp.plan.isGlide && !glideDropped
        val outOv = if (glide) outOverlay(1.0) else GlideOverlay.NONE
        val inOv = if (glide) incOverlay(0.0) else GlideOverlay.NONE
        val savedArm = arm

        np.djCommitFlip(np.djIncomingState(incoming, sp.incoming.songId, startFrame))
        np.djSetOwnOverlay(inOv)
        tail = Tail(outgoing, controls, outOv)
        np.djPublishOverlay(outgoing.deck, controls, outOv)
        arm = null                      // the armed song is gone
        phase = DjPhase.FADING
        phaseElapsed = 0.0
        setFade(0.0)
        ensureTicker()

        val accepted = onFadeStart?.invoke(sp.incoming.songId) ?: true
        if (!accepted) revertFadeStart(outgoing, controls, savedArm)
    }

    /** The host refused the advance: the outgoing is live again on its deck, its glide eases out. */
    private fun revertFadeStart(outgoing: NowPlayingDspEngine.LiveState, controls: NowPlayingDspEngine.ControlSnap, savedArm: Arm?) {
        val incomingLive = np.djCaptureLive()
        np.djRevertFlip(outgoing, controls)
        np.djSetCrossfader(np.djCrossfaderEnd(outgoing.deck))
        np.djReleaseDeck(incomingLive.deck, incomingLive.main, incomingLive.mainRun, incomingLive.stemGroup, incomingLive.stemRuns)
        tail = null
        inc = null
        arm = savedArm
        handBackTail("refused", from = controls.overlay)
    }

    private fun endFade() {
        setFade(1.0)
        releaseTail()
        val sp = spec
        if (cutting) {
            startEase(np.djOverlay())
            finish("cut")
        } else if (sp != null && sp.plan.hasPostRoll && !glideDropped) {
            phase = DjPhase.POSTROLL
            phaseElapsed = 0.0
        } else finish(if (glideDropped) "listener" else "complete")
    }

    private fun releaseTail() {
        val t = tail ?: return
        tail = null
        t.state.let { np.djReleaseDeck(it.deck, it.main, it.mainRun, it.stemGroup, it.stemRuns) }
    }

    private fun finish(how: String) {
        val id = if (phase == DjPhase.FADING || phase == DjPhase.POSTROLL) spec?.incoming?.songId else null
        phase = DjPhase.IDLE
        spec = null
        inc = null
        cutting = false
        onTransitionEnded?.invoke(id, how)
    }

    // ================================================================ cut

    /**
     * End the transition NOW. Before the advance with the song still playing, the outgoing is handed back at its
     * playhead and the glide eases out over 0.5 s. After the advance the tail leaves over a 40 ms ramp.
     */
    fun cutTransition(reason: String) {
        when (phase) {
            DjPhase.IDLE -> Unit
            DjPhase.PREROLL -> {
                inc?.let { np.djReleaseDeck(it.deck, it.voice, it.run, null, emptyList()) }
                inc = null
                handBackTail(reason, from = np.djOverlay())
            }
            DjPhase.FADING -> {
                if (cutting) return
                if (!np.djPlayWanted) {      // paused: nothing is sounding, so nothing clicks
                    cutting = true
                    endFade()
                    return
                }
                cutting = true
                cutFrom = fadeProgress
                cutElapsed = 0.0
                lastClock = clock()
                ensureTicker()
            }
            DjPhase.POSTROLL -> {
                startEase(np.djOverlay())
                finish(reason)
            }
        }
    }

    private fun handBackTail(reason: String, from: GlideOverlay) {
        spec = null
        phase = DjPhase.IDLE
        glideDropped = false
        fadeProgress = 0.0
        onHandBack?.invoke(np.djPosition())
        startEase(from)
        onTransitionEnded?.invoke(null, reason)
    }

    internal fun cutIfBeforeAdvance(reason: String) { if (phase == DjPhase.PREROLL) cutTransition(reason) }

    /** A seek cuts the other deck. */
    internal fun onSeek() { if (phase != DjPhase.IDLE) cutTransition("seek") }

    /** Stop / disengage / a fresh engage: cut everything without a hand-back. */
    internal fun reset(reason: String) {
        arm = null
        ease = null
        ticker?.cancel(); ticker = null
        if (phase == DjPhase.IDLE && tail == null && inc == null) return
        val id = if (phase == DjPhase.FADING || phase == DjPhase.POSTROLL) spec?.incoming?.songId else null
        releaseTail()
        inc?.let { np.djReleaseDeck(it.deck, it.voice, it.run, null, emptyList()) }
        inc = null
        np.djSetCrossfader(np.djCrossfaderEnd(np.liveDeck))
        phase = DjPhase.IDLE
        spec = null
        cutting = false
        onTransitionEnded?.invoke(id, reason)
    }

    // ================================================================ listener + transport

    /** The listener touched tempo / pitch / an effect: the glide ends at once (the listener wins); the fade carries on. */
    internal fun listenerTouched() {
        when (phase) {
            DjPhase.IDLE -> if (ease != null) { ease = null; np.djClearOwnOverlay() }
            DjPhase.PREROLL -> {
                glideDropped = true
                np.djClearOwnOverlay()
                inc?.let { np.djPublishOverlay(it.deck, null, GlideOverlay.NONE) }
            }
            DjPhase.FADING -> { glideDropped = true; np.djClearOwnOverlay() }
            DjPhase.POSTROLL -> { glideDropped = true; np.djClearOwnOverlay(); finish("listener") }
        }
    }

    /** Pause pauses both decks. */
    internal fun onPause() {
        val t = tail ?: return
        t.state.main?.pause(); t.state.stemGroup?.pauseAll()
    }

    internal fun onPlay() {
        val t = tail ?: return
        if (np.djStemSide(t.state.deck, t.state.stemGroup)) t.state.stemGroup?.startAt(-1) else t.state.main?.play(-1)
    }

    // ================================================================ helpers

    private fun texEffect(): Pair<Effect, Double>? {
        val t = spec?.texture ?: return null
        val e = Effect.entries.firstOrNull { it.raw == t.effect.raw } ?: return null
        return e to t.peak
    }

    private fun outOverlay(p: Double): GlideOverlay {
        val sp = spec ?: return GlideOverlay.NONE
        val tex = texEffect()
        val r = AutoTransition.outgoingRamp(p, sp.glide.outRate, sp.glide.outPitch, tex?.second ?: 0.0)
        return GlideOverlay(r.rate, r.pitch, tex?.let { it.first to r.fxStrength })
    }

    private fun incOverlay(p: Double): GlideOverlay {
        val sp = spec ?: return GlideOverlay.NONE
        val tex = texEffect()
        val r = AutoTransition.incomingRamp(p, sp.glide.inRate, sp.glide.inPitch, tex?.second ?: 0.0)
        return GlideOverlay(r.rate, r.pitch, tex?.let { it.first to r.fxStrength })
    }

    /** Seconds to move the incoming's playhead so its beat lands on the outgoing's (never negative: a late beat waits one beat). */
    private fun alignOffset(sp: DjTransitionSpec, outPos: Double): Double {
        val bpm = sp.incoming.beat.bpm ?: return 0.0
        if (!(bpm > 0) || !bpm.isFinite()) return 0.0
        var off = AutoTransition.phaseAlignOffset(sp.outgoingBeat, outPos, sp.incoming.beat, 0.0)
        if (!off.isFinite()) return 0.0
        if (off < 0) off += 60.0 / bpm
        return off.coerceAtLeast(0.0)
    }

    private fun startEase(from: GlideOverlay) {
        if (from.isIdentity) { np.djClearOwnOverlay(); return }
        ease = Ease(from)
        lastClock = clock()
        ensureTicker()
    }

    private fun stepEase(dt: Double) {
        val e = ease ?: return
        e.elapsed += dt
        val q = (e.elapsed / EASE_SECONDS).coerceAtMost(1.0)
        if (q >= 1.0) { ease = null; np.djClearOwnOverlay(); return }
        val f = e.from
        np.djSetOwnOverlay(GlideOverlay(f.rateMul + (1 - f.rateMul) * q, f.pitchAdd * (1 - q), f.texture?.let { it.first to it.second * (1 - q) }))
    }

    private val running: Boolean get() = phase != DjPhase.IDLE || ease != null

    private fun ensureTicker() {
        if (!tickerEnabled || ticker?.isActive == true) return
        ticker = scope.launch {
            while (isActive && running) { delay(TICK_MS); step() }
            ticker = null
        }
    }

    internal fun voiceForTest(): Voice? = tail?.state?.main
    internal val tailPresent: Boolean get() = tail != null
    internal val incomingPresent: Boolean get() = inc != null

    companion object {
        /** The ticker period: 50 Hz. */
        const val TICK_MS = 20L
        /** A declined begin is retried this often while in the lead window. */
        const val RETRY_SECONDS = 1.0
        /** A cut that hands the outgoing back eases the glide overlays to identity over this. */
        const val EASE_SECONDS = 0.5
        /** A post-advance cut ramps the tail out over this instead of a hard (clicking) stop. */
        const val CUT_FADE_SECONDS = 0.04
    }
}
