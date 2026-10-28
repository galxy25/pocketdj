package com.levi.pocketdj.studio.audio

import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.dsp.MasterFx
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFx
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/** A pull source: write up to [frames] interleaved stereo frames into [out] (pre-zeroed); returns frames produced. */
fun interface PullSource {
    fun pull(out: FloatArray, frames: Int): Int
}

/**
 * Plays a canonical [PcmBuffer] from a frame cursor, optionally looping the whole buffer (loop
 * audition). The cursor is atomic so a UI thread can [seek] while the render thread pulls.
 */
class PcmClipSource(private val pcm: PcmBuffer, val loop: Boolean = false) : PullSource {
    private val cursor = AtomicLong(0)
    val position: Long get() = cursor.get()
    val finished: Boolean get() = !loop && cursor.get() >= pcm.frames

    fun seek(frame: Long) { cursor.set(max(0, frame)) }

    override fun pull(out: FloatArray, frames: Int): Int {
        val total = pcm.frames
        if (total == 0) return 0
        var produced = 0
        var pos = cursor.get()
        val s = pcm.samples
        while (produced < frames) {
            if (pos >= total) { if (!loop) break else pos = 0 }
            val n = min(frames - produced, (total - pos).toInt())
            System.arraycopy(s, (pos * 2).toInt(), out, produced * 2, n * 2)
            produced += n
            pos += n
        }
        cursor.set(pos)
        return produced
    }
}

/**
 * The pull API the Studio output callback drives (what the native/AudioTrack sink asks for each
 * block): per-track source -> strip FX -> gain/pan -> sum -> master FX -> clamp. The SAME math runs
 * live and in [renderOffline] (bounce == live). Control setters are safe from any thread; the track
 * list is copy-on-write and per-track values are volatile snapshots (a torn read during a knob drag
 * is benign, as on iOS).
 */
class RenderGraph(
    private val maxBlock: Int = 4096,
    private val newTrackFx: () -> TrackFx = { TrackFxKernel(StudioAudio.CANONICAL_RATE.toDouble(), 2) },
    private val master: MasterFx = MasterFxKernel(StudioAudio.CANONICAL_RATE.toDouble(), 2),
) : BlockRenderer {
    class Track internal constructor(val id: String, val fx: TrackFx) {
        @Volatile var source: PullSource? = null
        @Volatile var gain: Float = 1f
        /** -1 (left) ... +1 (right); equal-power. */
        @Volatile var pan: Float = 0f
        @Volatile var mute = false
        @Volatile var solo = false
    }

    @Volatile private var tracks: List<Track> = emptyList()
    private val frameCursor = AtomicLong(0)
    private var trackBuf = FloatArray(maxBlock * 2)
    private val planar = arrayOf(FloatArray(maxBlock), FloatArray(maxBlock))
    @Volatile private var masterOn = false
    @Volatile var masterBpm: Double = 120.0

    /** Frames rendered so far (drives the Brazilian-bass beat phase). */
    val position: Long get() = frameCursor.get()

    @Synchronized fun addTrack(id: String, source: PullSource? = null): Track {
        val t = Track(id, newTrackFx()); t.source = source
        tracks = tracks + t
        return t
    }

    @Synchronized fun removeTrack(id: String) {
        val gone = tracks.filter { it.id == id }
        tracks = tracks.filterNot { it.id == id }
        gone.forEach { it.fx.close() }
    }

    fun track(id: String): Track? = tracks.firstOrNull { it.id == id }

    fun setTrackFx(id: String, p: TrackFxParams) { track(id)?.fx?.update(p) }

    fun setMasterFx(p: MasterFxParams) { master.update(p); masterOn = true }

    /** Seek the beat phase (loop/seek). Track sources are repositioned by their owners. */
    fun seek(frame: Long) { frameCursor.set(max(0, frame)) }

    /** Equal-power pan gain for [pan] in -1...1; unity on both channels at centre. No allocation. */
    fun panGainL(pan: Float): Float = kotlin.math.cos((pan.coerceIn(-1f, 1f) + 1f) * (Math.PI.toFloat() / 4f)) * ROOT2
    fun panGainR(pan: Float): Float = kotlin.math.sin((pan.coerceIn(-1f, 1f) + 1f) * (Math.PI.toFloat() / 4f)) * ROOT2

    override fun render(out: FloatArray, frames: Int) {
        var done = 0
        while (done < frames) {
            val n = min(maxBlock, frames - done)
            renderChunk(out, done, n)
            done += n
        }
    }

    private fun renderChunk(out: FloatArray, offFrames: Int, frames: Int) {
        val o = offFrames * 2
        java.util.Arrays.fill(out, o, o + frames * 2, 0f)
        val list = tracks
        val anySolo = list.any { it.solo }
        for (t in list) {
            if (t.mute || (anySolo && !t.solo)) continue
            val src = t.source ?: continue
            java.util.Arrays.fill(trackBuf, 0, frames * 2, 0f)
            if (src.pull(trackBuf, frames) <= 0) { if (!t.fx.active) continue }
            if (t.fx.active) {
                for (i in 0 until frames) { planar[0][i] = trackBuf[2 * i]; planar[1][i] = trackBuf[2 * i + 1] }
                t.fx.process(planar, frames)
                for (i in 0 until frames) { trackBuf[2 * i] = planar[0][i]; trackBuf[2 * i + 1] = planar[1][i] }
            }
            val gL = t.gain * panGainL(t.pan); val gR = t.gain * panGainR(t.pan)
            for (i in 0 until frames) {
                out[o + 2 * i] += trackBuf[2 * i] * gL
                out[o + 2 * i + 1] += trackBuf[2 * i + 1] * gR
            }
        }
        if (masterOn) {
            for (i in 0 until frames) { planar[0][i] = out[o + 2 * i]; planar[1][i] = out[o + 2 * i + 1] }
            master.process(planar, frames, frameCursor.get().toDouble())
            for (i in 0 until frames) { out[o + 2 * i] = planar[0][i]; out[o + 2 * i + 1] = planar[1][i] }
        }
        for (i in o until o + frames * 2) out[i] = out[i].coerceIn(-1f, 1f)
        frameCursor.addAndGet(frames.toLong())
    }

    /** Render [frames] frames offline into a new buffer (bounce path; same math as live). */
    fun renderOffline(frames: Int, block: Int = 512): PcmBuffer {
        val out = FloatArray(frames * 2)
        val tmp = FloatArray(block * 2)
        var done = 0
        while (done < frames) {
            val n = min(block, frames - done)
            render(tmp, n)
            System.arraycopy(tmp, 0, out, done * 2, n * 2)
            done += n
        }
        return PcmBuffer(StudioAudio.CANONICAL_RATE, 2, out)
    }

    fun release() { tracks.forEach { it.fx.close() }; tracks = emptyList(); master.close() }

    private companion object { const val ROOT2 = 1.4142135f }
}
