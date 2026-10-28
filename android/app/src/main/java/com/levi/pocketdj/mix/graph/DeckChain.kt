package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.audio.dsp.Eq3
import com.levi.pocketdj.audio.dsp.EnvelopeFollower
import com.levi.pocketdj.audio.dsp.FxSlotNodes
import com.levi.pocketdj.audio.dsp.Meter
import com.levi.pocketdj.audio.dsp.MixDeckLevels
import com.levi.pocketdj.audio.dsp.TimePitch
import com.levi.pocketdj.audio.dsp.TrimGain
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.FxRack
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * One deck's chain, built ONCE and never reallocated:
 *
 * ```
 * main voice ---+
 * stem x4 ------+-> inputSum -> TimePitch -> slot0..3 -> Eq3 -> Trim -+-> mainGain -> [out]
 *   (env tap on inputSum)                      pre VU after Trim -----+-> cueGain  -> [cueOut]
 * ```
 *
 * The voices are installed by the engine ([main], [stems]) and read here on the render thread. All
 * voices of a deck share one INPUT CLOCK ([inputClock], frames pushed into the time-stretcher),
 * which equals the sink's render clock at 1x speed; scheduled starts and handovers live on it.
 *
 * Render invariants: no allocation, no blocking; a held voice (stream underrun) contributes
 * silence and its position does not advance; stems hold as one group.
 */
class DeckChain(val deck: Deck, val sampleRate: Int = 44_100, val maxBlock: Int = 2048) {
    val handover = Handover((0.06 * sampleRate).roundToInt())

    @Volatile var main: Voice? = null
    @Volatile var stems: VoiceGroup? = null

    val levels = MixDeckLevels()
    val envelope = EnvelopeFollower(sampleRate.toFloat())
    private val preMeter = Meter(levels, post = false)
    private val postMeter = Meter(levels, post = true)
    val timePitch = TimePitch(sampleRate, maxPushFrames = maxBlock)
    val slotNodes = Array(FxRack.SLOT_COUNT) { FxSlotNodes(sampleRate.toFloat()) }
    val eq = Eq3(sampleRate.toFloat())
    val trim = TrimGain(sampleRate.toFloat())

    /** Coherent (inputClock, mainPlayerFrame, stemPlayerFrame) for the control thread. */
    val stamp = PosStamp()

    /** Frames pushed through the chain so far (render thread). */
    @Volatile var inputClock = 0L; private set

    /** True while the cue send is (or was last block) non-zero. */
    var cueLive = false; private set

    /** Post-fader output of the last [render] (valid for `frames`). */
    val out = FloatArray(maxBlock * 2)
    /** Cue send of the last [render]; meaningful only when [cueLive]. */
    val cueOut = FloatArray(maxBlock * 2)

    private val mainIn = FloatArray(maxBlock * 2)
    private val stemIn = List(DeckParams.STEMS) { FloatArray(maxBlock * 2) }
    private val sum = FloatArray(maxBlock * 2)

    private var applied: DeckParams? = null
    private var prevMain = 0f
    private var prevCue = 0f
    private val prevBal = floatArrayOf(1f, 1f, 1f, 1f)
    private val posBuf = LongArray(3)

    // ------------------------------------------------------------ control-thread helpers

    /** Input-clock frame [seconds] from the last published block end (scheduled-start domain). */
    fun inputFrameAfter(seconds: Double): Long {
        stamp.read(posBuf)
        return posBuf[0] + Math.round(seconds * sampleRate)
    }

    // ------------------------------------------------------------ render

    fun render(frames: Int, p: DeckParams, capture: MixDeckCapture?) {
        require(frames <= maxBlock)
        if (p !== applied) applyParams(p)

        var iter = 0
        var first = true
        while (timePitch.availableFrames < frames && iter < MAX_ITER) {
            readChunk(frames, p, first)
            first = false
            iter++
        }
        val got = timePitch.pull(sum, frames)
        if (got < frames) java.util.Arrays.fill(sum, got * 2, frames * 2, 0f)

        // sum is the time-stretched mix; the FX/EQ/trim run in place on it
        for (i in 0 until FxRack.SLOT_COUNT) slotNodes[i].process(sum, frames)
        eq.process(sum, frames)
        trim.process(sum, frames)
        capture?.onDeck(deck, sum, frames)
        preMeter.process(sum, frames)

        // cue: pre-fader, pre-boost-divided send
        val cg = p.cueGain
        cueLive = cg != 0f || prevCue != 0f
        if (cueLive) {
            System.arraycopy(sum, 0, cueOut, 0, frames * 2)
            Ramps.scale(cueOut, frames, prevCue, cg)
        }
        prevCue = cg

        // main fader
        System.arraycopy(sum, 0, out, 0, frames * 2)
        Ramps.scale(out, frames, prevMain, p.mainGain)
        prevMain = p.mainGain
        postMeter.process(out, frames)

        stamp.write(inputClock, main?.playerFrame ?: 0L, stems?.voices?.get(0)?.playerFrame ?: 0L)
    }

