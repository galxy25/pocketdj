package com.levi.pocketdj.studio.audio

import android.media.AudioManager
import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.AudioTrackSink
import com.levi.pocketdj.audio.core.OboeSink
import com.levi.pocketdj.audio.core.PcmBuffer
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Shared Studio audio constants + pure helpers (port of the Swift `StudioAudio` enum). Everything here
 * is platform-free so live audition and the offline renderer share ONE definition.
 */
object StudioAudio {
    const val CANONICAL_RATE = PcmBuffer.CANONICAL_RATE
    const val CANONICAL_CHANNELS = 2

    /** Tail-drain window / floor / cap (spec §4): stop at the first 512-frame window under -60 dBFS RMS, or after 3 s. */
    const val TAIL_WINDOW_FRAMES = 512
    const val TAIL_FLOOR_DB = -60.0
    const val TAIL_CAP_SECONDS = 3.0

    /** Is [b] the canonical processing shape (44.1 kHz stereo)? */
    fun isCanonical(b: PcmBuffer): Boolean = b.sampleRate == CANONICAL_RATE && b.channels == CANONICAL_CHANNELS

    /** dB -> linear, clamped to the sample-edit gain domain (-60...+12 dB). */
    fun gainMultiplier(db: Double): Float = 10.0.pow(min(12.0, max(-60.0, db)) / 20.0).toFloat()

    /** ms -> frame index at [rate], schoolbook-rounded like Swift `.rounded()`. */
    fun msToFrames(ms: Int, rate: Double): Long = Math.round(max(0, ms).toDouble() / 1000.0 * rate)

    /** Sample render nominal length: ceil(window * 44.1k / srcRate / rate). */
    fun nominalSampleFrames(sourceWindowFrames: Long, sourceRate: Double, rate: Double): Long =
        ceil(sourceWindowFrames.toDouble() * CANONICAL_RATE / sourceRate / rate).toLong()

    /** Loop render EXACT length: round(lengthMs/1000 * 44.1k / rate) — the authoritative LoopFrames. */
    fun exactLoopFrames(lengthMs: Int, rate: Double): Long =
        Math.round(lengthMs.toDouble() / 1000.0 * CANONICAL_RATE / rate)

    /** Frames for the tail-drain cap. */
    val tailCapFrames: Long get() = (TAIL_CAP_SECONDS * CANONICAL_RATE).toLong()

    /**
     * Copy [buffer] to EXACTLY [frames] frames: truncate extra content, zero-pad a shortfall. The
     * loop-seam contract: the authoritative frame count, never the container's. Null on frames <= 0.
     */
    fun trimmedOrPadded(buffer: PcmBuffer, frames: Long): PcmBuffer? {
        if (frames <= 0 || frames > Int.MAX_VALUE / buffer.channels) return null
        if (buffer.frames.toLong() == frames) return buffer
        val out = FloatArray(frames.toInt() * buffer.channels)
        System.arraycopy(buffer.samples, 0, out, 0, min(buffer.samples.size, out.size))
        return PcmBuffer(buffer.sampleRate, buffer.channels, out)
    }

    /** [frames] frames from [from]; null on a bad window (never zero-pads). */
    fun slice(buffer: PcmBuffer, from: Long, frames: Long): PcmBuffer? {
        if (from < 0 || frames <= 0 || from + frames > buffer.frames) return null
        val c = buffer.channels
        return PcmBuffer(buffer.sampleRate, c, buffer.samples.copyOfRange((from * c).toInt(), ((from + frames) * c).toInt()))
    }

    /** RMS of interleaved samples in [from, from+count) as dBFS; silence/empty => -inf. */
    fun rmsDb(samples: FloatArray, from: Int, count: Int): Double {
        if (count <= 0) return Double.NEGATIVE_INFINITY
        var sum = 0.0
        for (i in from until from + count) sum += samples[i].toDouble() * samples[i]
        val rms = sqrt(sum / count)
        return if (rms <= 0) Double.NEGATIVE_INFINITY else 20 * kotlin.math.log10(rms)
    }

    /** Tail-drain stop condition: whole window's RMS below [floorDb]. An empty window counts as silence. */
    fun isBelowFloor(samples: FloatArray, from: Int, count: Int, floorDb: Double = TAIL_FLOOR_DB): Boolean {
        if (count <= 0) return true
        var sum = 0.0
        for (i in from until from + count) sum += samples[i].toDouble() * samples[i]
        return sqrt(sum / count) < 10.0.pow(floorDb / 20.0)
    }

    /** Float-sum canonical [buffers] to the LONGEST length, hard-clamped to +-1.0 (polyphonic mixdown). */
    fun mixPcm(buffers: List<PcmBuffer>): PcmBuffer {
        val longest = buffers.maxOfOrNull { it.frames } ?: 0
        require(longest > 0) { "nothing to mix" }
        val out = FloatArray(longest * 2)
        for (b in buffers) {
            val s = b.toStereo().samples
            for (i in s.indices) out[i] += s[i]
        }
        for (i in out.indices) out[i] = out[i].coerceIn(-1f, 1f)
        return PcmBuffer(CANONICAL_RATE, 2, out)
    }

    /** Sum [src] into [acc] (acc length is the authority; a short stem contributes silence for the tail). */
    fun addInto(acc: FloatArray, src: PcmBuffer) {
        val s = src.toStereo().samples
        for (i in 0 until min(acc.size, s.size)) acc[i] += s[i]
    }

    /**
     * Varispeed relabel: keep the samples, call them canonical-rate (the Quantized record mode). A 48 kHz
     * capture becomes ~1.088x longer and ~1.5 semitones flatter; a 44.1 capture is a no-op.
     */
    fun relabeled(b: PcmBuffer): PcmBuffer = PcmBuffer(CANONICAL_RATE, 2, b.toStereo().samples)
}

/** Device vs emulator sink choice for Studio (decision D1). */
object StudioOutputs {
    enum class Backend { OBOE, AUDIO_TRACK }

    fun looksLikeEmulator(fingerprint: String?, hardware: String?, product: String?): Boolean {
        val f = fingerprint.orEmpty().lowercase(); val h = hardware.orEmpty().lowercase(); val p = product.orEmpty().lowercase()
        return f.startsWith("generic") || f.contains("emulator") || h.contains("ranchu") || h.contains("goldfish") ||
            p.contains("sdk_gphone") || p.contains("emulator")
    }

    /** Oboe only on a real device with the native library present; everything else uses [AudioTrackSink]. */
    fun chooseBackend(nativeAvailable: Boolean, isEmulator: Boolean): Backend =
        if (nativeAvailable && !isEmulator) Backend.OBOE else Backend.AUDIO_TRACK

    fun create(audioManager: AudioManager, sampleRate: Int = CANONICAL_RATE_INT, blockFrames: Int = 512): AudioSink {
        val emu = looksLikeEmulator(android.os.Build.FINGERPRINT, android.os.Build.HARDWARE, android.os.Build.PRODUCT)
        return when (chooseBackend(NativeDsp.available, emu)) {
            Backend.OBOE -> OboeSink(sampleRate, blockFrames) { NativeDsp.oboeBackend(sampleRate, blockFrames * 4) }
            Backend.AUDIO_TRACK -> AudioTrackSink(audioManager, sampleRate, blockFrames)
        }
    }

    private const val CANONICAL_RATE_INT = StudioAudio.CANONICAL_RATE
}
