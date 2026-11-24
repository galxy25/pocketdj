package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.core.AudioDecoder
import com.levi.pocketdj.audio.dsp.Loudness
import com.levi.pocketdj.audio.dsp.LoudnessCancelFlag
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/** Streams decoded chunks of (a slice of) a file; returns false on cancel / no audio track. */
typealias ChunkDecoder = (
    path: String, startSeconds: Double, maxSeconds: Double, isCancelled: () -> Boolean,
    sink: (FloatArray, Int, Int, Int) -> Unit,
) -> Boolean

/** Decodes a local file in chunks and measures its BS.1770 integrated loudness (blocking; call off-main). */
object LoudnessAnalyzer {
    private val platformDecoder: ChunkDecoder = { p, s, m, c, sink -> AudioDecoder.decodeChunks(p, s, m, c, sink) }

    /**
     * Measures [path] (or just [segment]). [monoSum] averages channels into ONE K-weighting chain
     * (about half the cost; same relative leveling). Returns null when unmeasurable (silence / too short).
     * Throws [CancellationException] when [cancel] fires, [IOException] when the file can't be decoded.
     */
    fun analyzeSync(
        path: String,
        segment: LoudnessSegment? = null,
        monoSum: Boolean = true,
        cancel: LoudnessCancelFlag? = null,
        decoder: ChunkDecoder = platformDecoder,
    ): Double? {
        var meter: Loudness.Meter? = null
        val start = (segment?.startMs ?: 0) / 1000.0
        val len = (segment?.lengthMs ?: 0).coerceAtLeast(0) / 1000.0
        val ok = decoder(path, start, len, { cancel?.isCancelled == true }) { s, frames, ch, sr ->
            val m = meter ?: Loudness.Meter(if (monoSum) 1 else ch, sr.toDouble()).also { meter = it }
            if (monoSum) m.processMonoSum(s, frames, ch) else m.processInterleaved(s, frames)
        }
        if (cancel?.isCancelled == true) throw CancellationException("loudness analysis cancelled")
        if (!ok) throw IOException("no decodable audio: $path")
        return meter?.integratedLoudness()
    }
}
