package com.levi.pocketdj.screens.producer.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.audio.core.PcmBuffer
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Pure waveform helpers (JVM-tested). */
object WaveformMath {
    /** [buckets] peak magnitudes (0..1, normalised to the loudest bucket) across the whole buffer. */
    fun peaks(pcm: PcmBuffer, buckets: Int): FloatArray {
        val n = max(1, buckets)
        val out = FloatArray(n)
        val frames = pcm.frames
        if (frames <= 0) return out
        val ch = pcm.channels
        for (b in 0 until n) {
            val from = (b.toLong() * frames / n).toInt()
            val to = max(from + 1, ((b + 1).toLong() * frames / n).toInt()).coerceAtMost(frames)
            var p = 0f
            for (f in from until to) for (c in 0 until ch) { val a = abs(pcm.samples[f * ch + c]); if (a > p) p = a }
            out[b] = p
        }
        val top = out.max()
        if (top > 0f) for (i in out.indices) out[i] = out[i] / top
        return out
    }

    /** Fraction (0..1) of x within width, clamped. */
    fun fraction(x: Float, width: Float): Float = if (width <= 0f) 0f else (x / width).coerceIn(0f, 1f)

    /** Which handle a touch at [x] grabs: the nearer of start/end, `null` when neither is within [slop]. */
    fun grab(x: Float, startX: Float, endX: Float, slop: Float): Handle? {
        val ds = abs(x - startX); val de = abs(x - endX)
        return when {
            ds > slop && de > slop -> null
            ds <= de -> Handle.Start
            else -> Handle.End
        }
    }

    enum class Handle { Start, End }
}

/**
 * Peaks strip with an optional shaded region (trim / in-out), draggable handles and a playhead. Taps seek.
 * All positions are fractions 0..1 of the whole waveform.
 */
@Composable
fun WaveformView(
    peaks: FloatArray,
    modifier: Modifier = Modifier,
    regionStart: Float? = null,
    regionEnd: Float? = null,
    playhead: Float? = null,
    onSeek: ((Float) -> Unit)? = null,
    onRegionChange: ((start: Float, end: Float) -> Unit)? = null,
    description: String = "Waveform",
) {
    val wave = MaterialTheme.colorScheme.primary
    val dim = MaterialTheme.colorScheme.outline
    val shade = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
    val head = MaterialTheme.colorScheme.tertiary
    val rs by rememberUpdatedState(regionStart)
    val re by rememberUpdatedState(regionEnd)
    val seek by rememberUpdatedState(onSeek)
    val change by rememberUpdatedState(onRegionChange)
    var grabbed = remember { arrayOfNulls<WaveformMath.Handle>(1) }
    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(96.dp)
            .semantics { contentDescription = description }
            .pointerInput(Unit) {
                detectTapGestures { o -> seek?.invoke(WaveformMath.fraction(o.x, size.width.toFloat())) }
            }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { o ->
                        val s = rs; val e = re
                        grabbed[0] = if (s != null && e != null && change != null)
                            WaveformMath.grab(o.x, s * size.width, e * size.width, 28.dp.toPx()) else null
                    },
                    onDragEnd = { grabbed[0] = null },
                    onDragCancel = { grabbed[0] = null },
                ) { change0, _ ->
                    val s = rs ?: return@detectDragGestures
                    val e = re ?: return@detectDragGestures
                    val f = WaveformMath.fraction(change0.position.x, size.width.toFloat())
                    when (grabbed[0]) {
                        WaveformMath.Handle.Start -> change?.invoke(min(f, e), e)
                        WaveformMath.Handle.End -> change?.invoke(s, max(f, s))
                        null -> seek?.invoke(f)
                    }
                    change0.consume()
                }
            },
    ) {
        val w = size.width; val h = size.height; val mid = h / 2
        val n = peaks.size
        if (n > 0) {
            val bar = w / n
            for (i in 0 until n) {
                val x = (i + 0.5f) * bar
                val amp = max(1f, peaks[i] * (h * 0.46f))
                val inside = rs == null || re == null || (x / w >= rs!! && x / w <= re!!)
                drawLine(if (inside) wave else dim, Offset(x, mid - amp), Offset(x, mid + amp), strokeWidth = max(1f, bar * 0.7f), cap = StrokeCap.Round)
            }
        } else {
            drawLine(dim, Offset(0f, mid), Offset(w, mid), strokeWidth = 2f)
        }
        val s = rs; val e = re
        if (s != null && e != null) {
            drawRect(shade, Offset(s * w, 0f), Size(max(0f, (e - s) * w), h))
            for (x in listOf(s * w, e * w)) drawLine(wave, Offset(x, 0f), Offset(x, h), strokeWidth = 3.dp.toPx())
        }
        playhead?.let { p -> drawLine(head, Offset(p * w, 0f), Offset(p * w, h), strokeWidth = 2.dp.toPx()) }
    }
}
