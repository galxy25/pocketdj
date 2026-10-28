package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.studio.audio.NativeDsp
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.dsp.MasterFx
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFx
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioMasterFX
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** Studio model -> kernel params (iOS `MasterFXParams.init(_, bpm:, allowFreeze:)`). */
fun StudioMasterFX.toKernelParams(bpm: Double, allowFreeze: Boolean): MasterFxParams = MasterFxParams(
    phaser = phaserEnabled, phaserRate = phaserRate, phaserDepth = phaserDepth,
    ringMod = ringModEnabled, ringFreq = ringModFreqHz, ringMix = ringModMix,
    freeze = allowFreeze && freezeEnabled,
    brazil = brazilianBassEnabled, brazilAmount = brazilianBassAmount,
    drive = driveEnabled, driveAmount = driveAmount,
    masterGain = MasterFxParams.gainFromDb(masterGainDb), bpm = bpm,
)

fun StudioChannelStrip.toKernelParams(bpm: Double): TrackFxParams = TrackFxParams(
    eqLowDb = eqLowDb, eqMidDb = eqMidDb, eqHighDb = eqHighDb,
    reverb = reverb, delay = delay, chorus = chorus, bpm = bpm,
)

/**
 * The audio-thread render state for the arranger: decoded/pre-baked clips (immutable after load), LIVE
 * per-track gain/pan/FX and master-FX (written from the UI thread, read on the render thread; torn reads
 * during a knob drag are benign), a loop region and a frame cursor. One [render] call sums every clip
 * overlapping the block, runs per-track TrackFX only for tracks with active FX (neutral tracks keep the
 * direct-sum fast path), sums to master, runs MasterFX and peak-limits. Port of iOS
 * `MultitrackRenderContext`; the same math backs an offline pull ([renderOffline]) for WYSIWYG tests.
 */
