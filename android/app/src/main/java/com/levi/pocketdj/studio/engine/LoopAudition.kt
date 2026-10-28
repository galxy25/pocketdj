package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.PcmClipSource
import com.levi.pocketdj.studio.audio.RenderGraph
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.audio.StudioRenderException
import com.levi.pocketdj.studio.demux.BeatGrid
import com.levi.pocketdj.studio.demux.BeatMath
import com.levi.pocketdj.studio.demux.SliceBounds
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import kotlin.math.max

/** Pure loop-builder math shared by the Loops tab, the builder sheet and the tests (iOS StudioLoopsView statics). */
object LoopMath {
    /** The grid in the shape the slice math consumes. */
    fun beatGrid(g: StudioGrid): BeatGrid = BeatGrid(g.bpm, g.firstDownbeatMs, g.beatsMs)

    /** The anchor in effect: the user-stepped one, else "from start" = the grid's first downbeat. */
    fun effectiveAnchor(custom: Int?, grid: StudioGrid): Int = custom ?: grid.firstDownbeatMs

    /**
     * The exact window the renderer slices (same call as [com.levi.pocketdj.studio.audio.StudioRenderCore.loopBuffer]):
     * a measured grid gives the SUM OF REAL INTER-BEAT INTERVALS; a constant grid gives beats x 60000 / bpm.
     */
    fun window(anchorMs: Int, beats: LoopBeats, grid: StudioGrid): SliceBounds? =
        BeatMath.sliceBoundaries(anchorMs, beats.beatCount, beatGrid(grid))?.takeIf { it.lengthMs > 0 }

    fun lengthMs(anchorMs: Int, beats: LoopBeats, grid: StudioGrid): Int? = window(anchorMs, beats, grid)?.lengthMs

    /** The AUTHORITATIVE rendered frame count of a [lengthMs] window at rate 1 (ms-derived counts tick at the seam). */
    fun frames(lengthMs: Int): Long = StudioAudio.exactLoopFrames(lengthMs, 1.0)

    /** Constant beat spacing for stepping past / before the measured grid (stated bpm, else the grid's own mean). */
    fun beatStep(grid: StudioGrid): Double? {
        if (grid.bpm > 0) return 60_000.0 / grid.bpm
        val b = grid.beatsMs
        if (b.size < 2 || b.last() <= b.first()) return null
        return (b.last() - b.first()).toDouble() / (b.size - 1)
    }

    /** The beat one step BEFORE [startMs] on the same real-or-extended lattice the slicer walks; null at the first beat. */
    fun previousBeat(startMs: Int, grid: StudioGrid): Int? {
        val real = grid.beatsMs
        if (real.isNotEmpty()) {
            val step = beatStep(grid)
            if (startMs > real.last() && step != null) {
                return Math.round(max(real.last().toDouble(), startMs - step)).toInt()
            }
            var lo = 0; var hi = real.size
            while (lo < hi) { val mid = (lo + hi) / 2; if (real[mid] < startMs) lo = mid + 1 else hi = mid }
            return if (lo > 0) real[lo - 1] else null
        }
        val step = beatStep(grid) ?: return null
        val prev = startMs - step
        return if (prev >= grid.firstDownbeatMs - 0.5) Math.round(prev).toInt() else null
    }

    /** The anchor the +/- steppers display: the snapped beat the slicer would start on. */
    fun snappedAnchor(custom: Int?, grid: StudioGrid): Int {
        val a = effectiveAnchor(custom, grid)
        return BeatMath.sliceBoundaries(a, 1.0, beatGrid(grid))?.startMs ?: a
    }

    /** Can the anchor step one beat earlier? */
    fun canStepBack(custom: Int?, grid: StudioGrid): Boolean = previousBeat(snappedAnchor(custom, grid), grid) != null

    /** Can the anchor step one beat later without landing in pure silence (next beat at/after the sample's end)? */
    fun canStepForward(custom: Int?, grid: StudioGrid, sampleDurationMs: Int): Boolean {
        val step = BeatMath.sliceBoundaries(effectiveAnchor(custom, grid), 1.0, beatGrid(grid)) ?: return false
        return step.endMs < sampleDurationMs
    }

