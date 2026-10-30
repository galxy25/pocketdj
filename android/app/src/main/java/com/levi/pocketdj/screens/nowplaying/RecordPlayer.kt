package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.ui.theme.PdjAccent
import com.levi.pocketdj.ui.theme.PdjOnAccent
import com.levi.pocketdj.ui.theme.PdjBackground
import com.levi.pocketdj.ui.theme.PdjSurfaceVariant
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer

private val Gold = Color(0xFFE0B341)
private val GoldDark = Color(0xFF8A6A12)

/**
 * Gold record on the accent chassis. [spinning] drives the platter at the beat-grid BPM; the
 * angle lives in a remembered accumulator so a pause freezes it in place and resume continues
 * from the same angle. [progress] (0..1, 1 Hz) sweeps the tonearm outer edge -> center.
 */
@Composable
fun RecordPlayer(
    spinning: Boolean,
    bpm: Double?,
    progress: Double?,
    modifier: Modifier = Modifier,
    /** The current track's album: its cover is the record's centre label (iOS RecordPlayerView). */
    album: com.levi.pocketdj.data.catalog.IndexAlbum? = null,
    /** False when nothing is loaded: the tonearm parks OFF the record. */
    hasTrack: Boolean = true,
) {
    var angle by androidx.compose.runtime.saveable.rememberSaveable { mutableFloatStateOf(0f) }
    val spinningNow by rememberUpdatedState(spinning)
    val bpmNow by rememberUpdatedState(bpm)
    LaunchedEffect(spinning) {
        if (!spinning) return@LaunchedEffect
        var last = withFrameNanosCompat()
        while (true) {
            val now = withFrameNanosCompat()
            val dt = (now - last) / 1_000_000_000.0
            last = now
            angle = RecordMath.advance(angle.toDouble(), dt, spinningNow, bpmNow).toFloat()
        }
    }
    val arm = (if (hasTrack) RecordMath.tonearmAngle(progress) else RecordMath.TONEARM_PARKED_DEG).toFloat()
    androidx.compose.foundation.layout.BoxWithConstraints(
        modifier.fillMaxWidth().aspectRatio(1f).padding(8.dp).testTag("np-record"),
    ) {
        val side = if (maxWidth < maxHeight) maxWidth else maxHeight
        Canvas(Modifier.matchParentSize()) {
            val s = size.minDimension
            // Chassis: iOS RecordPlayerView = Theme.bgRaised fill + a 2 pt accent outline (not a
            // solid accent slab, which read as a flat bright-blue square on the navy UI).
            val corner = CornerRadius(s * 0.06f)
            drawRoundRect(PdjSurfaceVariant, size = Size(s, s), cornerRadius = corner)
            drawRoundRect(PdjAccent, size = Size(s, s), cornerRadius = corner, style = Stroke(2.dp.toPx()))
            val center = Offset(size.width / 2f, size.height / 2f)
            val r = s * 0.42f
            rotate(angle, center) {
                drawCircle(
                    Brush.radialGradient(listOf(Gold, GoldDark), center, r),
                    radius = r, center = center,
                )
                var g = r * 0.38f
                while (g < r * 0.96f) {
                    drawCircle(Color(0x33000000), radius = g, center = center, style = Stroke(1.dp.toPx()))
                    g += r * 0.07f
                }
                drawCircle(PdjOnAccent, radius = r * 0.30f, center = center)
                // Label marker: makes rotation visible.
                drawCircle(Gold, radius = r * 0.05f, center = center + Offset(r * 0.18f, 0f))
                drawCircle(Color.White, radius = r * 0.03f, center = center)
            }
        }
        // Centre label = the album cover, rotating with the platter.
        if (album != null) {
            Box(
                Modifier
                    .align(androidx.compose.ui.Alignment.Center)
                    .size(side * (RecordMath.LABEL_RADIUS * 2).toFloat())
                    .graphicsLayer { rotationZ = angle }
                    .clip(androidx.compose.foundation.shape.CircleShape),
            ) {
                com.levi.pocketdj.screens.browse.AlbumArt(album, Modifier.matchParentSize(), cornerRadius = 0)
            }
        }
        Canvas(Modifier.matchParentSize()) {
            val s = size.minDimension
            val center = Offset(size.width / 2f, size.height / 2f)
            if (album != null) drawCircle(PdjBackground, radius = s * 0.42f * 0.03f + 2f, center = center) // spindle
            // Tonearm (accent, like iOS): pivot at top-right of the chassis, needle sweeps with [arm].
            val pivot = Offset(s * RecordMath.ARM_PIVOT_X.toFloat(), s * RecordMath.ARM_PIVOT_Y.toFloat())
            // Positive degrees are clockwise: the arm swings from the outer edge toward the label.
            rotate(arm, pivot) {
                val tip = Offset(pivot.x, pivot.y + s * RecordMath.ARM_LENGTH.toFloat())
                drawLine(PdjAccent, pivot, tip, strokeWidth = 4.dp.toPx(), cap = StrokeCap.Round)
                drawCircle(PdjAccent, radius = 6.dp.toPx(), center = pivot)
            }
        }
    }
}

