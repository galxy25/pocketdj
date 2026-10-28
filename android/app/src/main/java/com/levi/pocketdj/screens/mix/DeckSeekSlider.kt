package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.delay

/** How often the seek slider re-reads the engine's playhead (iOS ~10 Hz). */
const val SEEK_POLL_MS = 100L

/**
 * The per-deck scrubber. A SEPARATE composable so the 10 Hz playhead re-reads only this slider, never
 * the deck. The drag fraction is gesture-scoped: it is cleared in a `finally`, so the instant a gesture
 * ends (lift, cancel, exception) the display follows the live playhead again. There is no flag that
 * can be stranded.
 */
@Composable
fun DeckSeekSlider(engine: MixEngine, deck: Deck, modifier: Modifier = Modifier) {
    var position by remember(deck) { mutableDoubleStateOf(engine.position(deck)) }
    var duration by remember(deck) { mutableDoubleStateOf(engine.duration(deck)) }
    var drag by remember(deck) { mutableStateOf<Double?>(null) }
    var widthPx by remember { mutableStateOf(0f) }

    LaunchedEffect(deck, engine) {
        while (true) {
            position = engine.position(deck)
            duration = engine.duration(deck)
            delay(SEEK_POLL_MS)
        }
    }

    val dur = duration
    val shown = DeckControlMath.shownFraction(drag, position, dur)
    val shownSeconds = shown * dur
    val density = LocalDensity.current
    Column(modifier.fillMaxWidth()) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(28.dp)
                .alpha(if (dur > 0) 1f else 0.4f)
                .testTag("deck-${deck.label}-seek")
                .semantics {
                    contentDescription = "Playback position"
                    stateDescription = DeckControlMath.clock(shownSeconds)
                    if (dur > 0) customActions = listOf(
                        CustomAccessibilityAction("Forward") {
                            engine.seek(deck, (engine.position(deck) + DeckControlMath.seekStep(dur)).coerceAtMost(dur)); position = engine.position(deck); true
                        },
                        CustomAccessibilityAction("Back") {
                            engine.seek(deck, (engine.position(deck) - DeckControlMath.seekStep(dur)).coerceAtLeast(0.0)); position = engine.position(deck); true
                        },
                    )
                }
                .onSizeChanged { widthPx = it.width.toFloat() }
                .pointerInput(deck, dur > 0) {
                    if (dur <= 0) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        var last = DeckControlMath.fractionAt(down.position.x, size.width.toFloat())
                        try {
                            drag = last
                            while (true) {
                                val ev = awaitPointerEvent(PointerEventPass.Main)
                                val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                                last = DeckControlMath.fractionAt(c.position.x, size.width.toFloat())
                                drag = last
                                c.consume()
                                if (!c.pressed) {
                                    engine.seek(deck, last * engine.duration(deck))
                                    position = engine.position(deck)
                                    duration = engine.duration(deck)
                                    break
                                }
                            }
                        } finally {
                            position = engine.position(deck)
                            duration = engine.duration(deck)
                            drag = null
                        }
                    }
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            Box(Modifier.fillMaxWidth().height(4.dp).background(DeckColors.border, CircleShape))
            val activeW = with(density) { (widthPx * shown.toFloat()).coerceAtLeast(0f).toDp() }
            Box(Modifier.width(activeW).height(4.dp).background(DeckColors.gold, CircleShape))
            val thumbX = with(density) { (widthPx * shown.toFloat() - 8.dp.toPx()).coerceIn(0f, (widthPx - 16.dp.toPx()).coerceAtLeast(0f)).toDp() }
            Box(Modifier.offset(x = thumbX).size(16.dp).background(DeckColors.gold, CircleShape))
        }
        Row(Modifier.fillMaxWidth()) {
            Text(DeckControlMath.clock(shownSeconds), fontSize = 11.sp, color = DeckColors.dim, fontFamily = FontFamily.Monospace)
            Box(Modifier.weight(1f))
            Text(DeckControlMath.clock(dur), fontSize = 11.sp, color = DeckColors.dim, fontFamily = FontFamily.Monospace)
        }
    }
}
