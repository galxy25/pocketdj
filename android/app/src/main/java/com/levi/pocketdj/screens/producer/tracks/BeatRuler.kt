package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.studio.store.ArrangerMath

/**
 * The beat-number RULER above the lanes: bar numbers + beat ticks on the shared timeline grid (it scrolls
 * with the clips). A TAP seeks the cursor to that timeline position; a drag scrolls (never seeks).
 */
@Composable
fun BeatRuler(
    bpm: Double,
    pxPerSec: Float,
    lengthMs: Int,
    width: Float,
    onSeek: (ms: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val measurer = rememberTextMeasurer()
    val tick = MaterialTheme.colorScheme.onSurfaceVariant
    val label = MaterialTheme.colorScheme.onSurface
    val seek by rememberUpdatedState(onSeek)
    Box(
        modifier.width(width.dp).height(RULER_HEIGHT.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .semantics { contentDescription = "Beat ruler. Tap to move the cursor." }
            .testTag("tracks-ruler")
            .pointerInput(pxPerSec, lengthMs) {
                detectTapGestures { o -> seek(ArrangerMath.seekMsForX(o.x / density, pxPerSec, lengthMs)) }
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val ticks = ArrangerMath.beatTicks(bpm, pxPerSec, size.width / density)
            val numbers = ArrangerMath.showBarNumbers(bpm, pxPerSec)
            val h = size.height
            for (t in ticks) {
                val x = t.x * density
                val top = if (t.isBar) h * 0.35f else h * 0.62f
                drawLine(tick.copy(alpha = if (t.isBar) 0.7f else 0.3f), Offset(x, top), Offset(x, h), strokeWidth = if (t.isBar) 1.5f else 1f)
                if (t.isBar && numbers && t.barNumber != null && x <= size.width - 10 * density) {
                    drawText(measurer, t.barNumber.toString(), Offset(x + 3 * density, 1f), style = TextStyle(fontSize = 9.sp, color = label))
                }
            }
        }
    }
}

/** The subtle beat/bar grid drawn over the lanes (never intercepts input). */
@Composable
fun BeatGrid(bpm: Double, pxPerSec: Float, width: Float, modifier: Modifier = Modifier) {
    val line: Color = MaterialTheme.colorScheme.onSurface
    Canvas(modifier.width(width.dp)) {
        for (t in ArrangerMath.beatTicks(bpm, pxPerSec, size.width / density)) {
            val x = t.x * density
            drawLine(line.copy(alpha = if (t.isBar) 0.20f else 0.08f), Offset(x, 0f), Offset(x, size.height), strokeWidth = if (t.isBar) 1.5f else 1f)
        }
    }
}

const val RULER_HEIGHT = 24