    /** New custom anchor after a +/-1 beat step, or [custom] unchanged when the step is refused. */
    fun stepAnchor(custom: Int?, direction: Int, grid: StudioGrid): Int? {
        val cur = BeatMath.sliceBoundaries(effectiveAnchor(custom, grid), 1.0, beatGrid(grid)) ?: return custom
        return if (direction > 0) cur.endMs else previousBeat(cur.startMs, grid) ?: custom
    }

    /** Does the window overhang the sample end (the overhang renders as silence)? */
    fun overhangs(w: SliceBounds, sampleDurationMs: Int) = w.endMs > sampleDurationMs

    /** Conform a decoded loop to its AUTHORITATIVE frame count (truncate extra, zero-pad a shortfall); frames <= 0 = as decoded. */
    fun conform(pcm: PcmBuffer, frames: Long): PcmBuffer? =
        if (frames <= 0) pcm.takeIf { it.frames > 0 } else StudioAudio.trimmedOrPadded(pcm, frames)

    fun beatsWord(b: LoopBeats) = if (b.beatCount == 1.0) "beat" else "beats"

    fun defaultName(sampleName: String, b: LoopBeats) =
        "${sampleName.ifEmpty { "Sample" }} · ${b.label} ${beatsWord(b)}"

    /** Sub-10 s lengths in raw ms (a 1/2-beat loop is 250 ms); longer as m:ss. */
    fun lengthLabel(ms: Int): String = if (ms < 10_000) "$ms ms" else {
        val s = ms / 1000; "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
    }

    fun rowSubtitle(l: StudioLoop): String =
        "${l.beats.label} ${beatsWord(l.beats)} · ${"%.1f".format(java.util.Locale.US, l.bpm)} BPM · ${lengthLabel(l.lengthMs)}"

    fun deleteMessage(patternRows: Int): String {
        var msg = "This deletes the loop’s audio file."
        if (patternRows > 0) msg += " $patternRows sequencer row${if (patternRows == 1) "" else "s"} targeting it will go silent."
        return msg
    }

    const val SOURCE_REMOVED_NOTE = "Source sample removed — still plays, can’t be re-sliced"
    const val GRIDLESS_CTA = "Set BPM in the sample editor to slice loops"
    const val PREVIEW_ID = "lp_preview"
}

/** Why a loop render/save failed (maps to user copy). */
sealed class LoopFailure(val message: String) {
    object NoSource : LoopFailure("The sample’s audio file can’t be reached right now.")
    object NoFolder : LoopFailure("The loops folder can’t be written right now.")
    object NoGrid : LoopFailure("No usable beat grid at this anchor.")
    object EmptyWindow : LoopFailure("The window has no audio — move the anchor earlier.")
    object Unreadable : LoopFailure("The sample’s audio file can’t be read.")
    object Other : LoopFailure("Rendering failed — please try again.")

    companion object {
        fun from(e: Throwable): LoopFailure = when (e) {
            is StudioRenderException.NoGrid -> NoGrid
            is StudioRenderException.EmptyWindow -> EmptyWindow
            is StudioRenderException.UnreadableSource -> Unreadable
            else -> Other
        }
    }
}

class LoopException(val failure: LoopFailure) : Exception(failure.message)

/**
 * Renders loops through the REAL [StudioRender.renderLoop] (preview and Save share one code path and so cannot
 * drift). The raw (never the edit-cache) sample file is the source: the renderer bakes the edits itself, and the
 * grid/anchor live in the RAW file's timeline.
 */
