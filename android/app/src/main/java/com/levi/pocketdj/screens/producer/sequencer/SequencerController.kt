package com.levi.pocketdj.screens.producer.sequencer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.engine.PatternBounceException
import com.levi.pocketdj.studio.engine.PatternBouncer
import com.levi.pocketdj.studio.engine.PatternMath
import com.levi.pocketdj.studio.engine.StudioStretchKey
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * The sequencer's playback preparation + bounce driver (the non-view half of iOS SequencerEditor): resolves each
 * row's target to a canonical PCM buffer, pre-stretches span variants (deduped on [StudioStretchKey]), hands the set
 * to the [com.levi.pocketdj.studio.engine.PatternEngine] and starts it. Missing targets and unreadable files are
 * SKIPPED with an advisory [notice] (never a throw); only a fully-empty result blocks playback. State is Compose state
 * so the editor re-renders; all engine calls happen on [scope] (Main).
 */
class SequencerController(private val graph: AppGraph, private val scope: CoroutineScope) {
    private val sg get() = graph.studioGraph
    private val store get() = sg.studioStore

    /** Inline advisory line (skipped rows, bounce results). Never a dialog. */
    var notice by mutableStateOf<String?>(null)
    /** Row buffers are decoding/rendering ahead of play: Play shows a spinner and is disabled. */
    var preparing by mutableStateOf(false)
    var bouncing by mutableStateOf(false)

    private var prepJob: Job? = null
    /** Pairs each prepare run with ITS `preparing` flag: a cancelled run's cleanup must not clobber its replacement. */
    private var prepGeneration = 0

    fun cancelPrepare() { prepJob?.cancel() }

    private fun rowTitle(targetId: String) = store.displayInfo(targetId)?.title ?: "Untitled"

