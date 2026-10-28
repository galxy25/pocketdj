package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.audio.core.Mp3Decoder
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.data.burns.BurnStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Compact deck waveform (≈200 normalized peaks) from a burned file, OFF the main thread. For an
 * ANALOG shared-album file the window `[startMs, startMs+lengthMs]` is used so the deck shows THIS
 * song's slice. Pure given a [PcmSource] + window: the fold is JVM-tested with a fake source.
 */
object WaveformExtractor {
    const val DEFAULT_PEAK_COUNT = 200
    private const val CHUNK_FRAMES = 16_384

    /**
     * Folds the window into [targetCount] absolute-peak buckets (max |sample| across channels),
     * normalised to 0…1 against the loudest bucket. Returns [] for an unreadable / empty / silent window.
     */
    fun fold(source: PcmSource, startMs: Int?, lengthMs: Int?, targetCount: Int = DEFAULT_PEAK_COUNT): FloatArray {
        val rate = source.sampleRate
        val total = source.totalFrames
        val ch = max(1, source.channels)
        if (targetCount <= 0 || rate <= 0 || total <= 0) return FloatArray(0)
        val startFrame = startMs?.let { (it / 1000.0 * rate).toLong() } ?: 0L
        val clampedStart = startFrame.coerceIn(0L, total)
        val window = if (lengthMs != null) {
            min((lengthMs / 1000.0 * rate).toLong(), total - clampedStart).coerceAtLeast(0L)
        } else total - clampedStart
        if (window <= 0) return FloatArray(0)
        source.seek(clampedStart)
        val perBucket = max(1L, window / targetCount)
        val peaks = FloatArray(targetCount)
        val buf = FloatArray(CHUNK_FRAMES * ch)
        var remaining = window
        var consumed = 0L
        var stalls = 0
        while (remaining > 0) {
            val want = min(remaining, CHUNK_FRAMES.toLong()).toInt()
            val got = source.read(buf, want)
            if (got < 0) break
            if (got == 0) { if (++stalls > 3) break else continue }
            stalls = 0
            for (i in 0 until got) {
                var amp = 0f
                for (c in 0 until ch) amp = max(amp, abs(buf[i * ch + c]))
                val bucket = min(targetCount - 1L, (consumed + i) / perBucket).toInt()
                if (amp > peaks[bucket]) peaks[bucket] = amp
            }
            consumed += got
            remaining -= got
        }
        val maxPeak = peaks.max()
        if (maxPeak <= 0f) return FloatArray(0)
        return FloatArray(targetCount) { peaks[it] / maxPeak }
    }

    suspend fun peaks(file: File, startMs: Int?, lengthMs: Int?, targetCount: Int = DEFAULT_PEAK_COUNT): FloatArray =
        withContext(Dispatchers.Default) {
            val d = runCatching { Mp3Decoder(file) }.getOrNull() ?: return@withContext FloatArray(0)
            try { fold(d, startMs, lengthMs, targetCount) } catch (_: Throwable) { FloatArray(0) } finally { runCatching { d.close() } }
        }
}

/** BurnStore-aware helper: prefers the per-song cut (the file the deck plays); windows only a shared-album file. */
object MixWaveform {
    suspend fun peaksForSong(songId: String, lengthMs: Int?, burns: BurnStore): FloatArray {
        val h = burns.localUrlPreferringCut(songId) ?: return FloatArray(0)
        val startMs = if (h.isCut) null else burns.startMs(songId)?.toInt()
        return WaveformExtractor.peaks(h.file, startMs, if (startMs != null) lengthMs else null)
    }
}

/** Center-mirrored bars; an EMPTY array renders a flat baseline placeholder. */
@Composable
fun MixWaveformView(peaks: FloatArray, modifier: Modifier = Modifier) {
    val bar = DeckColors.accent
    Canvas(
        modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(DeckColors.overlay),
    ) {
        if (peaks.isEmpty()) {
            drawLine(bar.copy(alpha = 0.25f), Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = 1f)
        } else {
            val bw = size.width / peaks.size
            val mid = size.height / 2
            peaks.forEachIndexed { i, p ->
                val h = max(1f, p.coerceIn(0f, 1f) * size.height)
                drawRect(bar, Offset(i * bw, mid - h / 2), Size(max(0.5f, bw - 0.5f), h))
            }
        }
    }
}