    private fun readChunk(n: Int, p: DeckParams, first: Boolean) {
        val clock = inputClock
        val landed = handover.advance(clock, n)
        java.util.Arrays.fill(sum, 0, n * 2, 0f)

        val m = main
        if (m != null) {
            m.read(mainIn, n, clock)
            Ramps.add(sum, mainIn, n, handover.mainG0, handover.mainG1)
        }
        val g = stems
        if (g != null) {
            g.read(stemIn, n, clock)
            val sg0 = handover.stemG0; val sg1 = handover.stemG1
            for (k in 0 until DeckParams.STEMS) {
                val b1 = p.stemBalance(k)
                val b0 = if (first) prevBal[k] else b1
                Ramps.add(sum, stemIn[k], n, sg0 * b0, sg1 * b1)
                prevBal[k] = b1
            }
        }

        if (handover.alignmentDue(clock, n)) verifyAlignment()
        if (landed) {
            if (handover.landedToStems) m?.pause() else g?.pauseAll()
        }

        envelope.process(sum, n)
        timePitch.push(sum, n)
        inputClock = clock + n
    }

    /** At the fade start the incoming voices must sit exactly where the outgoing ones do. */
    private fun verifyAlignment() {
        val m = main; val g = stems
        val toStems = handover.activeToStems
        val inFrame: Long
        val outFrame: Long
        var inPlaying: Boolean
        var outPlaying: Boolean
        if (toStems) {
            val s0 = g?.voices?.get(0)
            inFrame = s0?.playerFrame ?: -1; inPlaying = s0?.status == Voice.Status.PLAYING
            outFrame = m?.playerFrame ?: -1; outPlaying = m?.status == Voice.Status.PLAYING
        } else {
            val s0 = g?.voices?.get(0)
            inFrame = m?.playerFrame ?: -1; inPlaying = m?.status == Voice.Status.PLAYING
            outFrame = s0?.playerFrame ?: -1; outPlaying = s0?.status == Voice.Status.PLAYING
        }
        // A silent outgoing side has no position to match (the deck was silent: switch outright).
        if (!outPlaying) return
        if (!inPlaying || abs(inFrame - outFrame) > ALIGN_TOLERANCE) {
            handover.abort()
            if (toStems) g?.pauseAll() else m?.pause()
        }
    }

    private fun applyParams(p: DeckParams) {
        if (applied == null) { prevMain = p.mainGain; prevCue = p.cueGain } // first params: no fade-in from nothing
        timePitch.setSpeed(p.speed)
        timePitch.setPitchSemitones(p.pitchSemitones)
        if (p.eqLowDb != eq.lowDb) eq.setLowDb(p.eqLowDb)
        if (p.eqMidDb != eq.midDb) eq.setMidDb(p.eqMidDb)
        if (p.eqHighDb != eq.highDb) eq.setHighDb(p.eqHighDb)
        if (p.trimDb != trim.gainDb) trim.setGainDb(p.trimDb)
        for (i in 0 until FxRack.SLOT_COUNT) {
            val s = p.slot(i)
            if (s == null) slotNodes[i].bypass = true else slotNodes[i].applySlot(s.slot, s.strength)
        }
        applied = p
    }

    /** Clear history after a load / hard stop (render-thread safe only between sessions). */
    fun resetDsp() {
        timePitch.flush(); eq.reset(); trim.snap()
        for (s in slotNodes) s.reset()
        preMeter.reset(); postMeter.reset(); envelope.reset()
    }

    companion object {
        const val MAX_ITER = 8
        const val ALIGN_TOLERANCE = 64L
    }
}

/** In-place / accumulate gain ramps (linear across the block, per sample). */
internal object Ramps {
    fun scale(buf: FloatArray, n: Int, g0: Float, g1: Float) {
        if (g0 == 1f && g1 == 1f) return
        if (g0 == 0f && g1 == 0f) { java.util.Arrays.fill(buf, 0, n * 2, 0f); return }
        if (g0 == g1) { for (i in 0 until n * 2) buf[i] *= g1; return }
        val step = (g1 - g0) / n
        var g = g0
        var i = 0
        while (i < n * 2) { buf[i] *= g; buf[i + 1] *= g; g += step; i += 2 }
    }

    fun add(dst: FloatArray, src: FloatArray, n: Int, g0: Float, g1: Float) {
        if (g0 == 0f && g1 == 0f) return
        if (g0 == g1) {
            if (g1 == 1f) { for (i in 0 until n * 2) dst[i] += src[i] } else { for (i in 0 until n * 2) dst[i] += src[i] * g1 }
            return
        }
        val step = (g1 - g0) / n
        var g = g0
        var i = 0
        while (i < n * 2) { dst[i] += src[i] * g; dst[i + 1] += src[i + 1] * g; g += step; i += 2 }
    }

    /**
     * Hard-ish pan of a stereo block toward one side: fold toward mono by |pan|, attenuate the
     * opposite channel by (1-|pan|). At |pan|=1 the whole signal is the mono fold on one side
     * (centered content keeps its level). pan==0 is a no-op (callers skip it).
     */
    fun pan(buf: FloatArray, n: Int, pan: Float) {
        val a = abs(pan)
        if (a == 0f) return
        val keepL = if (pan > 0f) 1f - a else 1f
        val keepR = if (pan < 0f) 1f - a else 1f
        var i = 0
        while (i < n * 2) {
            val l = buf[i]; val r = buf[i + 1]
            val m = (l + r) * 0.5f
            buf[i] = (l + (m - l) * a) * keepL
            buf[i + 1] = (r + (m - r) * a) * keepR
            i += 2
        }
    }
}
