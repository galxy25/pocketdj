package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.model.StudioTrack
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Arranger-side additions to [StudioStore] (iOS `StudioStore` Arrangements extension) and the pure
 * timeline math the Tracks UI shares with its tests. The CRUD core (arrangements, tracks, clips, strip
 * setters, `mutateArrangement`, bpm seeding, artifacts) lives in [StudioStore] (STU-1); what is here is
 * what the Tracks surface adds on top.
 */

fun StudioStore.artifact(id: String): StudioArrangementArtifact? = doc.arrangementArtifacts.firstOrNull { it.id == id }

/** Folders in name order + the loose arrangements, as the home list renders them. */
fun StudioStore.arrangementFoldersOrdered() = foldersOrdered(StudioFolderKind.ARRANGEMENT)

/** True when [id] is an arranger id, which must NEVER be a Collections-addable studio id. */
fun isArrangerId(id: String) = id.startsWith("arr_") || id.startsWith("trk_") || id.startsWith("clip_")

/**
 * Convert a bounce / live-recording artifact into an INDEPENDENT sample (fresh `smp_` id, its own
 * file in the samples root; deleting the artifact or its arrangement never touches the sample).
 */
class ArtifactSampleConverter(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    suspend fun createSampleFromArtifact(artifact: StudioArrangementArtifact): StudioSample? {
        val src = store.artifactFile(artifact.fileName) ?: return null
        val id = StudioFactory.newSampleId()
        val name = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        val dest = StudioFiles.appFile(roots, StudioFamily.SAMPLES, name) ?: return null
        dest.parentFile?.mkdirs()
        val baked = try {
            render.importAudioFile(src.path, dest)
        } catch (e: kotlinx.coroutines.CancellationException) {
            dest.delete(); throw e
        } catch (_: Exception) {
            dest.delete(); return null
        }
        if (baked.durationMs <= 0) { dest.delete(); return null }
        return store.addSample(
            StudioSample(
                id, artifact.name, name, wasUserFolder = false, createdAt = now(),
                durationMs = baked.durationMs, source = StudioSource.File(artifact.name),
            ),
        )
    }
}

/** Palette (stem colours first: drums yellow, bass red, other green, vocals purple), cycling at 8. */
object TrackPalette {
    val names = listOf("Yellow", "Red", "Green", "Purple", "Cyan", "Orange", "Pink", "Mint")
    /** 0xRRGGBB for each swatch (the UI wraps them in a Color). */
    val rgb = intArrayOf(0xFFD60A, 0xFF453A, 0x32D74B, 0xBF5AF2, 0x64D2FF, 0xFF9F0A, 0xFF6482, 0x63E6BE)
    val size get() = names.size
    fun index(i: Int) = Math.floorMod(i, size)
    fun name(i: Int) = names[index(i)]
    fun rgb(i: Int) = rgb[index(i)]
}

/** Pure timeline math for the arranger (zoom ladder, follow anchors, beat ruler, snapping). */
object ArrangerMath {
    /** Horizontal zoom stops (dp per second); default 48. */
    val ZOOM_LADDER = floatArrayOf(16f, 24f, 36f, 48f, 72f, 108f, 160f, 240f)
    const val DEFAULT_PX_PER_SEC = 48f
    const val MAX_ANCHORS = 3600

    /** Fit-to-width: the whole arrangement fits [viewport]. Zoom-out may go below the ladder floor. */
    fun fitPx(lengthMs: Int, viewport: Float): Float {
        val secs = max(0.5, lengthMs / 1000.0)
        if (viewport <= 40f) return ZOOM_LADDER.first()
        return max(1f, ((viewport - 28f) / secs).toFloat())
    }

    /** One zoom step. dir < 0 zooms out (down to [fit]); dir > 0 zooms in (up to the ladder top). */
    fun stepZoom(dir: Int, current: Float, fit: Float): Float {
        if (dir < 0) {
            val lower = ZOOM_LADDER.lastOrNull { it < current - 0.01f }
            return if (lower != null && lower > fit) lower else fit
        }
        return ZOOM_LADDER.firstOrNull { it > current + 0.01f } ?: ZOOM_LADDER.last()
    }

    fun canZoomOut(current: Float, fit: Float) = current > fit + 0.01f
    fun canZoomIn(current: Float) = current < ZOOM_LADDER.last()

    fun timelineWidth(lengthMs: Int, pxPerSec: Float): Float = max(560f, lengthMs / 1000f * pxPerSec + 160f)

    /** Bounded per-second anchor count: every anchor AND every scroll target derive from this. */
    fun anchorSecondsCount(lengthMs: Int): Int = min(MAX_ANCHORS, max(1, ceil(lengthMs / 1000.0).toInt() + 2))

    fun cursorAnchorSec(cursorMs: Int, lengthMs: Int): Int =
        max(0, min(anchorSecondsCount(lengthMs), cursorMs / 1000))