class MultitrackRenderContext(
    private val maxBlock: Int = 4096,
    private val newTrackFx: () -> TrackFx = { NativeDsp.trackFx(StudioAudio.CANONICAL_RATE.toDouble()) },
    private val master: MasterFx = NativeDsp.masterFx(StudioAudio.CANONICAL_RATE.toDouble()),
) : BlockRenderer {

    /** A decoded, pre-baked clip: interleaved canonical stereo [samples]; plays frames [srcStart, srcStart+frameLength). */
    class Clip(
        val trackIndex: Int, val startFrame: Int, val frameLength: Int,
        val srcStart: Int, val samples: FloatArray,
    )

    private var clipsByTrack: List<List<Clip>> = emptyList()
    private var trackCount = 0

    // Live per-track scalars, index = track index.
    private var gain = FloatArray(0)
    private var panL = FloatArray(0)
    private var panR = FloatArray(0)
    private var trackFx: List<TrackFx> = emptyList()
    private var fxOn = BooleanArray(0)

    @Volatile private var looping = false
    @Volatile private var loopStart = 0
    @Volatile private var loopEnd = 0
    private var cursor = 0
    private var renderedTotal = 0L
    @Volatile private var masterOn = false
    @Volatile private var limitLive = true
    private var limiterGain = 1f

    private val scratch = arrayOf(FloatArray(maxBlock), FloatArray(maxBlock))
    private val mixL = FloatArray(maxBlock)
    private val mixR = FloatArray(maxBlock)
    private val planarMaster = arrayOf(FloatArray(maxBlock), FloatArray(maxBlock))

    /** Absolute frame the NEXT block starts at (timeline coordinates, loop-wrapped). */
    val cursorFrame: Int get() = cursor
    val totalRendered: Long get() = renderedTotal

    /** Build the immutable clip set + cursor/loop geometry (before the sink starts). */
    fun load(clips: List<Clip>, trackCount: Int, cursor: Int, looping: Boolean, loopStart: Int, loopEnd: Int) {
        this.trackCount = max(trackCount, 0)
        gain = FloatArray(this.trackCount)
        panL = FloatArray(this.trackCount) { 1f }
        panR = FloatArray(this.trackCount) { 1f }
        clipsByTrack = List(this.trackCount) { ti -> clips.filter { it.trackIndex == ti } }
        trackFx.forEach { it.close() }
        trackFx = List(this.trackCount) { newTrackFx() }
        fxOn = BooleanArray(this.trackCount)
        this.cursor = cursor
        // Anchor the FX phase base to the START frame so the beat-synced Brazilian bass pump lands on the
        // arrangement's real beats after a seek (iOS: renderedTotal = cursor).
        this.renderedTotal = cursor.toLong()
        this.looping = looping; this.loopStart = loopStart; this.loopEnd = loopEnd
    }

    /** Live per-track mix: [gainLinear] 0 = inaudible; pan is centre-unity balance. */
    fun setTrackMix(index: Int, gainLinear: Float, pan: Float) {
        if (index < 0 || index >= trackCount) return
        gain[index] = gainLinear
        val p = pan.coerceIn(-1f, 1f)
        panL[index] = if (p <= 0f) 1f else 1f - p
        panR[index] = if (p >= 0f) 1f else 1f + p
    }

    /** Live per-track FX; neutral params disengage the scratch path. */
    fun setTrackFx(index: Int, p: TrackFxParams) {
        if (index < 0 || index >= trackFx.size) return
        trackFx[index].update(p)
        fxOn[index] = p.active
    }

    fun setMasterFx(p: MasterFxParams) { master.update(p); masterOn = p.active }

    fun setLoop(looping: Boolean, start: Int, end: Int) { this.looping = looping; loopStart = start; loopEnd = end }

    override fun render(out: FloatArray, frames: Int) {
        var done = 0
        while (done < frames) {
            val n = min(maxBlock, frames - done)
            renderChunk(out, done * 2, n)
            done += n
        }
    }

    private fun renderChunk(out: FloatArray, o: Int, frames: Int) {
        java.util.Arrays.fill(out, o, o + frames * 2, 0f)
        var written = 0
        var pos = cursor
        val ls = loopStart; val le = loopEnd
        val hasLoop = looping && le > ls
        if (hasLoop && (pos < ls || pos >= le)) pos = ls
        while (written < frames) {
            val chunk = if (hasLoop) min(frames - written, max(1, le - pos)) else frames - written
            for (ti in 0 until trackCount) {
                val g = gain[ti]
                if (g == 0f) continue
                val gl = panL[ti] * g; val gr = panR[ti] * g
                if (fxOn[ti]) mixTrackFx(ti, out, o + written * 2, pos, chunk, gl, gr)
                else for (clip in clipsByTrack[ti]) sumClip(clip, out, o + written * 2, pos, chunk, gl, gr)
            }
            written += chunk
            pos += chunk
            if (hasLoop && pos >= le) pos = ls
        }
        cursor = pos

        if (masterOn) {
            for (i in 0 until frames) { planarMaster[0][i] = out[o + 2 * i]; planarMaster[1][i] = out[o + 2 * i + 1] }
            master.process(planarMaster, frames, renderedTotal.toDouble())
            for (i in 0 until frames) { out[o + 2 * i] = planarMaster[0][i]; out[o + 2 * i + 1] = planarMaster[1][i] }
        }
        renderedTotal += frames
        if (limitLive) peakLimit(out, o, frames)
    }

    /** Sum one clip's overlap with [pos, pos+chunk) into [dst] (interleaved) at frame offset [dstOff] floats. */
    private fun sumClip(c: Clip, dst: FloatArray, dstOff: Int, pos: Int, chunk: Int, gl: Float, gr: Float) {
        val os = max(c.startFrame, pos); val oe = min(c.startFrame + c.frameLength, pos + chunk)
        if (oe <= os) return
        var d = dstOff + (os - pos) * 2
        var s = (c.srcStart + (os - c.startFrame)) * 2
        for (i in 0 until oe - os) { dst[d] += c.samples[s] * gl; dst[d + 1] += c.samples[s + 1] * gr; d += 2; s += 2 }
    }

    /** Scratch path: sum raw clips, run channel-strip FX (tails ring past a clip's end), then pan/gain into master. */
    private fun mixTrackFx(ti: Int, out: FloatArray, dstOff: Int, pos: Int, chunk: Int, gl: Float, gr: Float) {
        java.util.Arrays.fill(mixL, 0, chunk, 0f); java.util.Arrays.fill(mixR, 0, chunk, 0f)
        for (c in clipsByTrack[ti]) {
            val os = max(c.startFrame, pos); val oe = min(c.startFrame + c.frameLength, pos + chunk)
            if (oe <= os) continue
            val local = os - pos
            var s = (c.srcStart + (os - c.startFrame)) * 2
            for (i in 0 until oe - os) { mixL[local + i] += c.samples[s]; mixR[local + i] += c.samples[s + 1]; s += 2 }
        }
        scratch[0].let { System.arraycopy(mixL, 0, it, 0, chunk) }
        scratch[1].let { System.arraycopy(mixR, 0, it, 0, chunk) }
        trackFx[ti].process(scratch, chunk)
        var d = dstOff
        for (i in 0 until chunk) { out[d] += scratch[0][i] * gl; out[d + 1] += scratch[1][i] * gr; d += 2 }
    }

    private fun peakLimit(out: FloatArray, o: Int, frames: Int) {
        var g = limiterGain
        val rel = 1f / (0.05f * StudioAudio.CANONICAL_RATE)
        for (i in 0 until frames) {
            val l = out[o + 2 * i]; val r = out[o + 2 * i + 1]
            val pk = max(abs(l), abs(r))
            if (pk * g > 1f) g = 1f / pk else if (g < 1f) g = min(1f, g + rel)
            out[o + 2 * i] = (l * g).coerceIn(-1f, 1f); out[o + 2 * i + 1] = (r * g).coerceIn(-1f, 1f)
        }
        limiterGain = g
    }

    /** Offline pull of [frames] (no live limiter; callers peak-normalize like the bouncer). */
    fun renderOffline(frames: Int, block: Int = 512): FloatArray {
        val out = FloatArray(frames * 2)
        val tmp = FloatArray(block * 2)
        limitLive = false
        try {
            var done = 0
            while (done < frames) {
                val n = min(block, frames - done)
                render(tmp, n)
                System.arraycopy(tmp, 0, out, done * 2, n * 2)
                done += n
            }
        } finally { limitLive = true }
        return out
    }

    fun release() { trackFx.forEach { it.close() }; trackFx = emptyList(); master.close() }

    companion object {
        /** Audible linear gain for a track (mute/solo, solo wins; dB clamped -24..+6 like iOS). */
        fun audibleGain(gainDb: Double, muted: Boolean, soloed: Boolean, anySolo: Boolean): Float {
            val audible = if (anySolo) soloed else !muted
            if (!audible) return 0f
            return 10.0.pow(gainDb.coerceIn(-24.0, 6.0) / 20.0).toFloat()
        }

        fun msToFrames(ms: Int, rate: Int = StudioAudio.CANONICAL_RATE): Int =
            (ms.toDouble() / 1000.0 * rate).roundToInt()
    }
}