private suspend fun withFrameNanosCompat(): Long = androidx.compose.runtime.withFrameNanos { it }

/** Pure math for the gold record and the tonearm (iOS NowPlayingView record player). */
object RecordMath {
    const val DEFAULT_RPM = 100.0 / 3.0
    const val MIN_RPM = 8.0
    const val MAX_RPM = 120.0

    /** Manifest beat-grid BPM beats the catalog BPM; non-positive values are ignored. */
    fun effectiveBpm(manifestBeatGridBpm: Double?, catalogBpm: Double?): Double? =
        manifestBeatGridBpm?.takeIf { it > 0 } ?: catalogBpm?.takeIf { it > 0 }

    /** clamp(bpm/4, 8, 120) RPM; 33 1/3 RPM when no BPM is known. */
    fun rpm(bpm: Double?): Double =
        bpm?.takeIf { it > 0 }?.let { (it / 4.0).coerceIn(MIN_RPM, MAX_RPM) } ?: DEFAULT_RPM

    fun revsPerSecond(bpm: Double?): Double = rpm(bpm) / 60.0

    /** Degrees per second at [bpm]. */
    fun degreesPerSecond(bpm: Double?): Double = revsPerSecond(bpm) * 360.0

    /** Frame deltas above this are stalls (backgrounded), not rotation. */
    const val MAX_FRAME_DT_S = 0.25

    /**
     * Next platter angle in [0,360). Accumulates ONLY while [audible]; when paused the angle is
     * returned unchanged (freezes in place, resumes from the same angle).
     */
    fun advance(angleDeg: Double, dtSeconds: Double, audible: Boolean, bpm: Double?): Double {
        if (!audible || dtSeconds <= 0) return angleDeg
        val next = angleDeg + degreesPerSecond(bpm) * dtSeconds.coerceAtMost(MAX_FRAME_DT_S)
        return ((next % 360.0) + 360.0) % 360.0
    }

    /** Catalog length first, then the player's duration; non-positive = unknown. */
    fun lengthMs(catalogLengthMs: Long?, playerDurationMs: Long?): Long? =
        catalogLengthMs?.takeIf { it > 0 } ?: playerDurationMs?.takeIf { it > 0 }

    /** elapsed/length clamped to 0..1; null when the length is unknown. */
    fun progressFraction(elapsedMs: Long, lengthMs: Long?): Double? {
        val len = lengthMs?.takeIf { it > 0 } ?: return null
        return (elapsedMs.toDouble() / len).coerceIn(0.0, 1.0)
    }

    const val TONEARM_OUTER_DEG = 1.0
    const val TONEARM_INNER_DEG = 33.0
    /** Rest position, swung clear of the record (nothing loaded). */
    const val TONEARM_PARKED_DEG = -9.0

    // Geometry in chassis-size units (platter centre 0.5,0.5; record radius 0.42; label 0.30 of it).
    const val ARM_PIVOT_X = 0.90
    const val ARM_PIVOT_Y = 0.10
    const val ARM_LENGTH = 0.50
    const val RECORD_RADIUS = 0.42
    const val LABEL_RADIUS = RECORD_RADIUS * 0.30

    /** Stylus tip for a clockwise arm rotation of [degrees] (arm hangs straight down at 0). */
    fun tipPosition(degrees: Double): Pair<Double, Double> {
        val t = Math.toRadians(degrees)
        return (ARM_PIVOT_X - ARM_LENGTH * Math.sin(t)) to (ARM_PIVOT_Y + ARM_LENGTH * Math.cos(t))
    }

    /** Distance of the stylus tip from the platter centre at [fraction] of the song. */
    fun tipDistanceFromCentre(fraction: Double?): Double {
        val (x, y) = tipPosition(tonearmAngle(fraction))
        return Math.hypot(x - 0.5, y - 0.5)
    }

    /** Tonearm pivot angle: outer edge at 0 progress, record center at 1. */
    fun tonearmAngle(fraction: Double?): Double {
        val f = (fraction ?: 0.0).coerceIn(0.0, 1.0)
        return TONEARM_OUTER_DEG + (TONEARM_INNER_DEG - TONEARM_OUTER_DEG) * f
    }
}
