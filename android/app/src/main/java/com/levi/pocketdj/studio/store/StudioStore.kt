package com.levi.pocketdj.studio.store

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioCue
import com.levi.pocketdj.studio.model.StudioCueDoc
import com.levi.pocketdj.studio.model.StudioDocument
import com.levi.pocketdj.studio.model.STUDIO_SCHEMA_VERSION
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioFolder
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioMasterFX
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.model.StudioSlice
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.model.StudioTakeStaff
import com.levi.pocketdj.studio.model.StudioClipSource
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Debounce seam: runs [task] after [delayMs]; the returned lambda cancels it. Injectable for tests. */
fun interface StudioScheduler {
    fun schedule(delayMs: Long, task: () -> Unit): () -> Unit
}

/** Production scheduler: one daemon thread. */
class ExecutorStudioScheduler(
    private val ex: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "pdj-studio-debounce").apply { isDaemon = true }
    },
) : StudioScheduler {
    override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
        val f: ScheduledFuture<*> = ex.schedule({ runCatching(task) }, delayMs, TimeUnit.MILLISECONDS)
        return { f.cancel(false) }
    }
}

/** The five flat-folder families (membership by each item's optional `folderId`; nil = Unfiled). */
enum class StudioFolderKind { SAMPLE, LOOP, PATTERN, TAKE, ARRANGEMENT }

/** What a sample/loop deletion would leave behind (the delete confirmation reads this). */
data class StudioReferrers(val loopCount: Int, val patternRowCount: Int)

/** A playable studio id resolved to a local file. */
data class StudioPlayable(val ref: StudioFileRef, val title: String, val lengthMs: Int)

data class StudioMixInfo(val bpm: Double?, val firstDownbeatMs: Int, val beatsMs: List<Int>?, val camelot: String?)
data class StudioDisplayInfo(val title: String, val lengthMs: Int, val bpm: Double?, val kindLabel: String)

/**
 * The Studio document store — samples, loops, sequencer patterns, instrument takes, cues, slices,
 * folders and arrangements (iOS `StudioStore`). Persists `pocketdj-studio.json` (schema v1,
 * iOS-key-compatible) through the program-wide [VersionedJsonWriter] (atomic temp+rename,
 * version-ordered, off-main via [executor]; [flush] is synchronous) plus the media-free cue
 * mirror `pocketdj-studio.cues.json`, the ONLY Studio data that ever leaves the device.
 *
 * This store persists; it never renders or plays. Engines write files and hand records here.
 * Dangling cross-references (a loop's deleted parent sample, a pattern row's deleted target) are
 * FLAGGED via [sampleExists]/[targetExists], never deleted.
 *
 * Thread-safe: every mutation serializes on one lock; readers observe the immutable [state].
 */
