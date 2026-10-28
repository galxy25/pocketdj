package com.levi.pocketdj.studio

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.data.collections.StudioItemInfo
import com.levi.pocketdj.data.collections.StudioLookup
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.engine.PatternBounceException
import com.levi.pocketdj.studio.engine.PatternBouncer
import com.levi.pocketdj.studio.engine.PatternMath
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioPlayable
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Ports [StudioPlayback] needs from the audio stack; implemented over the real
 * [com.levi.pocketdj.studio.audio.StudioRender] / [com.levi.pocketdj.studio.engine.SampleRenderCache]
 * in StudioGraph and faked in JVM tests.
 */
interface StudioPrepareBackend {
    /** Edited-sample render cache refresh (no-op for a neutral edit). Returns false when the source is gone. */
    suspend fun ensureSampleRendered(sampleId: String): Boolean

    /** Decode a sample/loop target into a canonical buffer (loops trimmed/padded to their exact frames), or null. */
    suspend fun targetBuffer(targetId: String): PcmBuffer?

    /** Pre-stretch the span variants (degraded fallback: absent key = natural buffer). */
    suspend fun stretchSpans(pattern: StudioPattern, natural: Map<String, PcmBuffer>): Map<com.levi.pocketdj.studio.engine.StudioStretchKey, PcmBuffer>

    /** Write the pattern bounce into the app-managed sequences root. Returns the written file name, or null if no writable root. */
    suspend fun bouncePattern(
        pattern: StudioPattern, buffers: Map<String, PcmBuffer>,
        spans: Map<com.levi.pocketdj.studio.engine.StudioStretchKey, PcmBuffer>,
    ): String?

    /**
     * Render a stale instrumental take (notes -> audio). Android has no instrument synth in this build:
     * the default returns false and the take falls back to its raw file.
     */
    suspend fun renderTake(takeId: String): Boolean = false
}

/**
 * Collections-side Studio playback (iOS `StudioStore.localURLForPlayback` + `StudioPatternBouncer.ensureBounced`
 * + `StudioTakeRenderer.ensureRendered`): resolves a studio id to a local file, preparing it on demand so a
 * freshly-added dirty sequence / edited sample / stale take plays the moment it is in a collection instead of
 * silently skipping ("couldn't play until I bounced it").
 */
class StudioPlayback(
    private val store: StudioStore,
    private val backend: StudioPrepareBackend,
) {
    private val lock = Mutex()

    /** No-prepare resolution (cheap; used by the "is this row on the device" probe). */
    fun playableNow(id: String): StudioPlayable? = store.localUrlForPlayback(id)

    /** True when [id] can play now OR could after [prepare] (record exists with something to render). */
    fun isPlayable(id: String): Boolean {
        if (playableNow(id) != null) return true
        return when {
            id.startsWith("ptn_") -> store.pattern(id)?.let { it.hasSoundingSteps } == true
            id.startsWith("smp_") -> store.sample(id) != null
            id.startsWith("tk_") -> store.take(id) != null
            else -> false
        }
    }

    /** Prepare [id] (bounce / render when stale) then resolve it. Never throws except cancellation. */
    suspend fun prepare(id: String): StudioPlayable? {
        playableNow(id)?.let { if (!needsPrepare(id)) return it }
        lock.withLock {
            try {
                when {
                    id.startsWith("smp_") -> backend.ensureSampleRendered(id)
                    id.startsWith("ptn_") -> ensureBounced(id)
                    id.startsWith("tk_") -> store.take(id)?.let { if (!it.isRenderFresh) backend.renderTake(id) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // degrade to whatever resolves (raw file / nothing): a broken render never crashes the set
            }
        }
        return playableNow(id)
    }

    /** A fresh pattern bounce / fresh sample render needs no work. */
    private fun needsPrepare(id: String): Boolean = when {
        id.startsWith("ptn_") -> store.pattern(id)?.let { it.fileName == null || it.bounceDirty } ?: false
        id.startsWith("smp_") -> store.sample(id)?.let { !it.edit.isNeutral && !it.isRenderFresh } ?: false
        id.startsWith("tk_") -> store.take(id)?.let { !it.isRenderFresh && it.events.isNotEmpty() } ?: false
        else -> false
    }

    private suspend fun ensureBounced(patternId: String) {
        val pattern = store.pattern(patternId) ?: return
        if (pattern.fileName != null && !pattern.bounceDirty) return
        val buffers = LinkedHashMap<String, PcmBuffer>()
        for (row in pattern.rows.take(PatternMath.MAX_PATTERN_ROWS)) {
            if (row.isSilent || row.targetId in buffers || !store.targetExists(row.targetId)) continue
            backend.targetBuffer(row.targetId)?.let { buffers[row.targetId] = it }
        }
        if (buffers.isEmpty()) return   // nothing sounding -> nothing to bounce
        val spans = backend.stretchSpans(pattern, buffers)
        val name = try {
            backend.bouncePattern(pattern, buffers, spans)
        } catch (e: PatternBounceException) {
            null
        } ?: return
        // Bless the bounce only if the pattern still matches what was rendered (an edit mid-render left it stale).
        val now = store.pattern(patternId)
        if (now != null && now.rows == pattern.rows && now.bpm == pattern.bpm) store.setPatternBounced(patternId, name, false)
    }

    /** The Collections lookup: title + REAL length (+ bpm/key) for a studio id, or null. */
    fun lookup(): StudioLookup = StudioLookup { id -> infoFor(id) }

    fun infoFor(id: String): StudioItemInfo? {
        val d = store.displayInfo(id) ?: return null
        val mix = store.mixInfo(id)
        return StudioItemInfo(
            title = d.title, lengthMs = d.lengthMs, bpm = d.bpm ?: mix?.bpm, camelot = mix?.camelot, kindLabel = d.kindLabel,
        )
    }

    companion object {
        /** `pattern-<id>.m4a` for a pattern (the one minting point). */
        fun patternFileName(patternId: String): String = StudioFolders.fileName(StudioFamily.SEQUENCES, patternId)

        /** Loop buffers play at their EXACT frame count (seamless): trim/pad the decoded file to it. */
        fun exactLoopBuffer(decoded: PcmBuffer, frames: Long): PcmBuffer =
            if (frames > 0) StudioAudio.trimmedOrPadded(decoded, frames) ?: decoded else decoded
    }
}
