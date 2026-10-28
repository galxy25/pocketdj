package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MeterSource
import kotlinx.coroutines.delay

/** VU poll period (iOS 20 Hz). */
const val VU_POLL_MS = 50L

/**
 * Per-deck VU: blue→gold→pink zone gradient (RMS fill) with a fast peak marker on a -48…+3 dBFS scale.
 * Polls the engine's non-observable level mirror at 20 Hz, so it never recomposes the deck. Long-press
 * (or right-click) switches PRE/POST fader.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DeckVuMeter(engine: MixEngine, deck: Deck, modifier: Modifier = Modifier) {
    val ui by engine.ui.collectAsState()
    val source = ui.meterSource(deck)
    var tick by remember { mutableLongStateOf(0L) }
    LaunchedEffect(deck, engine) { while (true) { tick = System.nanoTime(); delay(VU_POLL_MS) } }
    var menu by remember { mutableStateOf(false) }

    val lv = engine.levels(deck)
    val live = DeckControlMath.vuLive(lv.updatedAtNanos, if (tick == 0L) System.nanoTime() else tick)
    val pre = source == MeterSource.PRE
    val peak = if (live) (if (pre) lv.prePeak else lv.postPeak) else 0f
    val rms = if (live) (if (pre) lv.preRms else lv.postRms) else 0f
    val peakDb = DeckControlMath.amplitudeDb(peak)
    val hot = DeckControlMath.vuHot(peakDb)

    val a11y = "deck-${deck.label}"
    Column(
        modifier
            .fillMaxWidth()
            .combinedClickable(onClick = {}, onLongClick = { menu = true })
            .testTag("$a11y-vu")
            .semantics { contentDescription = "Level meter, ${if (pre) "pre" else "post"} fader" },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("VU", fontSize = 12.sp, color = DeckColors.dim)
            Text(if (pre) "PRE" else "POST", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = DeckColors.accent)
            Row(Modifier.weight(1f)) {}
            Text(
                DeckControlMath.peakDbLabel(peakDb), fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                color = if (hot) DeckColors.danger else DeckColors.dim, maxLines = 1,
            )
        }
        val gradient = remember {
            Brush.horizontalGradient(
                0f to DeckColors.accent,
                DeckControlMath.VU_BLUE_END to DeckColors.accent,
                DeckControlMath.VU_GOLD_START to DeckColors.gold,
                DeckControlMath.VU_GOLD_END to DeckColors.gold,
                DeckControlMath.VU_PINK_START to DeckColors.danger,
                1f to DeckColors.danger,
            )
        }
        Canvas(Modifier.fillMaxWidth().height(10.dp)) {
            val w = size.width
            val h = size.height
            drawRoundRect(DeckColors.overlay, size = size, cornerRadius = CornerRadius(h / 2))
            val fill = DeckControlMath.vuFillWidth(DeckControlMath.vuNorm(rms) * w)
            if (fill > 0f) {
                drawRoundRect(gradient, size = Size(fill, h), cornerRadius = CornerRadius(h / 2))
            }
            if (peak > 0.001f) {
                val px = DeckControlMath.vuNorm(peak) * w
                drawRoundRect(
                    if (hot) DeckColors.danger else DeckColors.fg,
                    topLeft = Offset((px - 1.25.dp.toPx()).coerceIn(0f, w - 2.5.dp.toPx()), 0f),
                    size = Size(2.5.dp.toPx(), h), cornerRadius = CornerRadius(1.dp.toPx()),
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text((if (pre) "● " else "○ ") + "Pre-fader") },
                onClick = { engine.setMeterSource(MeterSource.PRE, deck); menu = false },
                modifier = Modifier.testTag("$a11y-vu-pre"),
            )
            DropdownMenuItem(
                text = { Text((if (!pre) "● " else "○ ") + "Post-fader") },
                onClick = { engine.setMeterSource(MeterSource.POST, deck); menu = false },
                modifier = Modifier.testTag("$a11y-vu-post"),
            )
        }
    }
}
