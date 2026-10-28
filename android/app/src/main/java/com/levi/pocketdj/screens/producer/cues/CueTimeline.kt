package com.levi.pocketdj.screens.producer.cues

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.screens.mix.CueSlotColors
import com.levi.pocketdj.studio.cues.CueSeek
import com.levi.pocketdj.studio.model.StudioCue

/** What fills the timeline behind the markers. */
sealed interface CueWave {
    /** Locally extracted peaks (burned files); empty = flat baseline while extracting. */
    data class Peaks(val peaks: FloatArray) : CueWave
    /** A digital per-song PNG, as-is. */
    data class Png(val url: String) : CueWave
    /** The analog album-side PNG cropped to this song's window (fractions of the PNG width). */
    data class CroppedPng(val url: String, val crop: CueSeek.Crop) : CueWave
}

/**
 * The waveform strip with slot-colored cue markers and a live playhead. A tap [onSeekTo]s that position (the
 * screen decides whether that auditions or only moves the scrub target).
 */
@Composable
fun CueTimeline(
    wave: CueWave,
    durationMs: Int,
    cues: List<StudioCue>,
    playheadMs: Int?,
    modifier: Modifier = Modifier,
    onTap: ((Int) -> Unit)? = null,
) {
    val bar = MaterialTheme.colorScheme.primary
    val head = MaterialTheme.colorScheme.tertiary
    val bg = MaterialTheme.colorScheme.surfaceVariant
    BoxWithConstraints(
        modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(6.dp)).background(bg)
            .semantics { contentDescription = "Cue timeline" }
            .pointerInput(durationMs) {
                detectTapGestures { o -> onTap?.invoke(CueSeek.positionAt(o.x / size.width.coerceAtLeast(1), durationMs)) }
            },
    ) {
        val w = maxWidth
        when (wave) {
            is CueWave.Peaks -> Canvas(Modifier.fillMaxSize()) {
                val mid = size.height / 2
                if (wave.peaks.isEmpty()) drawLine(bar.copy(alpha = 0.3f), Offset(0f, mid), Offset(size.width, mid), 2f)
                else {
                    val bw = size.width / wave.peaks.size
                    wave.peaks.forEachIndexed { i, p ->
                        val h = maxOf(1f, p.coerceIn(0f, 1f) * size.height * 0.92f)
                        drawLine(bar, Offset((i + 0.5f) * bw, mid - h / 2), Offset((i + 0.5f) * bw, mid + h / 2), maxOf(1f, bw * 0.7f))
                    }
                }
            }
            is CueWave.Png -> AsyncImage(wave.url, null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
            is CueWave.CroppedPng -> {
                // The PNG spans the whole album side: widen it to w / widthFraction and slide the window into view.
                val frac = wave.crop.width.coerceIn(0.001f, 1f)
                val full = w / frac
                AsyncImage(
                    wave.url, null,
                    Modifier.requiredWidth(full).fillMaxSize().offset(x = -(full * wave.crop.start) + (full - w) / 2),
                    contentScale = ContentScale.FillBounds,
                )
            }
        }
        Canvas(Modifier.fillMaxSize()) {
            cues.forEach { c ->
                val x = CueSeek.fraction(c.positionMs, durationMs) * (size.width - 2f)
                val col = Color(CueSlotColors.argb(c.slot))
                drawLine(col, Offset(x + 1f, 0f), Offset(x + 1f, size.height), 2.dp.toPx())
                drawCircle(col, 3.dp.toPx(), Offset(x + 1f, 3.dp.toPx()))
            }
            playheadMs?.let { p ->
                val x = CueSeek.fraction(p, durationMs) * size.width
                drawLine(head, Offset(x, 0f), Offset(x, size.height), 2.dp.toPx())
            }
        }
    }
}
