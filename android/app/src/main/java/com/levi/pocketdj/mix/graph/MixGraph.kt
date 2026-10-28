package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.audio.core.VoiceGroup
import com.levi.pocketdj.audio.dsp.Limiter
import com.levi.pocketdj.mix.model.Deck
import java.util.concurrent.atomic.AtomicReference

/**
 * The Mix topology for two decks, built ONCE (docs/design/mix-audio-graph.md):
 *
 * ```
 * deck A chain --mainGain--+                      +--(cue sends, panned to cueSide)--+
 * deck B chain --mainGain--+-> houseSum -> TAP -> housePan -> + -> Limiter -> sink
 * ```
 *
 * [render] is the sink's [BlockRenderer]: it reads the current immutable [RenderParams] once per
 * block (swapped by the engine through [setParams]), renders both decks, sums the clean house (the
 * recording tap and [pulse] see it BEFORE any cue pan), pans the house only while a deck is cued,
 * adds the cue sends and runs the limiter. No allocation, no blocking, no node is ever created or
 * destroyed after construction: FX family/variant swaps are bypass flips inside the chains.
 */
class MixGraph(val sampleRate: Int = 44_100, val maxBlock: Int = 2048) : BlockRenderer {
    val a = DeckChain(Deck.A, sampleRate, maxBlock)
    val b = DeckChain(Deck.B, sampleRate, maxBlock)
    private val paramsRef = AtomicReference(RenderParams())
    private val limiter = Limiter(sampleRate.toFloat())
    val pulse = MixTapPulse()

    /** Persistent recording tap (null = none). */
    @Volatile var tapSink: TapSink? = null
    /** Probe seam on each deck's post-trim block. */
    @Volatile var deckCapture: MixDeckCapture? = null

    private val house = FloatArray(maxBlock * 2)
    private val posBuf = LongArray(3)

    fun deck(d: Deck): DeckChain = if (d == Deck.A) a else b

    val params: RenderParams get() = paramsRef.get()

    /** Publish a new immutable parameter snapshot (any thread). */
    fun setParams(p: RenderParams) { paramsRef.set(p) }

    /** Start pulling blocks from [sink]. */
    fun attach(sink: AudioSink) {
        require(sink.sampleRate == sampleRate) { "sink rate ${sink.sampleRate} != graph rate $sampleRate" }
        sink.start(this)
    }

    fun levelsOf(d: Deck) = deck(d).levels

    val limiterLatencyFrames: Int get() = limiter.latencyFrames

    // ------------------------------------------------------------------ render thread

    override fun render(out: FloatArray, frames: Int) {
        var done = 0
        while (done < frames) {
            val n = minOf(maxBlock, frames - done)
            renderBlock(n)
            System.arraycopy(house, 0, out, done * 2, n * 2)
            done += n
        }
    }

    private fun renderBlock(n: Int) {
        val p = paramsRef.get()
        val cap = deckCapture
        a.render(n, p.a, cap)
        b.render(n, p.b, cap)

        // house = both main sends (the clean stereo mix)
        val ao = a.out; val bo = b.out
        for (i in 0 until n * 2) house[i] = ao[i] + bo[i]
        pulse.note(house, n)
        val tap = tapSink
        if (tap != null && tap.isCapturing) tap.onHouse(house, n)

        // house pan only while any deck is cued (PFL split); otherwise untouched stereo
        if (p.house.housePan != 0f) Ramps.pan(house, n, p.house.housePan)

        // cue sends land on the cue side
        for (c in CHAINS) {
            val ch = if (c == 0) a else b
            if (!ch.cueLive) continue
            val co = ch.cueOut
            Ramps.pan(co, n, p.house.cuePan)
            for (i in 0 until n * 2) house[i] += co[i]
        }

        limiter.bypass = p.house.limiterBypass
        limiter.process(house, n)
    }

    // ------------------------------------------------------------------ control: handover

    /** Is the deck currently on (or heading to) its stems? */
    fun isOnStems(d: Deck): Boolean = deck(d).handover.intentStems

    /**
     * Cross-fade the deck from the full mix to its stems (or back) over 60 ms LINEAR. The incoming
     * voices are seeked to the outgoing side's exact source position at the fade start
     * (`now + [leadSeconds]`, on the deck's input clock) and started there at gain 0; the outgoing
     * voices are stopped by the render thread when the fade lands. Returns the plan generation
     * (compare with `handover.landedGen`). A newer call supersedes an in-flight fade (the LAST
     * intent wins, starting from the current gains: no dip, no dead air).
     *
     * The caller must have loaded the incoming voices and have enough decoded runway; if the
     * incoming side is not aligned when the fade starts the render thread aborts the plan
     * (`handover.abortedGen`) and the outgoing side keeps playing.
     */
    fun crossfadeTo(d: Deck, toStems: Boolean, leadSeconds: Double = DEFAULT_HANDOVER_LEAD): Int {
        val ch = deck(d)
        val h = ch.handover
        val m = ch.main; val g = ch.stems
        val incomingLive = if (toStems) h.publishedStem > 0f else h.publishedMain > 0f
        ch.stamp.read(posBuf)
        // iOS only cross-fades an AUDIBLE deck. A paused / stream-held / empty outgoing side switches
        // outright, and the new side starts only if the deck's transport is playing.
        val outV = if (toStems) m else g?.voices?.getOrNull(0)
        val audible = incomingLive || (outV != null && outV.isPlaying && outV.status == Voice.Status.PLAYING)
        val startAt = posBuf[0] + Math.round(leadSeconds * sampleRate)
        if (!audible) {
            val transportPlaying = outV?.isPlaying == true
            val pos = if (toStems) posBuf[1] else posBuf[2]
            if (toStems) { g?.seekAll(pos); g?.pauseAll() } else { m?.seek(pos); m?.pause() }
            // outright switch: pause the outgoing side, land the gains at the next block
            if (toStems) m?.pause() else g?.pauseAll()
            if (transportPlaying) { if (toStems) g?.startAt(-1) else m?.play(-1) }
            return h.settle(toStems)
        }
        if (!incomingLive) {
            val outPos = if (toStems) posBuf[1] else posBuf[2]
            val pos = outPos + (startAt - posBuf[0])
            if (toStems) { g?.seekAll(pos); g?.startAt(startAt) } else { m?.seek(pos); m?.play(startAt) }
        }
        return h.schedule(toStems, startAt)
    }

    /** Land the deck's intent immediately (next block, no fade): settle before any transport. */
    fun settleHandover(d: Deck): Int = deck(d).handover.settle()

    /** Install the deck's full-mix voice. */
    fun setMain(d: Deck, v: Voice?) { deck(d).main = v }

    /** Install the deck's four stem voices (vocals, drums, bass, other). */
    fun setStems(d: Deck, g: VoiceGroup?) {
        require(g == null || g.voices.size == DeckParams.STEMS)
        deck(d).stems = g
    }

    companion object {
        const val DEFAULT_HANDOVER_LEAD = 0.25
        private val CHAINS = intArrayOf(0, 1)
    }
}
