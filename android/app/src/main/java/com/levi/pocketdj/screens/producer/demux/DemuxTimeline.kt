package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.studio.demux.DemuxChordSegment
import com.levi.pocketdj.studio.demux.StemPlayer
import kotlinx.coroutines.delay
import kotlin.math.max
import kotlin.math.min

/** Pure timeline math (JVM-tested): zoom ladder + fit-to-width, scrub clamp, follow target from REAL layout widths. */
object DemuxTimelineMath {
    /** Points (dp) per second the zoom buttons walk. */
    val ZOOM_LADDER = floatArrayOf(4f, 10f, 25f, 60f)

    /** Px/s at which the whole track exactly fits [containerW]; the ladder floor before layout has a width. */
    fun fitPx(containerW: Float, durationMs: Int): Float {
        val seconds = max(durationMs / 1000.0, 0.01)
        return if (containerW > 0f) (containerW / seconds).toFloat() else ZOOM_LADDER.first()
    }

    /**
     * Walk the ladder; BELOW its floor land on fit-to-width so zoom-out always reaches "the whole track on
     * screen" even for a long song in portrait. Zooming back in from the fit stop returns to the ladder.
     */
    fun stepZoom(current: Float, dir: Int, fit: Float): Float =
        if (dir < 0) {
            val lower = ZOOM_LADDER.lastOrNull { it < current }
            if (lower != null && lower > fit) lower else fit
        } else {
            ZOOM_LADDER.firstOrNull { it > current } ?: ZOOM_LADDER.last()
        }

    /** The strip's laid-out width: never narrower than the container. */
    fun stripWidth(containerW: Float, durationMs: Int, pxPerSec: Float): Float =
        max(containerW, (max(durationMs / 1000.0, 0.01) * pxPerSec).toFloat())

    /** Effective px/s once the strip was widened to fill the container. */
    fun effectivePx(stripW: Float, durationMs: Int): Float = (stripW / max(durationMs / 1000.0, 0.01)).toFloat()

    fun clampMs(x: Float, pxPerSec: Float, durationMs: Int): Int =
        if (pxPerSec <= 0f) 0 else min(max(0, (x / pxPerSec * 1000f).toInt()), durationMs)

    /**
     * Scroll offset that centers the playhead's WHOLE second [sec] in a viewport [viewportW] wide. Computed
     * from the strip's real layout width (sec * effectivePx), never from a visual offset, so it lands the
     * same at every zoom (the iOS anchors-at-x=0 field bug).
     */
    fun followTarget(sec: Int, effectivePx: Float, viewportW: Float, stripW: Float): Int {
        val center = sec * effectivePx + effectivePx / 2f
        return (center - viewportW / 2f).coerceIn(0f, max(0f, stripW - viewportW)).toInt()
    }

    /** One hue per root pitch class around the wheel (minor dimmer) — harmony reads at a glance. */
    fun chordColor(seg: DemuxChordSegment): Color =
        Color.hsv(seg.rootPC.mod(12) * 30f, 0.55f, if (seg.minor) 0.42f else 0.62f)
}

private val WAVE_H = 44.dp
private val CHORD_H = 34.dp

