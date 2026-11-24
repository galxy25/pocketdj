package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.dsp.Loudness
import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.demux.KeyDetector
import kotlin.math.max
import kotlin.math.min
import kotlinx.serialization.Serializable

/**
 * Progressive on-device analysis (port of iOS `AudioAnalysis`, np-dj-mode 5a): a QUICK pass over ~20 s of the
 * song (from ~30 % in for a complete file, the 15-30 s head for a growing one) published as a HINT, then a FULL
 * pass that replaces it.
 *
 * PRECEDENCE: measured server beat-grid / catalog > full on-device > confident quick hint > nothing. A hint
 * never overwrites better data; a low-confidence hint is MISSING (planner / glide degrade as they already do).
 * A loudness hint is clamped to +-[HINT_GAIN_CLAMP_DB] until the full value lands.
 */
object AudioAnalysis {
    /** The slice of song a pass decodes (song seconds; [headOnly] = the head of a file still arriving). */
    data class Window(val startSeconds: Double, val lengthSeconds: Double, val headOnly: Boolean)

    const val QUICK_SECONDS = 20.0
    const val MIN_HEAD_SECONDS = 15.0
    const val MAX_HEAD_SECONDS = 30.0
    const val QUICK_START_FRACTION = 0.3

    /** Below these a detection is treated as missing. */
    const val MIN_BPM_CONFIDENCE = 0.3
    const val MIN_KEY_CONFIDENCE = 0.7
    /** A loudness HINT moves the trim at most this far (dB) until the full measurement lands. */
    const val HINT_GAIN_CLAMP_DB = 4.0

    /** Decode rate for analysis passes (lower than the 44.1 kHz canonical: the detectors are rate-agnostic). */
    const val ANALYSIS_RATE = 22_050

    /**
     * The quick window for a song of [durationSeconds] (null = unknown) with [availableSeconds] decodable now;
     * [complete] = the whole file is on disk. Null => not enough audio yet.
     */
    fun quickWindow(durationSeconds: Double?, availableSeconds: Double, complete: Boolean): Window? {
        if (!(availableSeconds > 0)) return null
        if (complete) {
            val dur = durationSeconds?.let { min(it, availableSeconds) } ?: availableSeconds
            if (dur <= 2) return null
            val len = min(QUICK_SECONDS, dur)
            // ~30 % in, never past the end (a short song: the whole of it).
            val start = max(0.0, min(dur * QUICK_START_FRACTION, dur - len))
            return Window(start, len, headOnly = false)
        }
        if (availableSeconds < MIN_HEAD_SECONDS) return null
        return Window(0.0, min(availableSeconds, MAX_HEAD_SECONDS), headOnly = true)
    }

    // ---- results + precedence ----

    @Serializable
    enum class Kind { quick, full }

    /** Tolerant by construction ([com.levi.pocketdj.data.PdjJson.lenient]): every field has a default. */
    @Serializable
    data class Result(
        val kind: Kind = Kind.full,
        /** The window was the head of a file still arriving (re-run once it completes). */
        val headOnly: Boolean = false,
        val bpm: Double? = null,
        val bpmConfidence: Double = 0.0,
        val camelot: String? = null,
        val keyConfidence: Double = 0.0,
        val lufs: Double? = null,
    ) {
        /** The BPM if confident enough to use, else null (a low-confidence hint is MISSING). */
        val usableBPM: Double? get() = if (bpmConfidence >= MIN_BPM_CONFIDENCE) bpm else null
        val usableCamelot: String? get() = if (keyConfidence >= MIN_KEY_CONFIDENCE) camelot else null
    }

    /** Where a value came from (readouts show "estimated" for a hint). */
    enum class Source { NONE, QUICK, FULL, MEASURED }

    data class Pick<T>(val value: T?, val source: Source)

    /** BPM by precedence: measured (server grid / catalog) > full on-device > confident quick hint > nothing. */
    fun bpm(measured: Double?, full: Result?, quick: Result?): Pick<Double> {
        if (measured != null && measured > 0) return Pick(measured, Source.MEASURED)
        full?.usableBPM?.let { return Pick(it, Source.FULL) }
        quick?.usableBPM?.let { return Pick(it, Source.QUICK) }
        return Pick(null, Source.NONE)
    }

    /** Camelot key by the same ladder. */
    fun camelot(measured: String?, full: Result?, quick: Result?): Pick<String> {
        if (!measured.isNullOrEmpty()) return Pick(measured, Source.MEASURED)
        full?.usableCamelot?.let { return Pick(it, Source.FULL) }
        quick?.usableCamelot?.let { return Pick(it, Source.QUICK) }
        return Pick(null, Source.NONE)
    }