class StudioStore(
    private val file: File,
    private val roots: StudioRoots,
    executor: Executor = VersionedJsonWriter.DIRECT,
    private val scheduler: StudioScheduler = StudioScheduler { _, _ -> {} },
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    private val lock = Any()
    private val writer = VersionedJsonWriter(file, executor)
    private val cuesFile: File = cuesFileFor(file)
    private val cueWriter = VersionedJsonWriter(cuesFile, executor)

    private var saveVersion = 0L
    private var cueVersion = 0L
    private var cancelSave: (() -> Unit)? = null
    private var cancelCueSave: (() -> Unit)? = null
    private var cueMirrorDirty = false

    private val _state = MutableStateFlow(load())
    /** The whole document, immutable snapshots; UI observes this. */
    val state: StateFlow<StudioDocument> = _state.asStateFlow()
    val doc: StudioDocument get() = _state.value

    /** The mic/instrument recorder's IN-FLIGHT capture file name (skipped by [deleteAll]). */
    @Volatile var activeTakeFileName: (() -> String?)? = null

    /** Fired ONCE for each NEWLY created sample (never on an upsert / crash-retry re-file). */
    @Volatile var onSampleAdded: ((StudioSample) -> Unit)? = null

    val samples get() = doc.samples
    val loops get() = doc.loops
    val patterns get() = doc.patterns
    val takes get() = doc.takes
    val cues get() = doc.cues
    val slices get() = doc.slices
    val arrangements get() = doc.arrangements
    val arrangementArtifacts get() = doc.arrangementArtifacts

    /** The cue mirror file (the profile-sync entry points here). */
    val cueSyncFile: File get() = cuesFile

    // ------------------------------------------------------------------------------------------
    // Load
    // ------------------------------------------------------------------------------------------

    private fun load(): StudioDocument {
        if (!file.exists()) return StudioDocument()
        val text = try { file.readText() } catch (_: Exception) { return StudioDocument() }
        StudioDocument.decode(text)?.let { return it }
        // Not even a JSON object: quarantine the bytes instead of silently overwriting them.
        if (text.isNotBlank()) runCatching { file.copyTo(File(file.parentFile, file.name + ".bak"), overwrite = true) }
        return StudioDocument()
    }

    // ------------------------------------------------------------------------------------------
    // Persistence plumbing
    // ------------------------------------------------------------------------------------------

    /** Replace the document and persist: debounced for slider streams, immediate otherwise. */
    private fun commit(next: StudioDocument, stream: Boolean = false) {
        _state.value = next
        if (stream) scheduleSave() else saveNow()
    }

    private inline fun mutate(stream: Boolean = false, f: (StudioDocument) -> StudioDocument?) = synchronized(lock) {
        val next = f(_state.value) ?: return@synchronized
        commit(next, stream)
    }

    private fun saveNow() {
        cancelSave?.invoke(); cancelSave = null
        val v = ++saveVersion
        val snap = _state.value
        writer.write(v) { snap.copy(schemaVersion = STUDIO_SCHEMA_VERSION).encode() }
    }

    private fun scheduleSave() {
        cancelSave?.invoke()
        cancelSave = scheduler.schedule(SAVE_DEBOUNCE_MS) { synchronized(lock) { cancelSave = null; saveNow() } }
    }

    private fun writeCueMirror() {
        cueMirrorDirty = false
        val snap = StudioCueDoc(STUDIO_CUE_VERSION, _state.value.cues)
        cueWriter.write(++cueVersion) { snap.encode() }
    }

    private fun saveCuesNow() { saveNow(); writeCueMirror() }

    private fun scheduleCueSave() {
        cueMirrorDirty = true
        cancelCueSave?.invoke()
        cancelCueSave = scheduler.schedule(SAVE_DEBOUNCE_MS) {
            synchronized(lock) { cancelCueSave = null; saveNow(); writeCueMirror() }
        }
    }

    /**
     * Force-persist now (ON_STOP / quit). Writes SYNCHRONOUSLY on the caller's thread and raises
     * the writer floor so queued stragglers are dropped. A pending debounced cue nudge is
     * mirrored too — only when a cue change is actually pending (never on a non-cue flush, so no
     * spurious sync push).
     */
    fun flush() = synchronized(lock) {
        cancelSave?.invoke(); cancelSave = null
        cancelCueSave?.invoke(); cancelCueSave = null
        val v = ++saveVersion
        val snap = _state.value
        writer.flushNow(v) { snap.copy(schemaVersion = STUDIO_SCHEMA_VERSION).encode() }
        if (cueMirrorDirty) {
            cueMirrorDirty = false
            val cv = ++cueVersion
            val cdoc = StudioCueDoc(STUDIO_CUE_VERSION, snap.cues)
            cueWriter.flushNow(cv) { cdoc.encode() }
        }
    }

    /** Test/diagnostic barrier: everything queued has been applied. */
    fun awaitIdle() { writer.awaitIdle(); cueWriter.awaitIdle() }

    private val nowMs: Double get() = now()

    private fun String.trimmedOrNull(): String? = trim().takeIf { it.isNotEmpty() }

    // ------------------------------------------------------------------------------------------
    // File helpers (resolve against the root a record was WRITTEN to)
    // ------------------------------------------------------------------------------------------

    private fun fileRef(family: StudioFamily, fileName: String, wasUser: Boolean) =
        StudioFolders.fileRef(roots, family, fileName, wasUser)

    /** Best-effort delete of one artifact from the root it lives in. */
    private fun deleteArtifact(family: StudioFamily, fileName: String, wasUser: Boolean) {
        if (!StudioFolders.isBareName(fileName)) return
        val dir = if (wasUser) roots.userDir(family) else roots.appDir(family)
        dir?.delete(fileName)
    }

    /**
     * Delete a record's raw file. false when the user root that held it is unreachable (record
     * must be KEPT — dropping it without deleting the file would orphan the file forever).
     */
    private fun deleteRaw(family: StudioFamily, fileName: String, wasUser: Boolean): Boolean {
        if (wasUser && !StudioFolders.userRootReachable(roots, family)) return false
        deleteArtifact(family, fileName, wasUser)
        return true
    }

    // ------------------------------------------------------------------------------------------
    // Samples
    // ------------------------------------------------------------------------------------------

    fun sample(id: String): StudioSample? = doc.samples.firstOrNull { it.id == id }
    fun sampleExists(id: String): Boolean = sample(id) != null

    /** Samples sorted by name (case-insensitive) — the sequencer retarget menu order. */
    val samplesByName: List<StudioSample> get() = doc.samples.sortedWith(byName { it.name })
    val loopsByName: List<StudioLoop> get() = doc.loops.sortedWith(byName { it.name })

    /** File a sample record (audio already on disk). Upserts by id so a crash-retry never duplicates. */
    fun addSample(sample: StudioSample): StudioSample {
        var isNew = false
        synchronized(lock) {
            val cur = _state.value
            val i = cur.samples.indexOfFirst { it.id == sample.id }
            isNew = i < 0
            commit(cur.copy(samples = if (i >= 0) cur.samples.replaced(i, sample) else cur.samples + sample))
        }
        if (isNew) onSampleAdded?.invoke(sample)
        return sample
    }

    fun renameSample(id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        updateSample(id) { it.copy(name = n) }
    }

    /** Grid changes do NOT bump renderRevision — the render bakes EDITS, not the grid. */
    fun setSampleGrid(id: String, grid: StudioGrid?) = updateSample(id) { it.copy(grid = grid) }

    /**
     * Update a sample's edit. Clamped; [StudioSample.renderRevision] bumps exactly when the clamped
     * value actually changed (the render-cache freshness stamp). Debounced save (slider-streamed).
     */
    fun updateSampleEdit(id: String, edit: StudioSampleEdit) =
        updateSample(id, stream = true) { s ->
            val c = edit.clamped()
            if (s.edit == c) null else s.copy(edit = c, renderRevision = s.renderRevision + 1)
        }

    /** A finished render cache (edits baked at [revision]); fresh only while revision == renderRevision. */
    fun setRenderedSample(id: String, fileName: String, wasUserFolder: Boolean, revision: Int) =
        updateSample(id) { it.copy(renderedFileName = fileName, renderedRevision = revision, renderedWasUserFolder = wasUserFolder) }

    fun setSampleKey(id: String, camelot: String?) = setCamelot(camelot, id)

    private fun updateSample(id: String, stream: Boolean = false, f: (StudioSample) -> StudioSample?) =
        mutate(stream) { d ->
            val i = d.samples.indexOfFirst { it.id == id }
            if (i < 0) return@mutate null
            val next = f(d.samples[i]) ?: return@mutate null
            d.copy(samples = d.samples.replaced(i, next))
        }

    /** Loops sliced from [targetId] and pattern rows targeting it (works for loop ids too). */
    fun referrers(targetId: String): StudioReferrers {
        val d = doc
        return StudioReferrers(
            d.loops.count { it.sampleId == targetId },
            d.patterns.sumOf { p -> p.rows.count { it.targetId == targetId } },
        )
    }

    /**
     * Delete a sample: raw file, render cache (best-effort), slices and record. Referencing loops
     * and pattern rows are NEVER touched. false — record kept, nothing deleted — when the raw
     * file's user root is unreachable right now.
     */
    fun deleteSample(id: String): Boolean = synchronized(lock) {
        val d = _state.value
        val s = d.samples.firstOrNull { it.id == id } ?: return false
        if (!deleteRaw(StudioFamily.SAMPLES, s.fileName, s.wasUserFolder)) return false
        s.renderedFileName?.let { deleteArtifact(StudioFamily.SAMPLES, it, s.renderedWasUserFolder ?: false) }
        commit(d.copy(samples = d.samples.filterNot { it.id == id }, slices = d.slices.filterNot { it.sampleId == id }))
        true
    }

    // ------------------------------------------------------------------------------------------
    // Folders (flat, device-local; membership via each item's folderId)
    // ------------------------------------------------------------------------------------------

    private fun StudioDocument.foldersOf(kind: StudioFolderKind): List<StudioFolder> = when (kind) {
        StudioFolderKind.SAMPLE -> folders
        StudioFolderKind.LOOP -> loopFolders
        StudioFolderKind.PATTERN -> patternFolders
        StudioFolderKind.TAKE -> takeFolders
        StudioFolderKind.ARRANGEMENT -> arrangementFolders
    }

    private fun StudioDocument.withFolders(kind: StudioFolderKind, xs: List<StudioFolder>): StudioDocument = when (kind) {
        StudioFolderKind.SAMPLE -> copy(folders = xs)
        StudioFolderKind.LOOP -> copy(loopFolders = xs)
        StudioFolderKind.PATTERN -> copy(patternFolders = xs)
        StudioFolderKind.TAKE -> copy(takeFolders = xs)
        StudioFolderKind.ARRANGEMENT -> copy(arrangementFolders = xs)
    }

    private fun mintFolderId(kind: StudioFolderKind) = when (kind) {
        StudioFolderKind.SAMPLE -> StudioFactory.newSampleFolderId()
        StudioFolderKind.LOOP -> StudioFactory.newLoopFolderId()
        StudioFolderKind.PATTERN -> StudioFactory.newPatternFolderId()
        StudioFolderKind.TAKE -> StudioFactory.newTakeFolderId()
        StudioFolderKind.ARRANGEMENT -> StudioFactory.newArrangementFolderId()
    }

    fun folder(kind: StudioFolderKind, id: String): StudioFolder? = doc.foldersOf(kind).firstOrNull { it.id == id }

    fun foldersOrdered(kind: StudioFolderKind): List<StudioFolder> = doc.foldersOf(kind).sortedWith(byName { it.name })

    fun createFolder(kind: StudioFolderKind, name: String): StudioFolder = synchronized(lock) {
        val t = nowMs
        val f = StudioFolder(mintFolderId(kind), name.trim(), t, t)
        val d = _state.value
        commit(d.withFolders(kind, d.foldersOf(kind) + f))
        f
    }

    fun renameFolder(kind: StudioFolderKind, id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        mutate { d ->
            val xs = d.foldersOf(kind)
            val i = xs.indexOfFirst { it.id == id }
            if (i < 0) null else d.withFolders(kind, xs.replaced(i, xs[i].copy(name = n, updatedAt = nowMs)))
        }
    }

    /** Delete a folder; members are re-homed to Unfiled (NEVER deleted — contrast deleteArrangement). */
    fun deleteFolder(kind: StudioFolderKind, id: String) = mutate { d ->
        val d2 = d.withFolders(kind, d.foldersOf(kind).filterNot { it.id == id })
        when (kind) {
            StudioFolderKind.SAMPLE -> d2.copy(samples = d2.samples.map { if (it.folderId == id) it.copy(folderId = null) else it })
            StudioFolderKind.LOOP -> d2.copy(loops = d2.loops.map { if (it.folderId == id) it.copy(folderId = null) else it })
            StudioFolderKind.PATTERN -> d2.copy(patterns = d2.patterns.map { if (it.folderId == id) it.copy(folderId = null) else it })
            StudioFolderKind.TAKE -> d2.copy(takes = d2.takes.map { if (it.folderId == id) it.copy(folderId = null) else it })
            StudioFolderKind.ARRANGEMENT -> d2.copy(arrangements = d2.arrangements.map { if (it.folderId == id) it.copy(folderId = null) else it })
        }
    }

    /** Move one item into [folderId] (null = Unfiled). Metadata only — no audio file is touched. */
    fun setItemFolder(kind: StudioFolderKind, itemId: String, folderId: String?) = mutate { d ->
        when (kind) {
            StudioFolderKind.SAMPLE -> d.samples.indexOfFirst { it.id == itemId }.takeIf { it >= 0 }
                ?.let { i -> d.copy(samples = d.samples.replaced(i, d.samples[i].copy(folderId = folderId))) }
            StudioFolderKind.LOOP -> d.loops.indexOfFirst { it.id == itemId }.takeIf { it >= 0 }
                ?.let { i -> d.copy(loops = d.loops.replaced(i, d.loops[i].copy(folderId = folderId))) }
            StudioFolderKind.PATTERN -> d.patterns.indexOfFirst { it.id == itemId }.takeIf { it >= 0 }
                ?.let { i -> d.copy(patterns = d.patterns.replaced(i, d.patterns[i].copy(folderId = folderId))) }
            StudioFolderKind.TAKE -> d.takes.indexOfFirst { it.id == itemId }.takeIf { it >= 0 }
                ?.let { i -> d.copy(takes = d.takes.replaced(i, d.takes[i].copy(folderId = folderId))) }
            StudioFolderKind.ARRANGEMENT -> d.arrangements.indexOfFirst { it.id == itemId }.takeIf { it >= 0 }
                ?.let { i -> d.copy(arrangements = d.arrangements.replaced(i, d.arrangements[i].copy(folderId = folderId, updatedAt = nowMs))) }
        }
    }

    /** True when [folderId] names a folder that exists (a dangling id reads as Unfiled). */
    private fun inFolder(known: Set<String>, folderId: String?, want: String?): Boolean =
        if (folderId != null && folderId in known) folderId == want else want == null

    fun samples(inFolder: String?): List<StudioSample> {
        val d = doc; val known = d.folders.map { it.id }.toSet()
        return d.samples.filter { inFolder(known, it.folderId, inFolder) }.sortedByDescending { it.createdAt }
    }

    fun loops(inFolder: String?): List<StudioLoop> {
        val d = doc; val known = d.loopFolders.map { it.id }.toSet()
        return d.loops.filter { inFolder(known, it.folderId, inFolder) }.sortedByDescending { it.createdAt }
    }

    fun patterns(inFolder: String?): List<StudioPattern> {
        val d = doc; val known = d.patternFolders.map { it.id }.toSet()
        return d.patterns.filter { inFolder(known, it.folderId, inFolder) }.sortedByDescending { it.createdAt }
    }

    fun takes(inFolder: String?): List<StudioTake> {
        val d = doc; val known = d.takeFolders.map { it.id }.toSet()
        return d.takes.filter { inFolder(known, it.folderId, inFolder) }.sortedByDescending { it.createdAt }
    }

    fun arrangements(inFolder: String?): List<StudioArrangement> {
        val d = doc; val known = d.arrangementFolders.map { it.id }.toSet()
        return d.arrangements.filter { inFolder(known, it.folderId, inFolder) }.sortedByDescending { it.createdAt }
    }

    // ------------------------------------------------------------------------------------------
    // Loops
    // ------------------------------------------------------------------------------------------

    fun loop(id: String): StudioLoop? = doc.loops.firstOrNull { it.id == id }

    fun addLoop(loop: StudioLoop): StudioLoop {
        mutate { d ->
            val i = d.loops.indexOfFirst { it.id == loop.id }
            d.copy(loops = if (i >= 0) d.loops.replaced(i, loop) else d.loops + loop)
        }
        return loop
    }

    fun renameLoop(id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        mutate { d ->
            val i = d.loops.indexOfFirst { it.id == id }
            if (i < 0) null else d.copy(loops = d.loops.replaced(i, d.loops[i].copy(name = n)))
        }
    }

    /** false (record kept) when the loop's user root is unreachable. Loops survive parent deletion. */
    fun deleteLoop(id: String): Boolean = synchronized(lock) {
        val d = _state.value
        val l = d.loops.firstOrNull { it.id == id } ?: return false
        if (!deleteRaw(StudioFamily.LOOPS, l.fileName, l.wasUserFolder)) return false
        commit(d.copy(loops = d.loops.filterNot { it.id == id }))
        true
    }

    /** A sample or loop with this id exists (pattern rows whose target is gone are "missing"). */
    fun targetExists(id: String): Boolean = sample(id) != null || loop(id) != null

    // ------------------------------------------------------------------------------------------
    // Patterns (sequencer)
    // ------------------------------------------------------------------------------------------

    fun pattern(id: String): StudioPattern? = doc.patterns.firstOrNull { it.id == id }

    fun addPattern(pattern: StudioPattern): StudioPattern {
        mutate { d ->
            val i = d.patterns.indexOfFirst { it.id == pattern.id }
            d.copy(patterns = if (i >= 0) d.patterns.replaced(i, pattern) else d.patterns + pattern)
        }
        return pattern
    }

    fun renamePattern(id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        updatePattern(id) { it.copy(name = n) }
    }

    private fun updatePattern(id: String, stream: Boolean = false, f: (StudioPattern) -> StudioPattern) =
        mutate(stream) { d ->
            val i = d.patterns.indexOfFirst { it.id == id }
            if (i < 0) null else d.copy(patterns = d.patterns.replaced(i, f(d.patterns[i])))
        }

    /** The one door for sequencer edits: applies [f] and re-marks `bounceDirty` (a stale bounce is never played). */
    fun mutatePattern(id: String, f: (StudioPattern) -> StudioPattern) =
        updatePattern(id) { f(it).copy(bounceDirty = true) }

    private fun StudioPattern.mapRow(row: Int, f: (StudioPatternRow) -> StudioPatternRow): StudioPattern =
        if (row !in rows.indices) this else copy(rows = rows.replaced(row, f(rows[row])))

    private fun <T> List<T>.with(i: Int, v: T): List<T> = toMutableList().also { it[i] = v }

    fun setPatternStep(id: String, row: Int, col: Int, on: Boolean) {
        val sc = pattern(id)?.stepCount ?: return
        if (col !in 0 until sc) return
        mutatePattern(id) { p ->
            p.mapRow(row) { r ->
                // A cleared step sheds its trigger modes, so re-enabling starts one-shot.
                if (on) r.copy(steps = r.steps.with(col, true))
                else r.copy(steps = r.steps.with(col, false), loopSteps = r.loopSteps.with(col, false), stepSpans = r.stepSpans.with(col, 0))
            }
        }
    }

    fun setPatternStepLoop(id: String, row: Int, col: Int, loop: Boolean) {
        val sc = pattern(id)?.stepCount ?: return
        if (col !in 0 until sc) return
        mutatePattern(id) { p -> p.mapRow(row) { it.copy(loopSteps = it.loopSteps.with(col, loop)) } }
    }

    fun setPatternStepSpan(id: String, row: Int, col: Int, span: Int) {
        val sc = pattern(id)?.stepCount ?: return
        if (col !in 0 until sc) return
        mutatePattern(id) { p -> p.mapRow(row) { it.copy(stepSpans = it.stepSpans.with(col, span.coerceIn(0, p.stepCount))) } }
    }

    /** Lane label (does not dirty the bounce — a label is not audio). */
    fun setPatternRowLabel(id: String, row: Int, label: String?) {
        val t = label?.trim()?.takeIf { it.isNotEmpty() }
        updatePattern(id) { p -> p.mapRow(row) { it.copy(label = t) } }
    }

    fun setPatternRowTarget(id: String, row: Int, targetId: String) {
        if (targetId.isEmpty()) return
        mutatePattern(id) { p -> p.mapRow(row) { it.copy(targetId = targetId) } }
    }

    fun setPatternBpm(id: String, bpm: Double) {
        if (!(bpm > 0)) return
        mutatePattern(id) { it.copy(bpm = bpm) }
    }

    fun addPatternRow(id: String, targetId: String) =
        mutatePattern(id) { it.copy(rows = it.rows + StudioPatternRow.of(targetId).resized(it.stepCount)) }

    fun removePatternRow(id: String, row: Int) =
        mutatePattern(id) { p -> if (row in p.rows.indices) p.copy(rows = p.rows.filterIndexed { i, _ -> i != row }) else p }

    fun setPatternStepCount(id: String, count: Int) =
        mutatePattern(id) { p ->
            val n = StudioPattern.clampStepCount(count)
            if (n == p.stepCount) p else p.copy(stepCount = n, rows = p.rows.map { it.resized(n) })
        }

    /** Row gain is slider-driven: debounced save, bounce dirtied. */
    fun setPatternRowGain(id: String, row: Int, gainDb: Double) =
        updatePattern(id, stream = true) { p -> p.mapRow(row) { it.copy(gainDb = gainDb) }.copy(bounceDirty = true) }

    fun setPatternBounced(id: String, fileName: String, wasUserFolder: Boolean) =
        updatePattern(id) { it.copy(fileName = fileName, wasUserFolder = wasUserFolder, bounceDirty = false) }

    fun deletePattern(id: String): Boolean = synchronized(lock) {
        val d = _state.value
        val p = d.patterns.firstOrNull { it.id == id } ?: return false
        p.fileName?.let { if (!deleteRaw(StudioFamily.SEQUENCES, it, p.wasUserFolder)) return false }
        commit(d.copy(patterns = d.patterns.filterNot { it.id == id }))
        true
    }

    // ------------------------------------------------------------------------------------------
    // Takes
    // ------------------------------------------------------------------------------------------

    fun take(id: String): StudioTake? = doc.takes.firstOrNull { it.id == id }

    fun addTake(take: StudioTake): StudioTake {
        mutate { d ->
            val i = d.takes.indexOfFirst { it.id == take.id }
            d.copy(takes = if (i >= 0) d.takes.replaced(i, take) else d.takes + take)
        }
        return take
    }

    /**
     * File a take, first MOVING its audio from app storage into the user instrumentals folder when
     * one is configured, reachable and writable (the recorder always writes the app root).
     * A failed move keeps app storage (`wasUserFolder` stays false).
     */
    fun addTakeRelocating(take: StudioTake): StudioTake {
        var t = take
        val (dest, isUser) = StudioFolders.writeFolder(roots, StudioFamily.TAKES)
        if (isUser) {
            val appDir = roots.appDir(StudioFamily.TAKES)
            val src = appDir.resolve(take.fileName)?.file
            if (src != null) {
                val ok = runCatching {
                    dest.openOutput(take.fileName)?.use { out -> src.inputStream().use { it.copyTo(out) } } != null
                }.getOrDefault(false) && dest.exists(take.fileName)
                if (ok) {
                    appDir.delete(take.fileName)
                    t = t.copy(wasUserFolder = true)
                } else {
                    dest.delete(take.fileName)   // never leave a half-written copy behind
                }
            }
        }
        return addTake(t)
    }

    private fun updateTake(id: String, f: (StudioTake) -> StudioTake?) = mutate { d ->
        val i = d.takes.indexOfFirst { it.id == id }
        if (i < 0) return@mutate null
        val next = f(d.takes[i]) ?: return@mutate null
        d.copy(takes = d.takes.replaced(i, next))
    }

    fun renameTake(id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        updateTake(id) { it.copy(name = n) }
    }

    private fun StudioTake.extendedTo(events: List<StudioNoteEvent>): StudioTake {
        val maxOff = events.maxOfOrNull { it.offMs }
        return if (maxOff != null && maxOff > durationMs) copy(durationMs = maxOff) else this
    }

    /** User-EDITED note stream; extends the duration, invalidates the rendered audio. */
    fun setTakeEvents(id: String, events: List<StudioNoteEvent>) =
        updateTake(id) { invalidateTakeRender(it.copy(editedEvents = events).extendedTo(events)) }

    fun setTakeDemuxMode(id: String, mode: String?) = updateTake(id) { it.copy(demuxMode = mode) }

    fun revertTakeEdits(id: String) =
        updateTake(id) { if (it.editedEvents == null) null else invalidateTakeRender(it.copy(editedEvents = null)) }

    fun setTakeInstrument(id: String, instrument: InstrumentKey) =
        updateTake(id) { if (it.instrument == instrument) null else invalidateTakeRender(it.copy(instrument = instrument)) }

    /** Retempo: rescales every note ms on EVERY staff (one score clock) and the duration. */
    fun setTakeTempo(id: String, newBpm: Double) = updateTake(id) { t ->
        val old = t.bpm
        val target = newBpm.coerceIn(20.0, 300.0)
        if (!(old > 0) || !(target > 0) || Math.abs(target - old) <= 0.01) return@updateTake null
        val scale = old / target
        fun rescale(e: StudioNoteEvent) = e.copy(
            onMs = Math.round(e.onMs * scale).toInt(), offMs = Math.round(e.offMs * scale).toInt(),
        )
        invalidateTakeRender(
            t.copy(
                events = t.events.map(::rescale),
                editedEvents = t.editedEvents?.map(::rescale),
                extraStaffs = t.extraStaffs?.map { s -> s.copy(events = s.events.map(::rescale), editedEvents = s.editedEvents?.map(::rescale)) },
                bpm = target,
                durationMs = Math.round(t.durationMs * scale).toInt(),
            ),
        )
    }

    // Overdub staffs (staffs 2..4).

    /** Add an overdub staff; null when empty or past the [StudioTake.MAX_STAFFS] cap. Returns the staff id. */
    fun addOverdubStaff(takeId: String, instrument: InstrumentKey, events: List<StudioNoteEvent>): String? =
        synchronized(lock) {
            val t = take(takeId) ?: return null
            if (events.isEmpty() || t.staffCount >= StudioTake.MAX_STAFFS) return null
            val staff = StudioTakeStaff(StudioFactory.newStaffId(), instrument, events, null, System.currentTimeMillis() / 1000.0)
            updateTake(takeId) { invalidateTakeRender(it.copy(extraStaffs = (it.extraStaffs ?: emptyList()) + staff).extendedTo(events)) }
            staff.id
        }

    private fun updateStaff(takeId: String, staffId: String, f: (StudioTakeStaff) -> StudioTakeStaff?, extend: List<StudioNoteEvent>? = null) =
        updateTake(takeId) { t ->
            val xs = t.extraStaffs ?: return@updateTake null
            val i = xs.indexOfFirst { it.id == staffId }
            if (i < 0) return@updateTake null
            val next = f(xs[i]) ?: return@updateTake null
            val t2 = t.copy(extraStaffs = xs.replaced(i, next))
            invalidateTakeRender(if (extend != null) t2.extendedTo(extend) else t2)
        }

    fun setStaffEvents(takeId: String, staffId: String, events: List<StudioNoteEvent>) =
        updateStaff(takeId, staffId, { it.copy(editedEvents = events) }, events)

    fun revertStaffEdits(takeId: String, staffId: String) =
        updateStaff(takeId, staffId, { if (it.editedEvents == null) null else it.copy(editedEvents = null) })

    fun setStaffInstrument(takeId: String, staffId: String, instrument: InstrumentKey) =
        updateStaff(takeId, staffId, { if (it.instrument == instrument) null else it.copy(instrument = instrument) })

    fun deleteStaff(takeId: String, staffId: String) = updateTake(takeId) { t ->
        val xs = t.extraStaffs ?: return@updateTake null
        if (xs.none { it.id == staffId }) return@updateTake null
        val left = xs.filterNot { it.id == staffId }
        invalidateTakeRender(t.copy(extraStaffs = left.ifEmpty { null }))
    }

    /**
     * A score/instrument/tempo/staff change makes the rendered mixdown stale: drop the cache file,
     * clear the fields and bump the monotonic revision (so a render STARTED before the edit that
     * lands AFTER it is rejected by [setTakeRendered]).
     */
    private fun invalidateTakeRender(t: StudioTake): StudioTake {
        t.renderedFileName?.let { deleteArtifact(StudioFamily.TAKES, it, t.renderedWasUserFolder ?: false) }
        return t.copy(renderedFileName = null, renderedWasUserFolder = null, renderedRevision = null, renderRevision = t.renderRevision + 1)
    }

    fun deleteTake(id: String): Boolean = synchronized(lock) {
        val d = _state.value
        val t = d.takes.firstOrNull { it.id == id } ?: return false
        deleteArtifact(StudioFamily.TAKES, t.fileName, t.wasUserFolder)
        invalidateTakeRender(t)   // also drops the rendered-audio cache file
        commit(d.copy(takes = d.takes.filterNot { it.id == id }))
        true
    }

    /** File a finished take render, unless an edit landed mid-render (revision mismatch => STALE, dropped + file deleted). */
    fun setTakeRendered(id: String, fileName: String, wasUserFolder: Boolean, revision: Int): Boolean = synchronized(lock) {
        val t = take(id) ?: return false
        if (t.renderRevision != revision) {
            deleteArtifact(StudioFamily.TAKES, fileName, wasUserFolder)
            return false
        }
        updateTake(id) { it.copy(renderedFileName = fileName, renderedWasUserFolder = wasUserFolder, renderedRevision = revision) }
        true
    }

    // ------------------------------------------------------------------------------------------
    // Cues (max 8 slots per song, store-enforced) + the cue mirror
    // ------------------------------------------------------------------------------------------

    fun cues(songId: String): List<StudioCue> = doc.cues.filter { it.songId == songId }.sortedBy { it.slot }

    fun cue(songId: String, slot: Int): StudioCue? = doc.cues.firstOrNull { it.songId == songId && it.slot == slot }

    private fun normalizedName(name: String?): String? = name?.trimmedOrNull()

    /** Set (or replace) the cue in [slot]; null when the slot is out of 0..7 or songId empty. */
    fun setCue(songId: String, slot: Int, positionMs: Int, name: String? = null): StudioCue? = synchronized(lock) {
        if (songId.isEmpty() || slot !in 0 until StudioCue.MAX_SLOTS) return null
        val pos = maxOf(0, positionMs)
        val d = _state.value
        val i = d.cues.indexOfFirst { it.songId == songId && it.slot == slot }
        val cue = if (i >= 0) {
            d.cues[i].copy(positionMs = pos, name = if (name != null) normalizedName(name) else d.cues[i].name)
        } else {
            StudioCue(StudioFactory.newCueId(), songId, slot, pos, normalizedName(name))
        }
        _state.value = d.copy(cues = if (i >= 0) d.cues.replaced(i, cue) else d.cues + cue)
        saveCuesNow()
        cue
    }

    fun removeCue(songId: String, slot: Int) = synchronized(lock) {
        val d = _state.value
        val left = d.cues.filterNot { it.songId == songId && it.slot == slot }
        if (left.size != d.cues.size) {
            _state.value = d.copy(cues = left)
            saveCuesNow()
        }
    }

    fun renameCue(songId: String, slot: Int, name: String?) = synchronized(lock) {
        val d = _state.value
        val i = d.cues.indexOfFirst { it.songId == songId && it.slot == slot }
        if (i < 0) return@synchronized
        _state.value = d.copy(cues = d.cues.replaced(i, d.cues[i].copy(name = normalizedName(name))))
        saveCuesNow()
    }

    /** Debounced (streams from a nudge control); the mirror write rides the same debounce. */
    fun nudgeCue(songId: String, slot: Int, deltaMs: Int) = synchronized(lock) {
        val d = _state.value
        val i = d.cues.indexOfFirst { it.songId == songId && it.slot == slot }
        if (i < 0) return@synchronized
        _state.value = d.copy(cues = d.cues.replaced(i, d.cues[i].copy(positionMs = maxOf(0, d.cues[i].positionMs + deltaMs))))
        scheduleCueSave()
    }

    /**
     * Adopt the cue mirror a sync pull just wrote. The pulled cues are made durable in the studio
     * doc SYNCHRONOUSLY (a kill right after a pull must not leave a stale doc under a fresh
     * watermark) and the mirror is NEVER rewritten (no push-back loop).
     */
    fun reloadCuesFromDisk(): Boolean = synchronized(lock) {
        val text = try { cuesFile.readText() } catch (_: Exception) { return false }
        val cdoc = StudioCueDoc.decode(text) ?: return false
        // Drop any queued/pending local mirror write: it would overwrite the pulled mirror with
        // stale cues and push them back.
        cancelCueSave?.invoke(); cancelCueSave = null
        cueMirrorDirty = false
        cueWriter.invalidate(++cueVersion)
        _state.value = _state.value.copy(cues = cdoc.cues)
        cancelSave?.invoke(); cancelSave = null
        val v = ++saveVersion
        val snap = _state.value
        writer.flushNow(v) { snap.encode() }
        true
    }

    /** Wipe all cues from the doc AND the mirror ("Reset everything"). */
    fun clearCues() = synchronized(lock) {
        cancelCueSave?.invoke(); cancelCueSave = null
        cueMirrorDirty = false
        _state.value = _state.value.copy(cues = emptyList())
        saveNow()
        cueWriter.delete(++cueVersion)
    }

    // ------------------------------------------------------------------------------------------
    // Slices (max 8 pads per sample)
    // ------------------------------------------------------------------------------------------

    fun slices(sampleId: String): List<StudioSlice> = doc.slices.filter { it.sampleId == sampleId }.sortedBy { it.slot }

    fun slice(sampleId: String, slot: Int): StudioSlice? = doc.slices.firstOrNull { it.sampleId == sampleId && it.slot == slot }

    /** [start, end) of a pad: until the NEXT slice's start by time, else the RAW sample end. */
    fun sliceWindow(sampleId: String, slot: Int): Pair<Int, Int>? {
        val s = slice(sampleId, slot) ?: return null
        val sample = sample(sampleId) ?: return null
        val nextStart = doc.slices.filter { it.sampleId == sampleId && it.startMs > s.startMs }.minOfOrNull { it.startMs }
        val end = nextStart ?: sample.durationMs
        return if (end > s.startMs) s.startMs to end else null
    }

    fun setSlice(sampleId: String, slot: Int, startMs: Int, name: String? = null): StudioSlice? = synchronized(lock) {
        if (sampleId.isEmpty() || slot !in 0 until StudioSlice.MAX_SLOTS) return null
        val start = maxOf(0, startMs)
        val d = _state.value
        val i = d.slices.indexOfFirst { it.sampleId == sampleId && it.slot == slot }
        val s = if (i >= 0) d.slices[i].copy(startMs = start, name = if (name != null) normalizedName(name) else d.slices[i].name)
        else StudioSlice(StudioFactory.newSliceId(), sampleId, slot, start, normalizedName(name))
        commit(d.copy(slices = if (i >= 0) d.slices.replaced(i, s) else d.slices + s))
        s
    }

    /** Replace all of a sample's slices with the distinct sorted [startsMs] (capped at 8). */
    fun setSlices(sampleId: String, startsMs: List<Int>) = mutate { d ->
        if (sampleId.isEmpty()) return@mutate null
        val starts = startsMs.map { maxOf(0, it) }.toSortedSet().take(StudioSlice.MAX_SLOTS)
        d.copy(
            slices = d.slices.filterNot { it.sampleId == sampleId } +
                starts.mapIndexed { slot, st -> StudioSlice(StudioFactory.newSliceId(), sampleId, slot, st) },
        )
    }

    fun removeSlice(sampleId: String, slot: Int) = mutate { d ->
        val left = d.slices.filterNot { it.sampleId == sampleId && it.slot == slot }
        if (left.size == d.slices.size) null else d.copy(slices = left)
    }

    fun clearSlices(sampleId: String) = mutate { d ->
        val left = d.slices.filterNot { it.sampleId == sampleId }
        if (left.size == d.slices.size) null else d.copy(slices = left)
    }

    fun renameSlice(sampleId: String, slot: Int, name: String?) = mutate { d ->
        val i = d.slices.indexOfFirst { it.sampleId == sampleId && it.slot == slot }
        if (i < 0) null else d.copy(slices = d.slices.replaced(i, d.slices[i].copy(name = normalizedName(name))))
    }

    fun nudgeSlice(sampleId: String, slot: Int, deltaMs: Int) = mutate(stream = true) { d ->
        val i = d.slices.indexOfFirst { it.sampleId == sampleId && it.slot == slot }
        if (i < 0) null else d.copy(slices = d.slices.replaced(i, d.slices[i].copy(startMs = maxOf(0, d.slices[i].startMs + deltaMs))))
    }

    // ------------------------------------------------------------------------------------------
    // Playback resolution (collections / audition seam)
    // ------------------------------------------------------------------------------------------

    /**
     * Resolve a studio id (`smp_`/`lp_`/`ptn_`/`tk_`) to a local file for playback, or null when
     * the record or file is gone / its user root unreachable. Samples and takes prefer a FRESH
     * render cache; a pattern plays only while its bounce is not dirty.
     */
    fun localUrlForPlayback(id: String): StudioPlayable? {
        val d = doc
        when {
            id.startsWith("smp_") -> {
                val s = d.samples.firstOrNull { it.id == id } ?: return null
                if (s.isRenderFresh) {
                    s.renderedFileName?.let { rf ->
                        fileRef(StudioFamily.SAMPLES, rf, s.renderedWasUserFolder ?: false)?.let {
                            return StudioPlayable(it, s.name, s.effectiveDurationMs)
                        }
                    }
                }
                return fileRef(StudioFamily.SAMPLES, s.fileName, s.wasUserFolder)?.let { StudioPlayable(it, s.name, s.effectiveDurationMs) }
            }
            id.startsWith("lp_") -> {
                val l = d.loops.firstOrNull { it.id == id } ?: return null
                return fileRef(StudioFamily.LOOPS, l.fileName, l.wasUserFolder)?.let { StudioPlayable(it, l.name, l.lengthMs) }
            }
            id.startsWith("ptn_") -> {
                val p = d.patterns.firstOrNull { it.id == id } ?: return null
                val f = p.fileName ?: return null
                if (p.bounceDirty) return null
                return fileRef(StudioFamily.SEQUENCES, f, p.wasUserFolder)?.let { StudioPlayable(it, p.name, p.lengthMs) }
            }
            id.startsWith("tk_") -> {
                val t = d.takes.firstOrNull { it.id == id } ?: return null
                if (t.isRenderFresh) {
                    t.renderedFileName?.let { rf ->
                        fileRef(StudioFamily.TAKES, rf, t.renderedWasUserFolder ?: false)?.let {
                            return StudioPlayable(it, t.name, t.durationMs)
                        }
                    }
                }
                return fileRef(StudioFamily.TAKES, t.fileName, t.wasUserFolder)?.let { StudioPlayable(it, t.name, t.durationMs) }
            }
        }
        return null
    }

    // ------------------------------------------------------------------------------------------
    // Analysis (on-device key) + Mix / display info
    // ------------------------------------------------------------------------------------------

    fun camelot(studioId: String): String? = doc.keys[studioId]

    fun setCamelot(camelot: String?, studioId: String) = mutate { d ->
        d.copy(keys = if (!camelot.isNullOrEmpty()) d.keys + (studioId to camelot) else d.keys - studioId)
    }

    fun mixInfo(studioId: String): StudioMixInfo? {
        val d = doc
        val cam = d.keys[studioId]
        return when {
            studioId.startsWith("smp_") -> d.samples.firstOrNull { it.id == studioId }?.let { s ->
                StudioMixInfo(s.grid?.bpm, s.grid?.firstDownbeatMs ?: 0, s.grid?.beatsMs?.takeIf { it.isNotEmpty() }, cam)
            }
            studioId.startsWith("lp_") -> d.loops.firstOrNull { it.id == studioId }?.let { StudioMixInfo(it.bpm, 0, null, cam) }
            studioId.startsWith("ptn_") -> d.patterns.firstOrNull { it.id == studioId }?.let { StudioMixInfo(it.bpm, 0, null, cam) }
            studioId.startsWith("tk_") -> d.takes.firstOrNull { it.id == studioId }?.let { StudioMixInfo(it.bpm, 0, null, cam) }
            else -> null
        }
    }

    fun displayInfo(studioId: String): StudioDisplayInfo? {
        val d = doc
        return when {
            studioId.startsWith("smp_") -> d.samples.firstOrNull { it.id == studioId }?.let { StudioDisplayInfo(it.name, it.effectiveDurationMs, it.grid?.bpm, "Sample") }
            studioId.startsWith("lp_") -> d.loops.firstOrNull { it.id == studioId }?.let { StudioDisplayInfo(it.name, it.lengthMs, it.bpm, "Loop") }
            studioId.startsWith("ptn_") -> d.patterns.firstOrNull { it.id == studioId }?.let { StudioDisplayInfo(it.name, it.lengthMs, it.bpm, "Sequence") }
            studioId.startsWith("tk_") -> d.takes.firstOrNull { it.id == studioId }?.let { StudioDisplayInfo(it.name, it.durationMs, it.bpm, "Instrumental") }
            else -> null
        }
    }

    // ------------------------------------------------------------------------------------------
    // Reconcile (launch) + storage manager
    // ------------------------------------------------------------------------------------------

    /** Prune records whose file is PROVABLY gone from a REACHABLE root (see [StudioReconcile]). */
    fun reconcileOnLaunch(): StudioReconcile.Result = synchronized(lock) {
        val r = StudioReconcile.reconcile(_state.value, roots)
        if (r.changed) commit(r.doc)
        r
    }

    /** On-disk bytes for one family's artifacts (Settings > Storage usage row). */
    fun usageBytes(family: StudioFamily): Long = StudioReconcile.usageBytes(doc, roots, family)

    /** Storage manager: delete EVERYTHING in one family (files + records), safely. */
    fun deleteAll(family: StudioFamily) = synchronized(lock) {
        commit(StudioReconcile.deleteAll(_state.value, roots, family, activeTakeFileName?.invoke()))
    }

    // ------------------------------------------------------------------------------------------
    // Arrangements (the "Tracks" sub-tab)
    // ------------------------------------------------------------------------------------------

    fun arrangement(id: String): StudioArrangement? = doc.arrangements.firstOrNull { it.id == id }

    fun arrangementsOrdered(): List<StudioArrangement> = doc.arrangements.sortedByDescending { it.createdAt }

    /** Resolve a clip/artifact audio file in the app-managed arrangements dir. */
    fun clipFile(fileName: String): File? {
        if (!StudioFolders.isBareName(fileName)) return null
        return File(roots.arrangementsDir(), fileName).takeIf { it.isFile }
    }

    fun artifactFile(fileName: String): File? = clipFile(fileName)

    fun createArrangement(name: String): StudioArrangement = synchronized(lock) {
        val t = nowMs
        val a = StudioArrangement(StudioFactory.newArrangementId(), name.trim(), createdAt = t, updatedAt = t)
        commit(_state.value.let { it.copy(arrangements = it.arrangements + a) })
        a
    }

    fun renameArrangement(id: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        mutateArrangement(id) { it.copy(name = n) }
    }

    /** Deletes the arrangement AND its clip files. */
    fun deleteArrangement(id: String): Boolean = synchronized(lock) {
        val d = _state.value
        val a = d.arrangements.firstOrNull { it.id == id } ?: return false
        a.tracks.forEach { t -> t.clips.forEach { deleteClipFile(it.fileName) } }
        commit(d.copy(arrangements = d.arrangements.filterNot { it.id == id }))
        true
    }

    /** The arranger's one mutation door: applies [f], stamps updatedAt, saves (debounced when [stream]). */
    fun mutateArrangement(id: String, stream: Boolean = false, f: (StudioArrangement) -> StudioArrangement) =
        mutate(stream) { d ->
            val i = d.arrangements.indexOfFirst { it.id == id }
            if (i < 0) null else d.copy(arrangements = d.arrangements.replaced(i, f(d.arrangements[i]).copy(updatedAt = nowMs)))
        }

    fun setArrangementBpm(id: String, bpm: Double) =
        mutateArrangement(id) { it.copy(bpm = if (bpm.isFinite() && bpm > 0) bpm.coerceIn(20.0, 300.0) else 120.0) }

    fun setArrangementLoop(id: String, enabled: Boolean? = null, startMs: Int? = null, endMs: Int? = null) =
        mutateArrangement(id, stream = true) { a ->
            val s = startMs?.let { maxOf(0, it) } ?: a.loopStartMs
            val e = endMs ?: a.loopEndMs
            a.copy(loopEnabled = enabled ?: a.loopEnabled, loopStartMs = s, loopEndMs = maxOf(s, e))
        }

    fun setArrangementMasterFX(id: String, fx: StudioMasterFX) = mutateArrangement(id, stream = true) { it.copy(masterFX = fx) }

    fun setArrangementBeatMatch(id: String, enabled: Boolean) = mutateArrangement(id) { it.copy(beatMatchEnabled = enabled) }

    fun setClipGrid(arrangementId: String, trackId: String, clipId: String, grid: StudioGrid) =
        mutateTrack(arrangementId, trackId) { t -> t.copy(clips = t.clips.map { if (it.id == clipId) it.copy(grid = grid) else it }) }

    // Artifacts (bounces + live recordings).

    fun artifacts(arrangementId: String, kind: StudioArrangementArtifact.Kind): List<StudioArrangementArtifact> =
        doc.arrangementArtifacts.filter { it.arrangementId == arrangementId && it.kind == kind }.sortedByDescending { it.createdAt }

    fun addArrangementArtifact(a: StudioArrangementArtifact): StudioArrangementArtifact {
        mutate { d ->
            val i = d.arrangementArtifacts.indexOfFirst { it.id == a.id }
            d.copy(arrangementArtifacts = if (i >= 0) d.arrangementArtifacts.replaced(i, a) else d.arrangementArtifacts + a)
        }
        return a
    }

    fun deleteArrangementArtifact(id: String) = synchronized(lock) {
        val d = _state.value
        val art = d.arrangementArtifacts.firstOrNull { it.id == id } ?: return@synchronized
        deleteClipFile(art.fileName)
        commit(d.copy(arrangementArtifacts = d.arrangementArtifacts.filterNot { it.id == id }))
    }

    // Tracks.

    private fun mutateTrack(aid: String, tid: String, stream: Boolean = false, f: (com.levi.pocketdj.studio.model.StudioTrack) -> com.levi.pocketdj.studio.model.StudioTrack) =
        mutateArrangement(aid, stream) { a -> a.copy(tracks = a.tracks.map { if (it.id == tid) f(it) else it }) }

    fun addTrack(arrangementId: String, name: String? = null): com.levi.pocketdj.studio.model.StudioTrack? = synchronized(lock) {
        val a = arrangement(arrangementId) ?: return null
        val n = a.tracks.size
        val track = com.levi.pocketdj.studio.model.StudioTrack(
            StudioFactory.newTrackId(), name?.trimmedOrNull() ?: "Track ${n + 1}",
            colorIndex = n % TRACK_PALETTE_SIZE, createdAt = nowMs,
        )
        mutateArrangement(arrangementId) { it.copy(tracks = it.tracks + track) }
        track
    }

    fun deleteTrack(arrangementId: String, trackId: String): Boolean = synchronized(lock) {
        val t = arrangement(arrangementId)?.tracks?.firstOrNull { it.id == trackId } ?: return false
        t.clips.forEach { deleteClipFile(it.fileName) }
        mutateArrangement(arrangementId) { a -> a.copy(tracks = a.tracks.filterNot { it.id == trackId }) }
        true
    }

    /** Duplicate a track (fresh ids, copied clip files, not soloed) right after the source. */
    fun duplicateTrack(arrangementId: String, trackId: String): com.levi.pocketdj.studio.model.StudioTrack? = synchronized(lock) {
        val a = arrangement(arrangementId) ?: return null
        val j = a.tracks.indexOfFirst { it.id == trackId }
        if (j < 0) return null
        val src = a.tracks[j]
        val t = nowMs
        val copy = src.copy(
            id = StudioFactory.newTrackId(), name = src.name + " copy", createdAt = t, soloed = false,
            clips = src.clips.map { c ->
                val nid = StudioFactory.newClipId()
                val fn = clipFileName(nid)
                copyClipFile(c.fileName, fn)
                c.copy(id = nid, fileName = fn, createdAt = t)
            },
        )
        mutateArrangement(arrangementId) { ar -> ar.copy(tracks = ar.tracks.toMutableList().also { it.add(j + 1, copy) }) }
        copy
    }

    fun renameTrack(arrangementId: String, trackId: String, name: String) {
        val n = name.trimmedOrNull() ?: return
        mutateTrack(arrangementId, trackId) { it.copy(name = n) }
    }

    fun setTrackGain(arrangementId: String, trackId: String, gainDb: Double) =
        mutateTrack(arrangementId, trackId, stream = true) { it.copy(gainDb = gainDb) }

    fun setTrackMuted(arrangementId: String, trackId: String, muted: Boolean) =
        mutateTrack(arrangementId, trackId) { it.copy(muted = muted) }

    fun setTrackSoloed(arrangementId: String, trackId: String, soloed: Boolean) =
        mutateTrack(arrangementId, trackId) { it.copy(soloed = soloed) }

    fun setTrackPan(arrangementId: String, trackId: String, pan: Double) =
        mutateTrack(arrangementId, trackId, stream = true) { it.copy(pan = pan.coerceIn(-1.0, 1.0)) }

    fun setTrackStrip(arrangementId: String, trackId: String, strip: StudioChannelStrip) =
        mutateTrack(arrangementId, trackId, stream = true) { it.copy(strip = strip.clamped()) }

    fun setTrackColor(arrangementId: String, trackId: String, colorIndex: Int) =
        mutateTrack(arrangementId, trackId) { it.copy(colorIndex = Math.floorMod(colorIndex, TRACK_PALETTE_SIZE)) }

    // Clips.

    /** The arrangement tempo seeds from the FIRST clip's source bpm while the arrangement is untouched. */
    private fun seededBpm(a: StudioArrangement, clip: StudioClip): Double? {
        if (a.allClips.isNotEmpty() || a.bpm != 120.0) return null
        val derived = when (clip.source) {
            StudioClipSource.LOOP -> clip.sourceId?.let { loop(it)?.bpm }
            StudioClipSource.TAKE -> clip.sourceId?.let { take(it)?.bpm }
            StudioClipSource.PATTERN -> clip.sourceId?.let { pattern(it)?.bpm }
            StudioClipSource.SAMPLE -> clip.sourceId?.let { sample(it)?.grid?.bpm }
            StudioClipSource.RECORDING, StudioClipSource.MASTER, StudioClipSource.STEM -> null
        }
        return derived?.takeIf { it.isFinite() && it > 0 }?.coerceIn(20.0, 300.0)
    }

    fun addClip(arrangementId: String, trackId: String, clip: StudioClip) = synchronized(lock) {
        val a = arrangement(arrangementId) ?: return@synchronized
        val seed = seededBpm(a, clip)
        mutateArrangement(arrangementId) { ar ->
            val withBpm = if (seed != null) ar.copy(bpm = seed) else ar
            withBpm.copy(
                tracks = withBpm.tracks.map { t ->
                    if (t.id != trackId) t else {
                        val k = t.clips.indexOfFirst { it.id == clip.id }
                        t.copy(clips = if (k >= 0) t.clips.replaced(k, clip) else t.clips + clip)
                    }
                },
            )
        }
    }

    fun removeClip(arrangementId: String, trackId: String, clipId: String): Boolean = synchronized(lock) {
        val c = arrangement(arrangementId)?.tracks?.firstOrNull { it.id == trackId }?.clips?.firstOrNull { it.id == clipId } ?: return false
        deleteClipFile(c.fileName)
        mutateTrack(arrangementId, trackId) { t -> t.copy(clips = t.clips.filterNot { it.id == clipId }) }
        true
    }

    fun moveClip(arrangementId: String, trackId: String, clipId: String, toStartMs: Int) =
        mutateTrack(arrangementId, trackId, stream = true) { t ->
            t.copy(clips = t.clips.map { if (it.id == clipId) it.copy(startMs = maxOf(0, toStartMs)) else it })
        }

    /**
     * Commit a scissor-trim session's clips for one track (the ONLY step that touches disk, so
     * Cancel is a pure revert). Shared source files are de-duplicated with a FULL byte copy, and
     * files this track dropped that no clip references any more are deleted.
     */
    fun commitTrimmedTrack(arrangementId: String, trackId: String, newClips: List<StudioClip>) = synchronized(lock) {
        val a = arrangement(arrangementId) ?: return@synchronized
        val old = a.tracks.firstOrNull { it.id == trackId } ?: return@synchronized
        val oldFiles = old.clips.map { it.fileName }.toSet()
        val claimed = HashSet<String>()
        val deduped = newClips.map { c ->
            var clip = c
            if (clip.fileName in claimed) {
                val unique = clipFileName(clip.id)
                copyClipFile(clip.fileName, unique)
                clip = clip.copy(fileName = unique)
            }
            claimed += clip.fileName
            clip
        }
        mutateArrangement(arrangementId) { ar -> ar.copy(tracks = ar.tracks.map { if (it.id == trackId) it.copy(clips = deduped) else it }) }
        val live = arrangement(arrangementId)!!.tracks.flatMap { t -> t.clips.map { it.fileName } }.toSet()
        for (f in oldFiles) if (f !in live) deleteClipFile(f)
    }

    private fun deleteClipFile(fileName: String) {
        if (!StudioFolders.isBareName(fileName)) return
        runCatching { File(roots.arrangementsDir(), fileName).delete() }
    }

    private fun copyClipFile(from: String, to: String) {
        if (!StudioFolders.isBareName(from) || !StudioFolders.isBareName(to)) return
        val dir = roots.arrangementsDir()
        runCatching { File(dir, from).copyTo(File(dir, to), overwrite = true) }
    }

    companion object {
        const val FILE_NAME = "pocketdj-studio.json"
        const val SAVE_DEBOUNCE_MS = 600L
        const val TRACK_PALETTE_SIZE = 8
        private const val STUDIO_CUE_VERSION = com.levi.pocketdj.studio.model.STUDIO_CUE_SCHEMA_VERSION

        /** `pocketdj-studio.json` -> `pocketdj-studio.cues.json` (sibling). */
        fun cuesFileFor(studio: File): File =
            File(studio.parentFile, studio.name.removeSuffix(".json") + ".cues.json")

        fun clipFileName(id: String) = "clip-$id.m4a"

        /**
         * Scissor trim: cut `[cs, ce)` out of one track's [clips], leaving a gap. Disjoint clips are
         * kept whole; a clip straddling the cut keeps a head and/or tail piece (the tail's
         * `fileStartMs` slides forward so the SAME source file is windowed, non-destructively).
         * A middle split mints a NEW id for the tail; a pure head-trim keeps the clip's identity.
         */
        fun trimGap(
            clips: List<StudioClip>, cutStartMs: Int, cutEndMs: Int,
            newId: () -> String = { StudioFactory.newClipId() },
        ): List<StudioClip> {
            val cs = cutStartMs; val ce = cutEndMs
            if (ce <= cs) return clips
            val out = ArrayList<StudioClip>()
            for (clip in clips) {
                val s = clip.startMs; val e = clip.endMs
                if (e <= cs || s >= ce) { out += clip; continue }
                val hasHead = s < cs; val hasTail = e > ce
                if (hasHead) out += clip.copy(durationMs = cs - s)
                if (hasTail) {
                    out += clip.copy(
                        id = if (hasHead) newId() else clip.id,
                        startMs = ce, fileStartMs = clip.fileStartMs + (ce - s), durationMs = e - ce,
                    )
                }
            }
            return out
        }
    }
}

private fun <T> List<T>.replaced(i: Int, v: T): List<T> = toMutableList().also { it[i] = v }
private fun <T> byName(sel: (T) -> String): Comparator<T> =
    Comparator { a, b -> String.CASE_INSENSITIVE_ORDER.compare(sel(a), sel(b)) }
