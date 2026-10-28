package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Pure loop-region geometry in TIMELINE coordinates (dp = ms/1000 * pxPerSec), shared with the tests. */
object LoopRegionMath {
    const val MIN_LENGTH_MS = 250

    fun msToDp(ms: Int, pxPerSec: Float): Float = ms / 1000f * pxPerSec
    fun dpToMs(dp: Float, pxPerSec: Float): Int = if (pxPerSec <= 0f) 0 else (dp / pxPerSec * 1000f).roundToInt()

    /** Snap [ms] to the nearest beat of [bpm] when [snap]. */
    fun snap(ms: Int, bpm: Double, snap: Boolean): Int {
        if (!snap || bpm <= 0) return ms
        val beat = 60_000.0 / bpm
        return max(0, (Math.rint(ms / beat) * beat).toInt())
    }

    /** New loop START after dragging its handle [dxDp]; stays >= 0 and at least MIN_LENGTH before the end. */
    fun dragStart(startMs: Int, endMs: Int, dxDp: Float, pxPerSec: Float, bpm: Double, snap: Boolean): Int {
        val raw = snap(startMs + dpToMs(dxDp, pxPerSec), bpm, snap)
        return raw.coerceIn(0, max(0, endMs - MIN_LENGTH_MS))
    }

    /** New loop END after dragging its handle [dxDp]; stays at least MIN_LENGTH past the start and within [lengthMs] (when > 0). */
    fun dragEnd(startMs: Int, endMs: Int, dxDp: Float, pxPerSec: Float, bpm: Double, snap: Boolean, lengthMs: Int): Int {
        val raw = snap(endMs + dpToMs(dxDp, pxPerSec), bpm, snap)
        val upper = if (lengthMs > 0) max(lengthMs, startMs + MIN_LENGTH_MS) else Int.MAX_VALUE
        return raw.coerceIn(startMs + MIN_LENGTH_MS, upper)
    }

    /** iOS default when Loop is first enabled with no usable region: 4 beats from 0:00, capped to the arrangement. */
    fun defaultRegion(lengthMs: Int, bpm: Double): Pair<Int, Int> {
        val fourBeats = if (bpm > 0) (60_000.0 / bpm * 4).toInt() else 2_000
        var end = if (lengthMs > 0) min(fourBeats, lengthMs) else fourBeats
        if (end <= 0) end = fourBeats
        return 0 to max(end, MIN_LENGTH_MS)
    }

    fun isUsable(startMs: Int, endMs: Int) = endMs - startMs >= MIN_LENGTH_MS
}

/**
 * The loop band + two draggable handles, laid out in the SAME coordinate space as the cursor overlay
 * (a child of the horizontally-scrolling timeline, so dp x = ms * pxPerSec). Drags report the new
 * region through [onChange]; handles always snap to the beat grid when bpm > 0 (iOS rule).
 */
@Composable
fun LoopRegionOverlay(
    startMs: Int, endMs: Int, pxPerSec: Float, bpm: Double, lengthMs: Int, laneCount: Int,
    onChange: (startMs: Int, endMs: Int) -> Unit, modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current.density
    val height = (RULER_HEIGHT + laneCount * LANE_HEIGHT + (laneCount - 1).coerceAtLeast(0) * LANE_GAP).dp
    val x0 = LoopRegionMath.msToDp(startMs, pxPerSec)
    val x1 = LoopRegionMath.msToDp(endMs, pxPerSec)
    val curStart by rememberUpdatedState(startMs)
    val curEnd by rememberUpdatedState(endMs)
    val curPx by rememberUpdatedState(pxPerSec)
    val curBpm by rememberUpdatedState(bpm)
    val curLen by rememberUpdatedState(lengthMs)
    var originStart by remember { mutableIntStateOf(startMs) }
    var originEnd by remember { mutableIntStateOf(endMs) }
    val accent = MaterialTheme.colorScheme.secondary
    Box(modifier.height(height).width((x1 + 24f).dp)) {
        Box(
            Modifier.offset(x = x0.dp).width((x1 - x0).coerceAtLeast(1f).dp).fillMaxHeight().background(accent).alpha(0.16f)
                .testTag("tracks-loop-band"),
        )
        // Drags are measured from where the gesture BEGAN (origin + accumulated dx), then snapped: per-event
        // deltas smaller than half a beat would otherwise round back to the same beat and the handle would never move.
        Handle(x0 - 10f, accent, "Loop start", "tracks-loop-start", onBegin = { originStart = curStart }) { totalPx ->
            onChange(LoopRegionMath.dragStart(originStart, curEnd, totalPx / density, curPx, curBpm, true), curEnd)
        }
        Handle(x1 - 10f, accent, "Loop end", "tracks-loop-end", onBegin = { originEnd = curEnd }) { totalPx ->
            onChange(curStart, LoopRegionMath.dragEnd(curStart, originEnd, totalPx / density, curPx, curBpm, true, curLen))
        }
    }
}

@Composable
private fun Handle(xDp: Float, color: androidx.compose.ui.graphics.Color, label: String, tag: String, onBegin: () -> Unit, onDrag: (Float) -> Unit) {
    Box(
        Modifier.offset(x = xDp.coerceAtLeast(0f).dp).width(20.dp).fillMaxHeight()
            .pointerInput(tag) {
                var total = 0f
                detectHorizontalDragGestures(onDragStart = { total = 0f; onBegin() }) { change, dx -> change.consume(); total += dx; onDrag(total) }
            }
            .semantics { contentDescription = label }.testTag(tag),
        contentAlignment = Alignment.TopCenter,
    ) { Box(Modifier.width(4.dp).fillMaxHeight().background(color)) }
}
