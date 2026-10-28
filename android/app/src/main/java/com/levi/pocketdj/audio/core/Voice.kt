package com.levi.pocketdj.audio.core

import kotlin.math.abs

/**
 * One playable stream: a [PcmSource] pumped by a decoder thread into a lock-free [FloatRing] and
 * consumed on the render thread by [read].
 *
 * Invariants (hard-won on iOS, see mix audit):
 *  - [read] never allocates and never blocks. Empty ring + not ended => silence + [underrun]
 *    (the HOLD signal: position does not advance, the engine decides what to do).
 *  - A schedule/seek is a 3-step handshake so the render thread never reads stale audio:
 *    control bumps the plan generation -> decoder acknowledges (quiescent) -> render thread flushes
 *    the ring and acknowledges -> decoder seeks the source and refills.
 *  - Loop windows wrap in the DECODER (so the ring already carries the looped stream) and in the
 *    position counter identically; a loop wraps frame-exactly with no gap.
 *  - Scheduled start (`play(atRenderFrame)`) lands on one exact render frame, so N voices started
 *    together share a sample-accurate start (the iOS StemSync lesson).
 *
 * Frames are FILE frames at [sampleRate]. Sources of another rate/channel count are wrapped in a
 * [ConvertedSource] (mono upmix, linear resample fallback).
 */