    /** The leveling gain: the full measurement's (LoudnessCache), else the quick hint's clamped to +-4 dB, else unknown. */
    fun levelGain(fullGainDb: Double?, quick: Result?): Pick<Double> {
        if (fullGainDb != null) return Pick(fullGainDb, Source.FULL)
        LoudnessLeveling.gainDb(quick?.lufs)?.let {
            return Pick(it.coerceIn(-HINT_GAIN_CLAMP_DB, HINT_GAIN_CLAMP_DB), Source.QUICK)
        }
        return Pick(null, Source.NONE)
    }

    /** True when a result changes a row's USABLE BPM or Camelot (a result re-plans only then). */
    fun usableChanged(beforeFull: Result?, beforeQuick: Result?, afterFull: Result?, afterQuick: Result?): Boolean =
        bpm(null, beforeFull, beforeQuick).value != bpm(null, afterFull, afterQuick).value ||
            camelot(null, beforeFull, beforeQuick).value != camelot(null, afterFull, afterQuick).value

    // ---- passes (blocking: call off-main) ----

    /** Platform seam: decode [lengthSeconds] of [path] from [startSeconds]; seconds decodable right now. */
    interface PassSource {
        fun decode(path: String, startSeconds: Double, lengthSeconds: Double): PcmBuffer?
        fun availableSeconds(path: String): Double
    }

    /** MediaCodec-backed decode (the container's declared duration bounds "available"). */
    object Platform : PassSource {
        override fun decode(path: String, startSeconds: Double, lengthSeconds: Double): PcmBuffer? =
            runCatching { AudioDecoder.decode(path, ANALYSIS_RATE, lengthSeconds, startSeconds) }.getOrNull()
                ?.takeIf { it.frames > 0 }

        override fun availableSeconds(path: String): Double = runCatching {
            val ex = android.media.MediaExtractor()
            try {
                ex.setDataSource(path)
                val idx = (0 until ex.trackCount).firstOrNull {
                    ex.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                } ?: return@runCatching 0.0
                val f = ex.getTrackFormat(idx)
                if (f.containsKey(android.media.MediaFormat.KEY_DURATION)) f.getLong(android.media.MediaFormat.KEY_DURATION) / 1_000_000.0 else 0.0
            } finally { ex.release() }
        }.getOrDefault(0.0)
    }

    /** BPM / key / loudness of one decoded window. */
    fun measure(
        pcm: PcmBuffer, kind: Kind, headOnly: Boolean, bpmSeconds: Double, keySeconds: Double, loudness: Boolean,
    ): Result {
        var bpm: Double? = null; var bpmC = 0.0; var cam: String? = null; var keyC = 0.0; var lufs: Double? = null
        BeatDetect.detectGridWithConfidence(pcm, bpmSeconds)?.let { bpm = it.grid.bpm; bpmC = it.confidence }
        KeyDetector.detect(pcm, keySeconds)?.let { cam = it.camelot; keyC = it.strength }
        if (loudness && pcm.frames > 0) {
            val m = Loudness.Meter(1, pcm.sampleRate.toDouble())
            m.processMonoSum(pcm.samples, pcm.frames, pcm.channels)
            lufs = m.integratedLoudness()
        }
        return Result(kind, headOnly, bpm, bpmC, cam, keyC, lufs)
    }

    /** The QUICK pass over [window]. */
    fun quickPass(src: PassSource, path: String, sliceStartSeconds: Double, window: Window): Result? {
        val pcm = src.decode(path, sliceStartSeconds + window.startSeconds, window.lengthSeconds) ?: return null
        return measure(pcm, Kind.quick, window.headOnly, window.lengthSeconds, window.lengthSeconds, loudness = true)
    }

    /**
     * The FULL pass: BPM over up to 120 s from the top, key over the song's middle minute; loudness is
     * `LoudnessCache`'s whole-song measurement, not repeated here.
     */
    fun fullPass(src: PassSource, path: String, sliceStartSeconds: Double, durationSeconds: Double): Result? {
        if (durationSeconds <= 2) return null
        var bpm: Double? = null; var bpmC = 0.0; var cam: String? = null; var keyC = 0.0
        src.decode(path, sliceStartSeconds, min(120.0, durationSeconds))?.let { pcm ->
            BeatDetect.detectGridWithConfidence(pcm, 120.0)?.let { bpm = it.grid.bpm; bpmC = it.confidence }
        }
        val keyLen = min(60.0, durationSeconds)
        src.decode(path, sliceStartSeconds + max(0.0, (durationSeconds - keyLen) / 2), keyLen)?.let { pcm ->
            KeyDetector.detect(pcm, keyLen)?.let { cam = it.camelot; keyC = it.strength }
        }
        return Result(Kind.full, false, bpm, bpmC, cam, keyC, null)
    }
}
