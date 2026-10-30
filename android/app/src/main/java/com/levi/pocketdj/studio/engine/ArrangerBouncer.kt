package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AacEncoder
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.PcmChunkWriter
import com.levi.pocketdj.studio.audio.AndroidStudioCodec
import com.levi.pocketdj.studio.audio.BufferedM4aWriter
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioMasterFX
import com.levi.pocketdj.studio.model.StudioTrack
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max

/**
 * Turns arranger tracks into render-context clips: decode each source file ONCE per pass, window it by the
 * non-destructive `fileStartMs`/`durationMs`, warp it by Beat Match x per-track tempo (+ strip pitch) through
 * the stretcher, and snap its start to the master beat. This is the ONE planning path both the live
 * [MultitrackPlayer] and the [ArrangerBouncer] run, which is what makes a bounce identical to playback
 * (the iOS two-read-path WYSIWYG invariant) instead of two copies that can drift.
 */
object ArrangerClipPlan {
    /**
     * Clips for [tracks] (clip.trackIndex = position in [tracks]) or null when [isCancelled] flipped across a
     * decode/warp await (a stop/second play won). Missing/unreadable files are skipped.
     */
    suspend fun build(
        tracks: List<StudioTrack>, bpm: Double, beatMatch: Boolean, loader: MultitrackClipLoader,
        rate: Int = StudioAudio.CANONICAL_RATE, isCancelled: () -> Boolean = { false },
        /** ANS-STU-5: when set, windows of [shortClipFrames]+ frames are cached as PCM16 pages and read through mmap (heap O(1)). */
        pager: ClipPageStore? = null,
        shortClipFrames: Int = ClipPageStore.SHORT_CLIP_FRAMES,
    ): List<MultitrackRenderContext.Clip>? {
        val beatFrames = ArrangerBeatMatch.beatFrames(bpm, rate)
        // Per-clip warp parameters + cache lookup first: a file whose clips all hit the page cache is never decoded.
        class Item(val ti: Int, val clip: StudioClip, val r: Double, val pitchCents: Double, val needsBake: Boolean,
                   val startFrame: Int, val key: ClipPageStore.Key?, val cached: ClipReader?)
        val items = ArrayList<Item>()
        for ((ti, track) in tracks.withIndex()) {
            val strip = track.strip.clamped()
            for (clip in track.clips) {
                val r = ArrangerBeatMatch.rate(clip.grid?.bpm ?: 0.0, bpm, strip.tempoRatio, beatMatch)
                val pitchCents = strip.pitchSemitones * 100
                val key = pager?.let { ClipPageStore.Key(clip.fileName, loader.sourceStamp(clip.fileName), clip.fileStartMs, clip.durationMs, r, pitchCents, rate) }
                val cached = if (pager != null && key != null && pager.has(key)) pager.open(key) else null
                items += Item(ti, clip, r, pitchCents, ArrangerBeatMatch.needsBake(r, pitchCents),
                    ArrangerBeatMatch.snappedStartFrame(MultitrackRenderContext.msToFrames(clip.startMs, rate), beatFrames, beatMatch), key, cached)
            }
        }
        // Each source file is decoded once per pass and released after its last uncached clip; only the clip's
        // window (not the whole file) is retained.
        val uses = HashMap<String, Int>()
        for (w in items) if (w.cached == null) uses.merge(w.clip.fileName, 1, Int::plus)
        val decoded = HashMap<String, PcmBuffer?>()
        val clips = ArrayList<MultitrackRenderContext.Clip>()
        try {
            for (w in items) {
                val clip = w.clip
                if (w.cached != null) {
                    if (isCancelled()) { w.cached.close(); return null.also { closeAll(clips) } }
                    clips += MultitrackRenderContext.Clip(w.ti, w.startFrame, w.cached.frameCount, 0, null, w.cached)
                    continue
                }
                val left = (uses[clip.fileName] ?: 1) - 1
                uses[clip.fileName] = left
                val buf = if (decoded.containsKey(clip.fileName)) decoded[clip.fileName] else loader.decode(clip.fileName).also { decoded[clip.fileName] = it }
                if (left <= 0) decoded.remove(clip.fileName)
                if (isCancelled()) { closeAll(clips); return null }
                if (buf == null || buf.frames <= 0) continue
                val window = MultitrackPlayer.clipWindow(buf.frames, clip.fileStartMs, clip.durationMs, rate)
                if (window.frameLength <= 0) continue
                val warped = if (w.needsBake) loader.transform(buf, window.srcStart.toLong(), window.frameLength.toLong(), w.r, w.pitchCents) else null
                if (isCancelled()) { closeAll(clips); return null }
                val usable = warped != null && warped.frames > 0
                val frames = if (usable) warped!!.frames else window.frameLength
                // The unwarped fallback is the raw window, so it must not poison the warped key.
                val key = if (usable || !w.needsBake) w.key else pager?.let { _ ->
                    ClipPageStore.Key(clip.fileName, loader.sourceStamp(clip.fileName), clip.fileStartMs, clip.durationMs, 1.0, 0.0, rate)
                }
                val samples: FloatArray = if (usable) warped!!.toStereo().samples else {
                    buf.toStereo().samples.copyOfRange(window.srcStart * 2, (window.srcStart + window.frameLength) * 2)
                }
                val paged = if (pager != null && key != null && frames >= shortClipFrames) {
                    runCatching { pager.write(key, samples, frames); pager.open(key) }.getOrNull()
                } else null
                clips += if (paged != null) MultitrackRenderContext.Clip(w.ti, w.startFrame, frames, 0, null, paged)
                else MultitrackRenderContext.Clip(w.ti, w.startFrame, frames, 0, samples)
            }
        } catch (t: Throwable) { closeAll(clips); throw t }
        pager?.trim(items.mapNotNull { it.key }.toSet())
        return clips
    }

