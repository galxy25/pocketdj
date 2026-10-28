package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.io.InputStream
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString

/**
 * Owns the Demuxer's derived-metadata documents (port of DemuxStore.swift): one [DemuxDocument] JSON
 * per source under `<cacheDir>/<key>.json` (flat files, memory tier above), the copied-in audio for
 * imported files under `audio/`, a carved analog song under `audio/<songId>.m4a`, and a CUSTOM source's
 * downloaded stems under `stems/<key>/<stem>.<ext>`. [cacheDir] is injectable for JVM tests.
 */
class DemuxStore(
    private val cacheDir: File?,
    private val json: kotlinx.serialization.json.Json = PdjJson.lenient,
    /** Blocking-ish fetch of [url] into [dest]; true on a 2xx full write (stems download seam). */
    private val fetch: suspend (url: String, dest: File) -> Boolean = { _, _ -> false },
    private val detectChords: (path: String) -> List<DemuxChordSegment> = { ChordDetector.detect(it) },
) {
    private val memory = HashMap<String, DemuxDocument>()
    private val lock = Any()

    private val _chordRuns = MutableStateFlow<Set<String>>(emptySet())
    /** Keys with a chord analysis in flight (drives the running spinner; not persisted). */
    val chordRuns: StateFlow<Set<String>> = _chordRuns.asStateFlow()

    private val _revision = MutableStateFlow(0L)
    /** Bumped on every [save] so Compose can re-read documents. */
    val revision: StateFlow<Long> = _revision.asStateFlow()

    // ---- documents ---------------------------------------------------------------------------

    private fun fileFor(key: String): File? = cacheDir?.let { File(it, "${safe(key)}.json") }

    /** The document for a source key: memory -> disk -> null (never analyzed). */
    fun document(key: String): DemuxDocument? = synchronized(lock) {
        memory[key]?.let { return it }
        val f = fileFor(key)?.takeIf { it.isFile } ?: return null
        val doc = runCatching { json.decodeFromString<DemuxDocument>(f.readText()) }.getOrNull() ?: return null
        memory[key] = doc
        doc
    }

    /** The document for a source, created empty on first sight. */
    fun documentCreating(source: DemuxSource): DemuxDocument = synchronized(lock) {
        document(source.key) ?: DemuxDocument(sourceKey = source.key, displayName = source.displayName).also { memory[source.key] = it }
    }

    fun save(doc: DemuxDocument) {
        synchronized(lock) {
            memory[doc.sourceKey] = doc
            val f = fileFor(doc.sourceKey)
            if (f != null) {
                f.parentFile?.mkdirs()
                val tmp = File(f.parentFile, f.name + ".tmp")
                runCatching { tmp.writeText(json.encodeToString(doc)); atomicMove(tmp, f) }
            }
        }
        _revision.value = _revision.value + 1
    }

    /** Read-modify-write one document atomically (analysis results land through this). */
    fun update(source: DemuxSource, change: (DemuxDocument) -> DemuxDocument) {
        synchronized(lock) { save(change(documentCreating(source))) }
    }

    // ---- imported audio ----------------------------------------------------------------------

    private fun audioDir(): File? = cacheDir?.let { File(it, "audio").apply { mkdirs() } }

    /** Copy a picked file's bytes into the demux audio folder and mint its source (durable past the picker grant). */
    fun importStream(displayNameWithExt: String, input: InputStream): DemuxSource.ImportedFile? {
        val dir = audioDir() ?: return null
        val id = "dmx_${UUID.randomUUID().toString().lowercase().take(8)}"
        val ext = displayNameWithExt.substringAfterLast('.', "").lowercase().ifEmpty { "audio" }
        val name = "$id.$ext"
        val dest = File(dir, name)
        try {
            dest.outputStream().use { input.copyTo(it) }
        } catch (e: Exception) {
            dest.delete(); return null
        }
        val title = displayNameWithExt.substringBeforeLast('.', displayNameWithExt)
        save(DemuxDocument(sourceKey = id, displayName = title, importedFileName = name))
        return DemuxSource.ImportedFile(id, title)
    }

    /** Local file of an imported source's copied-in audio. */
    fun importedAudioFile(key: String): File? {
        val name = document(key)?.importedFileName ?: return null
        return File(audioDir() ?: return null, name).takeIf { it.isFile }
    }

    /** Imported sources whose audio is still on disk (disk-scanned: survives restarts), name-sorted. */
    fun importedSources(): List<Pair<String, String>> {
        val files = cacheDir?.listFiles { f -> f.extension == "json" } ?: return emptyList()
        val out = ArrayList<Pair<String, String>>()
        for (f in files) {
            val doc = runCatching { json.decodeFromString<DemuxDocument>(f.readText()) }.getOrNull() ?: continue
            if (doc.importedFileName == null || importedAudioFile(doc.sourceKey) == null) continue
            out.add(doc.sourceKey to doc.displayName)
        }
        return out.sortedBy { it.second.lowercase() }
    }

    // ---- carved analog song ------------------------------------------------------------------

    /** Where a song CARVED out of a shared analog album side lands (`audio/<songId>.m4a`). */
    fun carvedSongDestination(songId: String): File? = audioDir()?.let { File(it, "${safe(songId)}.m4a") }

    /** Already-carved audio for a song (carve ONCE; 0:00 = the song's 0:00), or null. */
    fun carvedSongFile(songId: String): File? = carvedSongDestination(songId)?.takeIf { it.isFile && it.length() > 0 }

    // ---- custom stems ------------------------------------------------------------------------

    private fun stemsDir(key: String): File? = cacheDir?.let { File(File(it, "stems"), safe(key)) }

    /** The four downloaded stem files for a custom source, or null if ANY is missing (all-or-nothing). */
    fun localStemFiles(key: String): Map<String, File>? {
        val dir = stemsDir(key)?.takeIf { it.isDirectory } ?: return null
        val listing = dir.listFiles()?.filter { !it.name.endsWith(".tmp") } ?: return null
        val out = LinkedHashMap<String, File>()
        for (name in STEM_NAMES) out[name] = listing.firstOrNull { it.nameWithoutExtension == name } ?: return null
        return out
    }

    /**
     * Download the four remote stems (name -> URL) into the cache. ALL-OR-NOTHING: files land as
     * `.tmp` and are renamed only once every stem arrived; any failure removes the whole folder so
     * [localStemFiles] never reports a half set as ready.
     */
    suspend fun downloadStems(key: String, remote: Map<String, String>): Map<String, File>? {
        val dir = stemsDir(key) ?: return null
        dir.deleteRecursively(); dir.mkdirs()
        val staged = LinkedHashMap<String, File>()
        for (name in STEM_NAMES) {
            val url = remote[name] ?: run { dir.deleteRecursively(); return null }
            val ext = url.substringBefore('?').substringAfterLast('/').substringAfterLast('.', "").ifEmpty { "mp3" }
            val tmp = File(dir, "$name.$ext.tmp")
            val ok = try { fetch(url, tmp) } catch (e: kotlinx.coroutines.CancellationException) { dir.deleteRecursively(); throw e } catch (_: Exception) { false }
            if (!ok || !tmp.isFile || tmp.length() == 0L) { dir.deleteRecursively(); return null }
            staged[name] = tmp
        }
        val out = LinkedHashMap<String, File>()
        for ((name, tmp) in staged) {
            val dest = File(dir, tmp.name.removeSuffix(".tmp"))
            if (!tmp.renameTo(dest)) { dir.deleteRecursively(); return null }
            out[name] = dest
        }
        return out
    }

    // ---- chord analysis ----------------------------------------------------------------------

    /**
     * Detect the chord timeline of [path] and land it on the source's document. No-op while a run for
     * the same key is in flight; [force] re-analyzes over a done result. Runs off the main thread.
     */
    fun analyzeChords(
        scope: CoroutineScope, source: DemuxSource, path: String, durationMs: Int, force: Boolean = false,
        dispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): Job? {
        val key = source.key
        if (!claimRun(key, force, source)) return null
        update(source) { it.copy(durationMs = maxOf(it.durationMs, durationMs)) }
        return scope.launch {
            val segments = try {
                withContext(dispatcher) { detectChords(path) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                _chordRuns.value = _chordRuns.value - key; throw e
            } catch (_: Throwable) { emptyList() }
            update(source) { it.copy(chords = segments, chordStatus = if (segments.isEmpty()) DemuxArtifactStatus.FAILED else DemuxArtifactStatus.DONE) }
            _chordRuns.value = _chordRuns.value - key
        }
    }

    private fun claimRun(key: String, force: Boolean, source: DemuxSource): Boolean = synchronized(lock) {
        if (key in _chordRuns.value) return false
        if (!force && documentCreating(source).chordStatus == DemuxArtifactStatus.DONE) return false
        _chordRuns.value = _chordRuns.value + key
        true
    }

    companion object {
        /** Stem order of the server's Demucs output / iOS `StemPlayer.stems`. */
        val STEM_NAMES = listOf("vocals", "drums", "bass", "other")

        fun safe(key: String): String = key.replace(":", "_").replace("/", "_")

        private fun atomicMove(tmp: File, dest: File) {
            java.nio.file.Files.move(tmp.toPath(), dest.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
