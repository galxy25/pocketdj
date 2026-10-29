package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.MaterialTheme
import kotlin.math.roundToInt

/** Pure keyboard geometry + naming (JVM-testable; the composable only draws and forwards touches). */
object PianoLayout {
    private val BLACK = setOf(1, 3, 6, 8, 10)
    private val NAMES = arrayOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")

    /** Black keys span this fraction of the white-key width and of the keyboard height. */
    const val BLACK_WIDTH_FRACTION = 0.6f
    const val BLACK_HEIGHT_FRACTION = 0.62f

    fun isBlack(note: Int): Boolean = (((note % 12) + 12) % 12) in BLACK

    /** MIDI 60 = "C4". */
    fun name(note: Int): String = NAMES[((note % 12) + 12) % 12] + (Math.floorDiv(note, 12) - 1)

    /** The white notes in [first]..[last] inclusive, low to high. */
    fun whiteKeys(first: Int, last: Int): List<Int> = (first..last).filter { !isBlack(it) }

    fun whiteWidth(totalWidth: Float, first: Int, last: Int): Float = totalWidth / whiteKeys(first, last).size.coerceAtLeast(1)

    /** Left edge x of a white key (index into [whiteKeys]) / the left edge of a black key (centered on the white-key boundary). */
    fun blackLeft(note: Int, first: Int, last: Int, totalWidth: Float): Float {
        val w = whiteWidth(totalWidth, first, last)
        val whitesBelow = whiteKeys(first, note).size          // the black key sits on the boundary after the white below it
        return whitesBelow * w - w * BLACK_WIDTH_FRACTION / 2
    }

    /** The note under (x, y), black keys first (they overlay the top of the whites); null outside the board. */
    fun keyAt(x: Float, y: Float, width: Float, height: Float, first: Int, last: Int): Int? {
        if (x < 0 || y < 0 || x >= width || y >= height || width <= 0 || height <= 0) return null
        val w = whiteWidth(width, first, last)
        if (y < height * BLACK_HEIGHT_FRACTION) {
            for (n in first..last) {
                if (!isBlack(n)) continue
                val l = blackLeft(n, first, last, width)
                if (x >= l && x < l + w * BLACK_WIDTH_FRACTION) return n
            }
        }
        val whites = whiteKeys(first, last)
        return whites.getOrNull((x / w).toInt().coerceAtMost(whites.size - 1))
    }

    /** Harder further down the key (a touch screen's only expressive axis): 48..127. */
    fun velocity(y: Float, height: Float): Int {
        if (height <= 0) return 96
        return (48 + (y / height).coerceIn(0f, 1f) * 79).roundToInt().coerceIn(1, 127)
    }

    /** Clamp a requested range to the 0..127 MIDI domain, ending on a white key so the board has no dangling black key. */
    fun clampRange(first: Int, last: Int): Pair<Int, Int> {
        val f = first.coerceIn(0, 120)
        var l = last.coerceIn(f + 1, 127)
        while (isBlack(l) && l > f) l--
        return f to l
    }
}

/**
 * On-screen keys. Multi-touch: each pointer tracks the key it is on; sliding off a key releases it and strikes the
 * new one (a glissando). Callbacks run on the touch thread and go straight to the native synth.
 */
@Composable
fun PianoKeyboard(
    first: Int,
    last: Int,
    pressed: Set<Int>,
    onNoteOn: (note: Int, velocity: Int) -> Unit,
    onNoteOff: (note: Int) -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 180.dp,
) {
    val on = rememberUpdatedState(onNoteOn)
    val off = rememberUpdatedState(onNoteOff)
    // Real piano colours (iOS PianoKeyboardView: white keys .white, black keys .black), NOT
    // theme surface/onSurface, which inverted them on the dark scheme.
    val white = Color(0xFFF4F5F8)
    val whiteDown = MaterialTheme.colorScheme.primary.copy(alpha = 0.55f).compositeOver(white)
    val black = Color(0xFF111318)
    val blackDown = MaterialTheme.colorScheme.primary
    val edge = Color(0xFF8A90A0)
    Canvas(
        modifier.fillMaxWidth().height(height).testTag("piano-keyboard")
            .pointerInput(first, last) {
                val down = HashMap<PointerId, Int>()
                awaitPointerEventScope {
                    while (true) {
                        val ev = awaitPointerEvent()
                        for (c in ev.changes) {
                            val w = size.width.toFloat(); val h = size.height.toFloat()
                            val key = if (c.pressed) PianoLayout.keyAt(c.position.x, c.position.y, w, h, first, last) else null
                            val prev = down[c.id]
                            if (prev != key) {
                                if (prev != null) { off.value(prev); down.remove(c.id) }
                                if (key != null) { down[c.id] = key; on.value(key, PianoLayout.velocity(c.position.y, h)) }
                            }
                            if (c.pressed != c.previousPressed || c.positionChanged()) c.consume()
                        }
                    }
                }
            },
    ) {
        val whites = PianoLayout.whiteKeys(first, last)
        val w = size.width / whites.size.coerceAtLeast(1)
        whites.forEachIndexed { i, n ->
            drawRect(if (n in pressed) whiteDown else white, Offset(i * w, 0f), Size(w, size.height))
            drawRect(edge, Offset(i * w, 0f), Size(w, size.height), style = androidx.compose.ui.graphics.drawscope.Stroke(1f))
        }
        for (n in first..last) {
            if (!PianoLayout.isBlack(n)) continue
            val l = PianoLayout.blackLeft(n, first, last, size.width)
            drawRoundRect(
                if (n in pressed) blackDown else black, Offset(l, 0f),
                Size(w * PianoLayout.BLACK_WIDTH_FRACTION, size.height * PianoLayout.BLACK_HEIGHT_FRACTION), CornerRadius(4f, 4f),
            )
        }
    }
}

private fun androidx.compose.ui.input.pointer.PointerInputChange.positionChanged(): Boolean = position != previousPosition
