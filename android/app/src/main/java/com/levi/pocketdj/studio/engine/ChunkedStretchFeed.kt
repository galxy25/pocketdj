package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Q109: a warped (Beat Match / tempo / pitch) clip window streamed through the offline stretcher in
 * bounded chunks, so the play-start heap is O(chunk) instead of O(window).
 *
 * The output timeline (window length / rate frames) is cut into cores of [chunkOut] frames. Chunk i renders
 * its core PLUS [xf] frames past it, from a source excerpt that also carries [pad] source frames of
 * context on each side (a phase vocoder smears its first/last analysis windows; that context is rendered
 * and thrown away, never heard). At each seam the previous chunk's [xf]-frame extension is linearly
 * crossfaded into the next chunk's head, so any residual phase difference between two independent
 * stretch calls becomes a ~90 ms blend instead of a step (no click). Only the window's true start and
 * end see an un-padded stretch edge, exactly as the whole-window bake did.
 *
 * Sequential consumer: [fill] is driven by [ClipPageStore.writeStream] front to back. Heap: one chunk of
 * source + one chunk of output + the [xf] tail.
 */
internal class ChunkedStretchFeed(
    /** Source window length in frames (window-relative frame 0 = the clip's fileStartMs). */
    private val win: Int,
    /** Output length; the same `max(1, round(win / rate))` the whole-window bake produces. */
    val outTotal: Int,
    chunkOutTarget: Int,
    block: Int,
    xfTarget: Int = XF_FRAMES,
    private val pad: Int = PAD_FRAMES,
    /** Window-relative source [start, start+len) as canonical stereo; may come back short (padded with silence). Null = failure. */
    private val fetch: (start: Int, len: Int) -> PcmBuffer?,
    /** Stretch a whole excerpt (frames / rate out); null = failure. */
    private val stretch: (PcmBuffer) -> PcmBuffer?,
    /** Polled once per chunk; true aborts with a [java.util.concurrent.CancellationException]. */
    private val stop: () -> Boolean = { false },
) {
    /** Output frames per core: a whole number of [block]s, so a page block never straddles two chunks' bookkeeping. */
    val chunkOut: Int = max(block, chunkOutTarget - chunkOutTarget % max(1, block))
    private val xf = xfTarget.coerceIn(0, chunkOut)
    /** Source frames per output frame across the whole window (the global time map). */
    private val q = if (outTotal > 0) win.toDouble() / outTotal else 1.0
    private val padOut = ceil(pad / max(q, 1e-9)).toInt()

    private var curIndex = -1
    private var cur: FloatArray? = null
    private var curFrames = 0
    /** Global output frame that local output frame 0 of [cur] corresponds to. */
    private var curBase = 0
    private val tail = FloatArray(xf * 2)
    private var tailFrames = 0

    /** Largest source excerpt fetched / output chunk held (frames): the heap bound tests assert. */
    var maxFetchFrames = 0; private set
    var maxOutFrames = 0; private set
    var chunksRendered = 0; private set

    fun fill(out: FloatArray, at: Int, n: Int) {
        for (f in 0 until n) {
            val k = at + f
            val i = k / chunkOut
            if (i != curIndex) load(i)
            val j = k - curBase
            var l = 0f; var r = 0f
            val c = cur
            if (c != null && j in 0 until curFrames) { l = c[2 * j]; r = c[2 * j + 1] }
            val inXf = k - i * chunkOut
            if (i > 0 && inXf < tailFrames) {
                val w = (inXf + 0.5f) / tailFrames
                l = tail[2 * inXf] * (1f - w) + l * w
                r = tail[2 * inXf + 1] * (1f - w) + r * w
            }
            out[2 * f] = l; out[2 * f + 1] = r
        }
    }

    private fun load(i: Int) {
        val a = i * chunkOut
        // Hand-off: the previous chunk rendered xf frames past its core; keep them for the blend.
        tailFrames = 0
        if (i == curIndex + 1 && cur != null) {
            val n = min(xf, outTotal - a).coerceAtLeast(0)
            val c = cur!!
            for (t in 0 until n) {
                val j = a + t - curBase
                if (j in 0 until curFrames) { tail[2 * t] = c[2 * j]; tail[2 * t + 1] = c[2 * j + 1] }
                else { tail[2 * t] = 0f; tail[2 * t + 1] = 0f }
            }
            tailFrames = n
        }
        cur = null; curFrames = 0 // release before the next decode: never two chunks on the heap
        if (stop()) throw java.util.concurrent.CancellationException("plan superseded")
        val oEnd = min(outTotal, a + chunkOut + xf)
        val m = max(0, a - padOut)                       // first output frame the excerpt yields
        val sS = (m * q).roundToInt().coerceIn(0, win)
        val sE = min(win, ceil(min(outTotal, oEnd + padOut) * q).toInt())
        val len = max(1, sE - sS)
        val src = fetch(sS, len) ?: throw java.io.IOException("chunk decode failed at source frame $sS")
        val exact = if (src.frames == len && src.channels == 2) src else padTo(src, len)
        maxFetchFrames = max(maxFetchFrames, len)
        val y = stretch(exact) ?: throw java.io.IOException("chunk stretch failed at source frame $sS")
        val st = if (y.channels == 2) y else padTo(y, y.frames)
        // Local output j of this excerpt is source sS + j*q, i.e. global output frame sS/q + j.
        cur = st.samples; curFrames = st.frames; curBase = (sS / q).roundToInt()
        maxOutFrames = max(maxOutFrames, curFrames)
        curIndex = i
        chunksRendered++
    }

    private fun padTo(src: PcmBuffer, frames: Int): PcmBuffer {
        val out = FloatArray(frames * 2)
        val c = src.channels; val s = src.samples
        val n = min(frames, src.frames)
        for (f in 0 until n) {
            when (c) {
                2 -> { out[2 * f] = s[2 * f]; out[2 * f + 1] = s[2 * f + 1] }
                1 -> { out[2 * f] = s[f]; out[2 * f + 1] = s[f] }
                else -> { out[2 * f] = s[f * c]; out[2 * f + 1] = s[f * c + 1] }
            }
        }
        return PcmBuffer(src.sampleRate, 2, out)
    }

    companion object {
        /** Seam crossfade in output frames (~93 ms). */
        const val XF_FRAMES = 4096
        /** Discarded stretch context on each side of an excerpt, in source frames (~0.5 s: several Signalsmith windows). */
        const val PAD_FRAMES = 22_050

        fun outFrames(win: Int, rate: Double): Int = max(1L, Math.round(win / rate.coerceIn(1.0 / 32.0, 32.0))).toInt()

        /** Output-frame core for a [chunkSourceFrames]-bounded chunk: neither the source excerpt nor the output exceeds it. */
        fun coreFrames(chunkSourceFrames: Int, rate: Double): Int = max(1, floor(chunkSourceFrames / max(1.0, rate)).toInt())
    }
}