    /** The cursor clamped into the CURRENT timeline (a trim after a seek can strand it past the end). */
    fun effectiveCursorMs(cursorMs: Int, lengthMs: Int) = max(0, min(cursorMs, max(0, lengthMs)))

    fun beatPx(bpm: Double, pxPerSec: Float): Float = if (bpm > 0) (pxPerSec * 60.0 / bpm).toFloat() else 0f

    /** Seek position (ms) from a tap at timeline x, clamped into [0, lengthMs]. */
    fun seekMsForX(x: Float, pxPerSec: Float, lengthMs: Int): Int =
        max(0, min((x / pxPerSec * 1000f).toInt(), max(0, lengthMs)))

    /**
     * Horizontal scroll offset that CENTRES [cursorMs] in a [viewport]-wide window over [content]-wide
     * content. 0 until the cursor passes the first half-screenful (so nothing scrolls early).
     */
    fun followScrollTarget(cursorMs: Int, pxPerSec: Float, viewport: Float, content: Float): Int {
        val x = cursorMs / 1000f * pxPerSec
        val maxScroll = max(0f, content - viewport)
        return (x - viewport / 2f).coerceIn(0f, maxScroll).roundToInt()
    }

    fun clipX(startMs: Int, pxPerSec: Float, dragDx: Float = 0f): Float = max(0f, startMs / 1000f * pxPerSec + dragDx)
    fun clipWidth(durationMs: Int, pxPerSec: Float): Float = max(10f, durationMs / 1000f * pxPerSec)

    /** Drop position (ms) after a horizontal drag of [dx] px; Beat Match snaps to the nearest beat. */
    fun dropMs(startMs: Int, dx: Float, pxPerSec: Float, beatMatch: Boolean, bpm: Double): Int {
        val target = max(0, startMs + (dx / pxPerSec * 1000f).toInt())
        return if (beatMatch) snapMs(target, bpm) else target
    }

    fun snapMs(ms: Int, bpm: Double): Int {
        if (bpm <= 0) return max(0, ms)
        val beatMs = 60_000.0 / bpm
        return max(0, ((ms / beatMs).roundToInt() * beatMs).toInt())
    }

    data class Tick(val x: Float, val isBar: Boolean, val barNumber: Int?)

    /** Beat ticks across [width] px (4/4 bars); empty when beats are < 4 px apart (unreadable). */
    fun beatTicks(bpm: Double, pxPerSec: Float, width: Float): List<Tick> {
        val bp = beatPx(bpm, pxPerSec)
        if (bp < 4f) return emptyList()
        val out = ArrayList<Tick>()
        var k = 0
        while (k * bp <= width) {
            val bar = k % 4 == 0
            out += Tick(k * bp, bar, if (bar) k / 4 + 1 else null)
            k++
        }
        return out
    }

    /** Bar numbers are printed only when a bar is at least 22 px wide. */
    fun showBarNumbers(bpm: Double, pxPerSec: Float) = beatPx(bpm, pxPerSec) * 4 >= 22f

    fun mmss(seconds: Double): String {
        val t = max(0, seconds.roundToInt())
        return "${t / 60}:${(t % 60).toString().padStart(2, '0')}"
    }

    /** `yyyy-MM-dd HH-mm-ss` — no colons, filesystem-safe (artifact names). */
    fun artifactStamp(at: Date = Date()): String = SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).format(at)

    /** Home-row summary: "3 tracks · 1:05". */
    fun summary(a: StudioArrangement): String =
        "${a.tracks.size} track${if (a.tracks.size == 1) "" else "s"} · ${mmss(a.lengthMs / 1000.0)}"

    /** Pan-dial sweep: the indicator travels +-135 degrees over pan -1..+1. */
    private const val PAN_MAX_ANGLE = 135.0 * Math.PI / 180

    /**
     * Pan (-1..+1) for a touch at ([dx], [dy]) from the dial centre (0 deg = straight up, clockwise
     * positive), snapping to dead centre within 6%. Null when the touch is on the hub (no direction).
     */
    fun panForPoint(dx: Float, dy: Float): Double? {
        if (kotlin.math.abs(dx) + kotlin.math.abs(dy) <= 1f) return null
        val ang = kotlin.math.atan2(dx.toDouble(), -dy.toDouble()).coerceIn(-PAN_MAX_ANGLE, PAN_MAX_ANGLE)
        val p = ang / PAN_MAX_ANGLE
        return if (kotlin.math.abs(p) < 0.06) 0.0 else p
    }

    /** "Center" / "Left 40%" / "Right 100%". */
    fun panText(p: Double): String =
        if (kotlin.math.abs(p) < 0.02) "Center" else if (p < 0) "Left ${(-p * 100).toInt()}%" else "Right ${(p * 100).toInt()}%"

    /** Where a new clip lands on [track]: appended after its last clip. */
    fun appendStartMs(track: StudioTrack?) = track?.lengthMs ?: 0
}