class LoopFactory(
    private val roots: StudioRoots,
    private val store: StudioStore,
    private val render: StudioRender,
    private val rawFile: (StudioSample) -> File?,
    private val previewFile: File,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** Render a TEMP loop (outside every family folder) and return a synthetic [StudioLoop] to audition. */
    suspend fun renderPreview(sample: StudioSample, anchorMs: Int, beats: LoopBeats): Pair<StudioLoop, File> {
        val grid = sample.grid ?: throw LoopException(LoopFailure.NoGrid)
        val src = rawFile(sample) ?: throw LoopException(LoopFailure.NoSource)
        previewFile.parentFile?.mkdirs()
        val r = try { render.renderLoop(sample.edit, src.path, anchorMs, beats, grid, previewFile) } catch (e: StudioRenderException) {
            throw LoopException(LoopFailure.from(e))
        }
        val synthetic = StudioLoop(
            id = LoopMath.PREVIEW_ID, name = "Preview", sampleId = sample.id, anchorMs = anchorMs, beats = beats,
            bpm = r.bpm, lengthMs = r.lengthMs, frames = r.frames, fileName = previewFile.name,
        )
        return synthetic to previewFile
    }

    /** Render + file a loop; the record carries the RENDERER's returned truth (frames authoritative, bpm standalone). */
    suspend fun save(sample: StudioSample, anchorMs: Int, beats: LoopBeats, typedName: String?): StudioLoop {
        val grid = sample.grid ?: throw LoopException(LoopFailure.NoGrid)
        val src = rawFile(sample) ?: throw LoopException(LoopFailure.NoSource)
        val id = StudioFactory.newLoopId()
        val fileName = StudioFolders.fileName(StudioFamily.LOOPS, id)
        val dest = StudioFiles.appFile(roots, StudioFamily.LOOPS, fileName) ?: throw LoopException(LoopFailure.NoFolder)
        dest.parentFile?.mkdirs()
        val r = try { render.renderLoop(sample.edit, src.path, anchorMs, beats, grid, dest) } catch (e: StudioRenderException) {
            dest.delete(); throw LoopException(LoopFailure.from(e))
        }
        val name = typedName?.trim().orEmpty().ifEmpty { LoopMath.defaultName(sample.name, beats) }
        return store.addLoop(
            StudioLoop(
                id = id, name = name, sampleId = sample.id, anchorMs = anchorMs, beats = beats, bpm = r.bpm,
                lengthMs = r.lengthMs, frames = r.frames, fileName = fileName, wasUserFolder = false, createdAt = now(),
            ),
        )
    }
}

/**
 * Seamless looped audition of rendered loops (iOS StudioEngine.playLoop/stopLoop). The decoded file is
 * conformed to the loop's AUTHORITATIVE frame count and the whole buffer loops with no gap or overlap
 * ([PcmClipSource] wraps inside a single pull). Self-contained: it reads only the loop's own file, so a loop
 * outlives its parent sample. One loop at a time; a different audio owner (mic capture, no focus) refuses.
 */
class LoopAudition(
    private val sinkFactory: () -> AudioSink,
    private val decode: suspend (String) -> PcmBuffer?,
    private val focus: (() -> Boolean)? = null,
    private val focusRelease: (() -> Unit)? = null,
    private val diag: (String) -> Unit = {},
) {
    private val graph = RenderGraph()
    private var sink: AudioSink? = null
    private val _playingId = MutableStateFlow<String?>(null)
    /** The loop id currently looping (the preview's id is [LoopMath.PREVIEW_ID]); null when silent. */
    val playingId: StateFlow<String?> = _playingId.asStateFlow()
    @Volatile var lastRefusal: String? = null; private set
    /** Frames of the buffer actually looping (logcat verification: equals the loop's recorded frames). */
    @Volatile var loopedFrames: Long = 0; private set

    /** Loop [file] as [id], conformed to [frames] (<= 0: as decoded). False when refused or unreadable. */
    suspend fun play(id: String, file: File, frames: Long): Boolean {
        if (!AudioFocusPolicy.mayStartPlayback()) { lastRefusal = "mic-capture-active"; diag("loop play refused: mic capture"); return false }
        val raw = decode(file.path) ?: run { lastRefusal = "unreadable"; diag("loop $id unreadable ${file.name}"); return false }
        val buf = LoopMath.conform(raw, frames) ?: run { lastRefusal = "unreadable"; return false }
        if (focus != null && !focus.invoke()) { lastRefusal = "no-focus"; diag("loop play refused: no focus"); return false }
        lastRefusal = null
        stopInternal(releaseFocus = false)
        loopedFrames = buf.frames.toLong()
        graph.addTrack(TRACK, PcmClipSource(buf, loop = true))
        val k = sink ?: sinkFactory().also { sink = it }
        if (!k.isRendering) k.start(graph)
        _playingId.value = id
        diag("loop play $id decoded=${raw.frames} looped=${buf.frames} expected=$frames")
        return true
    }

    fun stop() = stopInternal(releaseFocus = true)

    private fun stopInternal(releaseFocus: Boolean) {
        graph.removeTrack(TRACK)
        if (_playingId.value != null) {
            _playingId.value = null
            sink?.stop()
            if (releaseFocus) focusRelease?.invoke()
        }
    }

    fun release() {
        stop()
        sink?.let { runCatching { it.release() } }
        sink = null
        graph.release()
    }

    companion object { private const val TRACK = "loop" }
}
