package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.AndroidStudioCodec
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
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
    ): List<MultitrackRenderContext.Clip>? {
        // Each source file is decoded once per pass and released after its last clip; only the clip's
        // window (not the whole file) is retained.
        val uses = HashMap<String, Int>()
        for (t in tracks) for (c in t.clips) uses.merge(c.fileName, 1, Int::plus)
        val decoded = HashMap<String, PcmBuffer?>()
        val clips = ArrayList<MultitrackRenderContext.Clip>()
        val beatFrames = ArrangerBeatMatch.beatFrames(bpm, rate)
        for ((ti, track) in tracks.withIndex()) {
            val strip = track.strip.clamped()
            for (clip in track.clips) {
                val left = (uses[clip.fileName] ?: 1) - 1
                uses[clip.fileName] = left
                val buf = if (decoded.containsKey(clip.fileName)) decoded[clip.fileName] else loader.decode(clip.fileName).also { decoded[clip.fileName] = it }
                if (left <= 0) decoded.remove(clip.fileName)
                if (isCancelled()) return null
                if (buf == null || buf.frames <= 0) continue
                val r = ArrangerBeatMatch.rate(clip.grid?.bpm ?: 0.0, bpm, strip.tempoRatio, beatMatch)
                val pitchCents = strip.pitchSemitones * 100
                val needsBake = ArrangerBeatMatch.needsBake(r, pitchCents)
                val startFrame = ArrangerBeatMatch.snappedStartFrame(
                    MultitrackRenderContext.msToFrames(clip.startMs, rate), beatFrames, beatMatch)
                val window = MultitrackPlayer.clipWindow(buf.frames, clip.fileStartMs, clip.durationMs, rate)
                if (window.frameLength <= 0) continue
                val warped = if (needsBake) loader.transform(buf, window.srcStart.toLong(), window.frameLength.toLong(), r, pitchCents) else null
                if (isCancelled()) return null
                if (warped != null && warped.frames > 0) {
                    clips += MultitrackRenderContext.Clip(ti, startFrame, warped.frames, 0, warped.toStereo().samples)
                } else {
                    val all = buf.toStereo().samples
                    val win = all.copyOfRange(window.srcStart * 2, (window.srcStart + window.frameLength) * 2)
                    clips += MultitrackRenderContext.Clip(ti, startFrame, window.frameLength, 0, win)
                }
            }
        }
        return clips
    }
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
    private val writeM4a: (PcmBuffer, File) -> Unit = { pcm, f -> AndroidStudioCodec.writeM4a(pcm, f) },
    private val newContext: () -> MultitrackRenderContext = { MultitrackRenderContext() },
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    /**
     * The mixdown as canonical stereo PCM, or null when the tracks hold no resolvable clips or the master
     * would exceed [MAX_SECONDS]. Length = the furthest warped clip end (no FX tail, like iOS).
     */
    suspend fun mixdown(
        tracks: List<StudioTrack>, masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120.0, beatMatch: Boolean = false,
    ): PcmBuffer? {
        val selected = tracks.filter { it.clips.isNotEmpty() }
        if (selected.isEmpty()) return null
        val clips = ArrangerClipPlan.build(selected, bpm, beatMatch, loader) ?: return null
        if (clips.isEmpty()) return null
        val total = clips.maxOf { it.startFrame + it.frameLength }
        if (total <= 0 || total.toLong() >= MAX_SECONDS.toLong() * StudioAudio.CANONICAL_RATE) return null
        return withContext(dispatcher) {
            val ctx = newContext()
            try {
                ctx.load(clips, selected.size, 0, false, 0, 0)
                val anySolo = false
                selected.forEachIndexed { i, t ->
                    // Mute/solo are intentionally NOT passed: only gain (dB clamped -24..+6) shapes a bounce.
                    ctx.setTrackMix(i, MultitrackRenderContext.audibleGain(t.gainDb, muted = false, soloed = false, anySolo = anySolo), t.pan.toFloat())
                    ctx.setTrackFx(i, t.strip.clamped().toKernelParams(bpm))
                }
                ctx.setMasterFx(masterFX.toKernelParams(bpm, allowFreeze = false))
                val samples = ctx.renderOffline(total)
                normalizeIfClipping(samples)
                PcmBuffer(StudioAudio.CANONICAL_RATE, 2, samples)
            } finally { ctx.release() }
        }
    }

    /** Mix and write [dest] (atomic temp+rename). Returns the master length in ms, or null on nothing-to-bounce / failure. */
    suspend fun bounceToFile(
        tracks: List<StudioTrack>, dest: File, masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120.0, beatMatch: Boolean = false,
    ): Int? {
        val pcm = mixdown(tracks, masterFX, bpm, beatMatch) ?: return null
        return withContext(dispatcher) { writeAtomically(pcm, dest) }
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

    private fun writeAtomically(pcm: PcmBuffer, dest: File): Int? {
        val dir = dest.absoluteFile.parentFile ?: return null
        dir.mkdirs()
        val tmp = File(dir, ".bounce-${UUID.randomUUID()}-${dest.name}")
        return try {
            writeM4a(pcm, tmp)
            dest.delete()
            if (!tmp.renameTo(dest)) { tmp.delete(); null } else Math.round(pcm.frames.toDouble() / StudioAudio.CANONICAL_RATE * 1000).toInt()
        } catch (t: Throwable) { tmp.delete(); if (t is kotlinx.coroutines.CancellationException) throw t; null }
    }

    companion object {
        /** Cap the master length so a runaway timeline can't allocate an unbounded accumulator. */
        const val MAX_SECONDS = 30 * 60

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