class Voice(
    source: PcmSource,
    val sampleRate: Int = 44_100,
    ringSeconds: Double = 3.0,
    val name: String = "voice",
) {
    enum class Status { IDLE, SCHEDULED, PLAYING, UNDERRUN, ENDED }

    private class Plan(
        val gen: Int, val from: Long, val loopStart: Long, val loopEnd: Long,
    ) {
        val looping: Boolean get() = loopEnd > loopStart && loopStart >= 0
    }

    private val source: PcmSource =
        if (source.sampleRate == sampleRate && source.channels == 2) source else ConvertedSource(source, sampleRate)
    private val ring = FloatRing(maxOf(1, (ringSeconds * sampleRate).toInt()) * 2)

    // ---- control-thread state (volatile reads on the other threads) ----
    @Volatile private var plan = Plan(0, 0, -1, -1)
    @Volatile private var endFrame: Long = Long.MAX_VALUE
    @Volatile private var endFinal = true
    @Volatile private var startAt: Long = NOT_PLAYING
    @Volatile private var targetGain = 1f

    // ---- decoder-thread state ----
    @Volatile private var ack = -1
    private var decodeGen = -1
    private var decodePos = 0L
    @Volatile private var atEndGen = -1
    @Volatile private var sourceEnded = false
    private val chunk = FloatArray(CHUNK_FRAMES * 2)

    // ---- render-thread state ----
    @Volatile private var consumerGen = -1
    @Volatile private var pos = 0L
    private var curGain = 1f
    private var wasStarted = false

    /** True when the last [read] could not fill the block (hold signal). */
    @Volatile var underrun = false; private set
    @Volatile var underrunCount = 0L; private set
    @Volatile var status = Status.IDLE; private set

    /** File frame of the next frame to be output. */
    val playerFrame: Long get() = pos

    val isPlaying: Boolean get() = startAt != NOT_PLAYING

    /** Frames decoded and waiting in the ring (valid once the handshake completed). */
    val bufferedFrames: Int get() = if (consumerGen == plan.gen) ring.readable / 2 else 0

    val totalFrames: Long get() = source.totalFrames

    // ---------------------------------------------------------------- control

    /** (Re)position at [from] with window end [to] (exclusive; default end of file). */
    fun schedule(from: Long, to: Long = Long.MAX_VALUE, final: Boolean = true) {
        endFrame = to
        endFinal = final
        val p = plan
        val f = normalize(from, p.loopStart, p.loopEnd)
        plan = Plan(p.gen + 1, f, p.loopStart, p.loopEnd)
    }

    /** Extend a growing window to [toFrontier] (only ever raises it). [final] marks true EOF. */
    fun append(toFrontier: Long, final: Boolean = false) {
        if (toFrontier > endFrame) endFrame = toFrontier
        endFinal = final
    }

    /** Loop [start,end) (file frames), re-seeking at the current position; (-1,-1) clears. */
    fun setLoop(start: Long, end: Long) {
        // a seek/schedule not yet acknowledged by the render thread owns the position
        val here = if (consumerGen != plan.gen) plan.from else pos
        val newStart = if (end > start && start >= 0) start else -1L
        val newEnd = if (end > start && start >= 0) end else -1L
        if (consumerGen == plan.gen && newStart == plan.loopStart && newEnd == plan.loopEnd) return // no-op: no flush/hold
        val f = if (end > start && start >= 0) normalize(here, start, end) else here
        plan = Plan(plan.gen + 1, f, newStart, newEnd)
    }

    fun seek(frame: Long) = schedule(frame, endFrame, endFinal)

    /** Begin playing at [atRenderFrame] (<0 = as soon as possible). */
    fun play(atRenderFrame: Long = -1) { startAt = if (atRenderFrame < 0) IMMEDIATE else atRenderFrame }

    fun pause() { startAt = NOT_PLAYING }

    /** Pause and rewind to the start of the window. */
    fun stop() { startAt = NOT_PLAYING; schedule(0, endFrame, endFinal) }

    fun setGain(g: Float) { targetGain = g }

    fun close() = source.close()

    // ---------------------------------------------------------------- decoder thread

    /** One unit of decoder work; true if it did something (caller may loop without sleeping). */
    fun pump(): Boolean {
        val p = plan
        if (ack != p.gen) { ack = p.gen; atEndGen = -1; return true }
        if (consumerGen != p.gen) return false // render thread hasn't flushed yet
        if (decodeGen != p.gen) {
            source.seek(p.from)
            decodePos = p.from
            decodeGen = p.gen
            sourceEnded = false
        }
        val end = endFrame
        val effEnd = if (p.looping) p.loopEnd else minOf(end, source.totalFrames.let { if (it < 0) Long.MAX_VALUE else it })
        val atEnd = sourceEnded || decodePos >= effEnd
        atEndGen = if (atEnd) p.gen else -1
        if (atEnd) return false
        val space = ring.writable / 2
        if (space <= 0) return false
        val n = minOf(space.toLong(), CHUNK_FRAMES.toLong(), effEnd - decodePos).toInt()
        val r = source.read(chunk, n)
        if (r < 0) { sourceEnded = true; atEndGen = p.gen; return false }
        if (r == 0) return false
        ring.write(chunk, 0, r * 2)
        decodePos += r
        if (p.looping && decodePos >= p.loopEnd) {
            source.seek(p.loopStart)
            decodePos = p.loopStart
        }
        return true
    }

    // ---------------------------------------------------------------- render thread

    /**
     * Fill [out] (interleaved stereo, [frames] frames) for the block that starts at render frame
     * [blockStart]. Always writes the whole block. No allocation, no blocking.
     */
    fun read(out: FloatArray, frames: Int, blockStart: Long): Status {
        val p = plan
        syncGeneration(p)
        val start = startAt
        if (start == NOT_PLAYING) return finish(out, 0, frames, Status.IDLE, false)
        if (consumerGen != p.gen) return finish(out, 0, frames, Status.UNDERRUN, true) // handshake pending: hold

        var lead = 0
        if (start != IMMEDIATE && start > blockStart) {
            val d = start - blockStart
            if (d >= frames) return finish(out, 0, frames, Status.SCHEDULED, false)
            lead = d.toInt()
        }
        wasStarted = true

        val atEnd = atEndGen == p.gen
        val want = frames - lead
        val got = ring.read(out, lead * 2, want * 2) / 2
        // gain ramp: linear across the block, per-sample step |delta|/frames <= 1/frames
        val g1 = targetGain
        val g0 = curGain
        if (g0 != 1f || g1 != 1f) {
            val step = (g1 - g0) / frames
            var g = g0
            var i = lead * 2
            val endI = (lead + got) * 2
            while (i < endI) { out[i] *= g; out[i + 1] *= g; g += step; i += 2 }
            curGain = g // partial when a scheduled-start lead shortened the ramp: the next block continues from here
            if (abs(g1 - curGain) < 1e-6f) curGain = g1
        }
        advance(got, p)

        val short = got < want
        var st = Status.PLAYING
        var under = false
        if (short) {
            java.util.Arrays.fill(out, (lead + got) * 2, frames * 2, 0f)
            if (atEnd && ring.readable == 0 && endFinal) st = Status.ENDED else { st = Status.UNDERRUN; under = true }
        }
        if (lead > 0) java.util.Arrays.fill(out, 0, lead * 2, 0f)
        underrun = under
        if (under) underrunCount++
        status = st
        return st
    }

    private fun syncGeneration(p: Plan) {
        if (consumerGen != p.gen && ack == p.gen) { ring.clearConsumer(); pos = p.from; consumerGen = p.gen; wasStarted = false }
    }

    /**
     * Would [read] for this block deliver the whole block (or end cleanly)? A [VoiceGroup] uses this to
     * hold ALL its voices when any one would underrun, so stems never drift apart.
     */
    fun canFill(frames: Int, blockStart: Long): Boolean {
        val p = plan
        val start = startAt
        if (start == NOT_PLAYING) return true
        if (consumerGen != p.gen) return false // handshake pending: read() would flush first, leaving an empty ring
        if (start != IMMEDIATE && start >= blockStart + frames) return true
        val lead = if (start != IMMEDIATE && start > blockStart) (start - blockStart).toInt() else 0
        if (ring.readable / 2 >= frames - lead) return true
        return atEndGen == p.gen && endFinal
    }

    /** Output silence for a block WITHOUT consuming anything (group hold). */
    fun hold(out: FloatArray, frames: Int): Status {
        syncGeneration(plan)
        val playing = startAt != NOT_PLAYING
        return finish(out, 0, frames, if (playing) Status.UNDERRUN else Status.IDLE, playing)
    }

    private fun finish(out: FloatArray, from: Int, frames: Int, st: Status, under: Boolean): Status {
        java.util.Arrays.fill(out, from * 2, frames * 2, 0f)
        underrun = under
        if (under) underrunCount++
        status = st
        return st
    }

    private fun advance(n: Int, p: Plan) {
        var q = pos + n
        if (p.looping) { val len = p.loopEnd - p.loopStart; while (q >= p.loopEnd) q -= len }
        pos = q
    }

    companion object {
        const val NOT_PLAYING = Long.MIN_VALUE
        const val IMMEDIATE = -1L
        const val CHUNK_FRAMES = 2048

        internal fun normalize(frame: Long, loopStart: Long, loopEnd: Long): Long =
            if (loopEnd > loopStart && loopStart >= 0 && frame >= loopEnd) loopStart else frame
    }
}

/** Decoder-thread driver: pumps a [Voice] until closed. */
class VoicePump(private val voice: Voice, name: String = "pdj-decode") {
    @Volatile private var running = true
    private val thread = Thread({
        while (running) {
            var any = false
            while (running && voice.pump()) any = true
            if (!any) try { Thread.sleep(4) } catch (_: InterruptedException) { }
        }
    }, name).apply { isDaemon = true }

    fun start(): VoicePump { thread.start(); return this }
    fun stop() { running = false; thread.interrupt() }
}