@Composable
fun DemuxTimeline(
    durationMs: Int,
    peaks: FloatArray,
    chords: List<DemuxChordSegment>,
    player: StemPlayer,
    follow: Boolean,
    onFollowChange: (Boolean) -> Unit,
    onSeek: (Int) -> Unit,
    onChordTap: (DemuxChordSegment) -> Unit,
    onSave: (() -> Unit)? = null,
    saving: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    var pxPerSec by remember { mutableFloatStateOf(10f) }
    var nowMs by remember { mutableIntStateOf(0) }
    var scrubMs by remember { mutableStateOf<Int?>(null) }
    var centerNonce by remember { mutableIntStateOf(0) }
    var containerPx by remember { mutableFloatStateOf(0f) }
    val scroll = rememberScrollState()

    LaunchedEffect(player) { while (true) { nowMs = (player.currentTimeSec * 1000).toInt(); delay(250) } }

    Column(modifier.fillMaxWidth().onSizeChanged { containerPx = it.width.toFloat() }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().height(WAVE_H + CHORD_H + 18.dp)) {
            val stripPx = DemuxTimelineMath.stripWidth(containerPx, durationMs, with(density) { pxPerSec.dp.toPx() })
            val effPx = DemuxTimelineMath.effectivePx(stripPx, durationMs)
            val stripDp = with(density) { stripPx.toDp() }

            fun scrollToSecond(sec: Int) = DemuxTimelineMath.followTarget(sec, effPx, containerPx, stripPx)

            // Zoom anchors at the PLAYHEAD: after the strip re-laid out at its new width, re-center the current second.
            LaunchedEffect(pxPerSec) { delay(16); scroll.scrollTo(scrollToSecond((player.currentTimeSec).toInt())) }
            LaunchedEffect(centerNonce) { if (centerNonce > 0) scroll.animateScrollTo(scrollToSecond(player.currentTimeSec.toInt())) }
            // Auto-follow polls (currentTime is not observable); NO isPlaying gate so a paused scrub recenters too.
            LaunchedEffect(follow, pxPerSec, containerPx) {
                var last = -1
                while (follow) {
                    val sec = player.currentTimeSec.toInt()
                    if (sec != last) { last = sec; scroll.animateScrollTo(scrollToSecond(sec)) }
                    delay(500)
                }
            }

            Box(Modifier.horizontalScroll(scroll).width(stripDp).testTag("demux-timeline")) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    WaveformLane(peaks, stripDp, Modifier.pointerInput(effPx, durationMs) {
                        // Drag anywhere on the waveform = scrub (preview while down, seek on release); a tap seeks too.
                        detectTapGestures { o -> onFollowChange(false); onSeek(DemuxTimelineMath.clampMs(o.x, effPx, durationMs)) }
                    }.pointerInput(effPx, durationMs) {
                        detectDragGestures(
                            onDragStart = { o -> scrubMs = DemuxTimelineMath.clampMs(o.x, effPx, durationMs) },
                            onDrag = { c, _ -> scrubMs = DemuxTimelineMath.clampMs(c.position.x, effPx, durationMs) },
                            onDragEnd = { scrubMs?.let { onFollowChange(false); onSeek(it) }; scrubMs = null },
                            onDragCancel = { scrubMs = null },
                        )
                    })
                    ChordLane(chords, stripDp, effPx / density.density, onChordTap)
                }
                val head = scrubMs ?: nowMs
                Box(
                    Modifier.offset { androidx.compose.ui.unit.IntOffset((head / 1000f * effPx - 1f).toInt(), 0) }
                        .width(2.dp).height(WAVE_H + CHORD_H + 2.dp).background(MaterialTheme.colorScheme.tertiary)
                        .testTag("demux-playhead"),
                )
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Zoom", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            val fitPx = DemuxTimelineMath.fitPx(containerPx, durationMs) / density.density
            IconButton(
                onClick = { pxPerSec = DemuxTimelineMath.stepZoom(pxPerSec, -1, fitPx) },
                enabled = pxPerSec > fitPx + 0.01f,
                modifier = Modifier.testTag("demux-zoom-out"),
            ) { Icon(Icons.Filled.ZoomOut, "Zoom out") }
            IconButton(
                onClick = { pxPerSec = DemuxTimelineMath.stepZoom(pxPerSec, +1, fitPx) },
                enabled = pxPerSec < DemuxTimelineMath.ZOOM_LADDER.last(),
                modifier = Modifier.testTag("demux-zoom-in"),
            ) { Icon(Icons.Filled.ZoomIn, "Zoom in") }
            Box(Modifier.weight(1f))
            if (onSave != null) IconButton(onClick = onSave, enabled = !saving, modifier = Modifier.testTag("demux-save")) {
                if (saving) androidx.compose.material3.CircularProgressIndicator(Modifier.width(18.dp).height(18.dp), strokeWidth = 2.dp)
                else Icon(Icons.Filled.IosShare, "Save to Pocket DJ library")
            }
            IconButton(
                onClick = { onFollowChange(true); centerNonce++ },
                modifier = Modifier.clip(RoundedCornerShape(50)).background(if (follow) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant).testTag("demux-follow"),
            ) { Icon(Icons.Filled.MyLocation, "Jump to the playhead and follow it", tint = if (follow) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun WaveformLane(peaks: FloatArray, width: Dp, modifier: Modifier) {
    val bar = MaterialTheme.colorScheme.primary.copy(alpha = 0.55f)
    val base = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    Canvas(modifier.width(width).height(WAVE_H).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
        val mid = size.height / 2
        if (peaks.isEmpty()) { drawLine(base, Offset(0f, mid), Offset(size.width, mid), 1f); return@Canvas }
        val bw = size.width / peaks.size
        for (i in peaks.indices) {
            val h = max(1.5f, peaks[i].coerceIn(0f, 1f) * size.height)
            drawRoundRect(bar, Offset(i * bw, mid - h / 2), Size(max(bw - 1f, 0.8f), h), CornerRadius(1f))
        }
    }
}

@Composable
private fun ChordLane(chords: List<DemuxChordSegment>, width: Dp, dpPerSec: Float, onTap: (DemuxChordSegment) -> Unit) {
    Box(Modifier.width(width).height(CHORD_H).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
        for (seg in chords) {
            val x = seg.startMs / 1000f * dpPerSec
            val w = max((seg.endMs - seg.startMs) / 1000f * dpPerSec - 1f, 2f)
            Box(
                Modifier.offset(x.dp, 3.dp).width(w.dp).height(CHORD_H - 6.dp)
                    .clip(RoundedCornerShape(4.dp)).background(DemuxTimelineMath.chordColor(seg))
                    .clickable { onTap(seg) }
                    .semantics { contentDescription = "${seg.name}, ${clock(seg.startMs)}" }
                    .testTag("demux-chord-${seg.startMs}"),
                contentAlignment = Alignment.Center,
            ) {
                if (w > 16f) Text(seg.name, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Clip, color = Color.White)
            }
        }
    }
}