    private fun closeAll(clips: List<MultitrackRenderContext.Clip>) = clips.forEach { it.reader?.close() }
}

/**
 * Bounces a set of arranger tracks to ONE master file (iOS `ArrangerBouncer`), artifact-only: a dated
 * `bounce-<ts>.m4a` plus a [StudioArrangementArtifact]; no clip or track is created. The mix is the SAME
 * [MultitrackRenderContext] math the live player runs (per-track gain/pan, strip FX kernels, master FX +
 * master gain; Freeze bypassed), pulled offline, so a bounce matches what you heard. Per-track GAIN + pan
 * are applied; MUTE and SOLO are live-monitor aids only (you choose which tracks to bounce). A peak
 * normalize prevents summing overflow. Everything runs off the main thread.
 */
class ArrangerBouncer(
    private val loader: MultitrackClipLoader,
    /** Legacy whole-buffer encoder seam (tests / fakes); null = stream through [openM4a]. */
    private val writeM4a: ((PcmBuffer, File) -> Unit)? = null,
    private val openM4a: (File, Int) -> PcmChunkWriter = { f, rate -> AndroidStudioCodec.openM4a(f, rate) },
    private val newContext: () -> MultitrackRenderContext = { MultitrackRenderContext() },
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private fun open(file: File): PcmChunkWriter =
        writeM4a?.let { w -> BufferedM4aWriter(StudioAudio.CANONICAL_RATE, 2) { w(it, file) } } ?: openM4a(file, StudioAudio.CANONICAL_RATE)

    /** Everything a render pass needs: resolved clips + the mix settings. Cheap to replay (the pass itself is block-wise). */
    private class Plan(val selected: List<StudioTrack>, val clips: List<MultitrackRenderContext.Clip>, val total: Int,
                       val masterFX: StudioMasterFX, val bpm: Double)

    private suspend fun plan(tracks: List<StudioTrack>, masterFX: StudioMasterFX, bpm: Double, beatMatch: Boolean): Plan? {
        val selected = tracks.filter { it.clips.isNotEmpty() }
        if (selected.isEmpty()) return null
        val clips = ArrangerClipPlan.build(selected, bpm, beatMatch, loader) ?: return null
        if (clips.isEmpty()) return null
        val total = clips.maxOf { it.startFrame + it.frameLength }
        if (total <= 0 || total.toLong() >= MAX_SECONDS.toLong() * StudioAudio.CANONICAL_RATE) return null
        return Plan(selected, clips, total, masterFX, bpm)
    }

    /** One full block-wise render of [p] through a fresh context (the context is stateful, so every pass starts clean). */
    private fun renderPass(p: Plan, sink: (FloatArray, Int) -> Unit) {
        val ctx = newContext()
        try {
            ctx.load(p.clips, p.selected.size, 0, false, 0, 0)
            p.selected.forEachIndexed { i, t ->
                // Mute/solo are intentionally NOT passed: only gain (dB clamped -24..+6) shapes a bounce.
                ctx.setTrackMix(i, MultitrackRenderContext.audibleGain(t.gainDb, muted = false, soloed = false, anySolo = false), t.pan.toFloat())
                ctx.setTrackFx(i, t.strip.clamped().toKernelParams(p.bpm))
            }
            ctx.setMasterFx(p.masterFX.toKernelParams(p.bpm, allowFreeze = false))
            ctx.renderOfflineBlocks(p.total, BLOCK_FRAMES, sink)
        } finally { ctx.release() }
    }

    /**
     * Two-pass streamed bounce: pass 1 renders to find the peak (nothing retained), pass 2 re-renders with the
     * iOS peak-normalize scale applied and streams each block into [writer]. Heap stays O(block).
     */
    private fun streamTo(p: Plan, writer: PcmChunkWriter) {
        var peak = 0f
        renderPass(p) { b, n -> val m = n * 2; for (i in 0 until m) { val a = abs(b[i]); if (a > peak) peak = a } }
        val inv = if (peak > 1f) 1f / peak else 1f
        renderPass(p) { b, n ->
            if (inv != 1f) for (i in 0 until n * 2) b[i] *= inv
            writer.write(b, n)
        }
    }

    /**
     * The mixdown as canonical stereo PCM (whole buffer: tests and short renders; bounces use [bounceToFile]'s
     * streaming path), or null when the tracks hold no resolvable clips or the master would exceed [MAX_SECONDS].
     * Length = the furthest warped clip end (no FX tail, like iOS).
     */
    suspend fun mixdown(
        tracks: List<StudioTrack>, masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120.0, beatMatch: Boolean = false,
    ): PcmBuffer? {
        val p = plan(tracks, masterFX, bpm, beatMatch) ?: return null
        return withContext(dispatcher) {
            val samples = FloatArray(p.total * 2)
            var at = 0
            renderPass(p) { b, n -> System.arraycopy(b, 0, samples, at, n * 2); at += n * 2 }
            normalizeIfClipping(samples)
            PcmBuffer(StudioAudio.CANONICAL_RATE, 2, samples)
        }
    }

    /** Mix and stream [dest] (atomic temp+rename). Returns the master length in ms, or null on nothing-to-bounce / failure. */
    suspend fun bounceToFile(
        tracks: List<StudioTrack>, dest: File, masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120.0, beatMatch: Boolean = false,
    ): Int? {
        val p = plan(tracks, masterFX, bpm, beatMatch) ?: return null
        return withContext(dispatcher) { writeAtomically(p, dest) }
    }

    /**
     * The artifact-only Bounce: writes `bounce-<stamp>.m4a` into [dir] and files a `.bounce` artifact under the
     * arrangement. Null (nothing written) when there is nothing to bounce or the encode failed.
     */
    suspend fun bounceArtifact(
        arrangement: StudioArrangement, tracks: List<StudioTrack>, dir: File, store: StudioStore,
        stamp: String, now: Double = System.currentTimeMillis().toDouble(),
    ): StudioArrangementArtifact? {
        val fileName = "bounce-$stamp.m4a"
        val ms = bounceToFile(tracks, File(dir, fileName), arrangement.masterFX, arrangement.bpm, arrangement.beatMatchEnabled) ?: return null
        if (ms <= 0) { File(dir, fileName).delete(); return null }
        return store.addArrangementArtifact(
            StudioArrangementArtifact(StudioFactory.newArtifactId(), arrangement.id, StudioArrangementArtifact.Kind.BOUNCE, "bounce-$stamp", fileName, ms, now),
        )
    }

    private fun writeAtomically(p: Plan, dest: File): Int? {
        val dir = dest.absoluteFile.parentFile ?: return null
        dir.mkdirs()
        val tmp = File(dir, ".bounce-${UUID.randomUUID()}-${dest.name}")
        var writer: PcmChunkWriter? = null
        return try {
            writer = open(tmp)
            streamTo(p, writer)
            writer.close(); writer = null
            dest.delete()
            if (!tmp.renameTo(dest)) { tmp.delete(); null } else Math.round(p.total.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt()
        } catch (t: Throwable) {
            writer?.let { w -> runCatching { (w as? AacEncoder.Stream)?.abort() ?: w.close() } }
            tmp.delete(); if (t is kotlinx.coroutines.CancellationException) throw t; null
        }
    }

    companion object {
        /** Cap the master length so a runaway timeline can't allocate an unbounded accumulator. */
        const val MAX_SECONDS = 30 * 60

        /** Render block (frames) for the streamed bounce: the largest array a bounce ever holds besides the clips. */
        const val BLOCK_FRAMES = 4096

        /** Scale the whole mix so its peak is 1.0 when summed overlaps / master gain pushed it over (iOS rule). */
        fun normalizeIfClipping(samples: FloatArray) {
            var peak = 0f
            for (v in samples) { val a = abs(v); if (a > peak) peak = a }
            if (peak > 1f) { val inv = 1f / peak; for (i in samples.indices) samples[i] *= inv }
        }

        /** Peak absolute sample. */
        fun peak(samples: FloatArray): Float { var p = 0f; for (v in samples) p = max(p, abs(v)); return p }
    }
}