    /**
     * Resolve ONE target id to the canonical PCM the engine schedules: loops decode then trim/pad to the loop's
     * AUTHORITATIVE frames (a +-1-frame seam retriggers off-beat); samples ensure a FRESH render cache first (bakes
     * edits when stale, falls back to the raw capture) and decode that. Null when unreachable/unreadable.
     */
    suspend fun preparedBuffer(targetId: String): PcmBuffer? {
        try {
            if (targetId.startsWith("lp_")) {
                val loop = store.loop(targetId) ?: return null
                val file = store.localUrlForPlayback(targetId)?.ref?.file ?: return null
                val decoded = sg.studioRender.decodeBuffer(file.path)
                return if (loop.frames > 0) StudioAudio.trimmedOrPadded(decoded, loop.frames) else decoded
            }
            if (targetId.startsWith("smp_")) {
                val file = sg.sampleRenderCache.playableFile(targetId) ?: return null
                return sg.studioRender.decodeBuffer(file.path)
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) { return null }
        return null
    }

    /** Solo-preview ONE row (SEQ1): only that row's steps, looping at the pattern BPM; re-tapping it stops. */
    fun toggleSolo(patternId: String, i: Int, startStep: Int, loopEnabled: Boolean, loopBars: Int) {
        val eng = sg.patternEngine
        if (eng.loadedPatternId.value == patternId && eng.isPlaying.value && eng.soloedRow.value == i) { eng.stopPattern(); return }
        val pattern = store.pattern(patternId) ?: return
        val row = pattern.rows.getOrNull(i) ?: return
        if (row.isSilent) { notice = "This row has no steps to preview — add a step first."; return }
        if (!store.targetExists(row.targetId)) { notice = "This row's sample or loop was removed."; return }
        beginPrepare { gen ->
            val natural = preparedBuffer(row.targetId)
            if (natural == null) { if (gen == prepGeneration) notice = "Couldn't prepare audio for ${rowTitle(row.targetId)}."; return@beginPrepare }
            val spans = HashMap<Int, PcmBuffer>()
            val stepF = PatternMath.stepFrames(pattern.bpm)
            for (col in row.steps.indices) {
                val span = PatternMath.spanAt(row, col)
                if (span > 0 && span !in spans) runCatching { sg.studioRender.stretchBuffer(natural, stepF * span) }.getOrNull()?.let { spans[span] = it }
            }
            if (gen != prepGeneration) return@beginPrepare
            val eng2 = sg.patternEngine
            eng2.loadPattern(pattern, mapOf(i to natural), mapOf(i to spans), soloedRow = i, startStep = startStep, loopEnabled = loopEnabled, loopBars = loopBars)
            if (!eng2.startPattern()) notice = refusalText(eng2.lastRefusal)
        }
    }

    /** Prepare every sounding row's buffer, then load + start the full pattern. */
    fun startPlayback(pattern: StudioPattern, startStep: Int, loopEnabled: Boolean, loopBars: Int) {
        beginPrepare { gen ->
            val buffers = HashMap<Int, PcmBuffer>()
            val skipped = ArrayList<String>()
            pattern.rows.take(PatternMath.MAX_PATTERN_ROWS).forEachIndexed { i, row ->
                if (gen != prepGeneration) return@beginPrepare
                if (row.isSilent) return@forEachIndexed                      // no on-steps: decode is wasted work
                if (!store.targetExists(row.targetId)) return@forEachIndexed // missing row: muted by design
                val buf = preparedBuffer(row.targetId)
                if (buf != null) buffers[i] = buf else skipped += rowTitle(row.targetId)
            }
            if (gen != prepGeneration) return@beginPrepare
            if (buffers.isEmpty()) {
                notice = if (skipped.isEmpty()) "Nothing can sound — every active row's target was removed." else "Couldn't prepare audio for: ${skipped.joinToString(", ")}."
                return@beginPrepare
            }
            if (skipped.isNotEmpty()) notice = "Skipped (audio unavailable): ${skipped.joinToString(", ")}."
            // Pre-stretch every span variant an on-step demands, deduped by target+span; a failed stretch falls back to natural.
            val stepF = PatternMath.stepFrames(pattern.bpm)
            val cache = HashMap<StudioStretchKey, PcmBuffer?>()
            val spanBuffers = HashMap<Int, MutableMap<Int, PcmBuffer>>()
            pattern.rows.take(PatternMath.MAX_PATTERN_ROWS).forEachIndexed { i, row ->
                val natural = buffers[i] ?: return@forEachIndexed
                for (col in row.steps.indices) {
                    val span = PatternMath.spanAt(row, col)
                    if (span <= 0) continue
                    val key = StudioStretchKey(row.targetId, span)
                    if (key !in cache) cache[key] = try { sg.studioRender.stretchBuffer(natural, stepF * span) } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
                    cache[key]?.let { spanBuffers.getOrPut(i) { HashMap() }[span] = it }
                }
                if (gen != prepGeneration) return@beginPrepare
            }
            // Reload FRESH from the store (the user may have toggled steps while buffers rendered) but ONLY when the
            // prepared audio still fits: buffers hold the SNAPSHOT's targets and span buffers are fit to its bpm.
            val current = store.pattern(pattern.id) ?: pattern
            val compatible = current.bpm == pattern.bpm &&
                current.rows.map { it.targetId } == pattern.rows.map { it.targetId } &&
                current.rows.map { it.stepSpans } == pattern.rows.map { it.stepSpans }
            val eng = sg.patternEngine
            eng.loadPattern(if (compatible) current else pattern, buffers, spanBuffers, startStep = startStep, loopEnabled = loopEnabled, loopBars = loopBars)
            if (!eng.startPattern()) notice = refusalText(eng.lastRefusal)
        }
    }

    private fun beginPrepare(body: suspend (gen: Int) -> Unit) {
        prepJob?.cancel()
        prepGeneration += 1
        val gen = prepGeneration
        notice = null
        preparing = true
        prepJob = scope.launch {
            try { body(gen) } catch (e: CancellationException) { throw e } catch (e: Exception) { if (gen == prepGeneration) notice = "Couldn't prepare the pattern: ${e.message ?: "unknown error"}." }
            finally { if (gen == prepGeneration) preparing = false }
        }
    }

    private fun refusalText(r: String?) = when (r) {
        "mic-capture-active" -> "Playback is paused while the microphone is recording."
        "no-content" -> "Toggle steps to enable Play — an empty pattern is never played."
        "no-focus" -> "Another app is using the audio output."
        "output-unavailable" -> "The audio output couldn't be opened."
        else -> "Couldn't start the pattern."
    }

    /** Overflow Bounce: pre-render row buffers keyed by TARGET id and write the one-pass `pattern-<id>.m4a`. */
    fun bounce(pattern: StudioPattern) {
        if (bouncing) return
        notice = null
        bouncing = true
        scope.launch {
            try {
                val buffers = HashMap<String, PcmBuffer>()
                for (row in pattern.rows.take(PatternMath.MAX_PATTERN_ROWS)) {
                    if (row.isSilent || !store.targetExists(row.targetId) || row.targetId in buffers) continue   // dedupe: a sample on two rows decodes once
                    preparedBuffer(row.targetId)?.let { buffers[row.targetId] = it }
                }
                if (buffers.isEmpty()) { notice = "Nothing to bounce — no active row has playable audio."; return@launch }
                val name = StudioFolders.fileName(StudioFamily.SEQUENCES, pattern.id)
                val dest = StudioFiles.appFile(sg.studioRoots, StudioFamily.SEQUENCES, name)
                if (dest == null) { notice = "Bounce failed — the sequences folder is unavailable."; return@launch }
                val spans = PatternBouncer.stretchSpanBuffers(pattern, buffers) { b, f -> sg.studioRender.stretchBuffer(b, f) }
                PatternBouncer.bounce(pattern, buffers, spans, dest)
                // Bless the bounce ONLY if the pattern still matches what was rendered.
                val now = store.pattern(pattern.id)
                if (now != null && now.rows == pattern.rows && now.bpm == pattern.bpm) {
                    store.setPatternBounced(pattern.id, name, false)
                    notice = "Bounced — this pattern now plays offline in collections."
                } else notice = "Bounced, but the pattern changed while rendering — bounce again to refresh."
            } catch (e: CancellationException) { throw e }
            catch (e: PatternBounceException) { notice = "Nothing to bounce — no active row has playable audio." }
            catch (e: Exception) { notice = "Bounce failed: ${e.message ?: "unknown error"}" }
            finally { bouncing = false }
        }
    }
}
