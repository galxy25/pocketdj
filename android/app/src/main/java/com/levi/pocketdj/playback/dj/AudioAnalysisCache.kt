package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Quick hints and full results per file (port of iOS `AudioAnalysisCache`), keyed like [LoudnessCache]
 * (song id + byte size + segment). Finals persist at `filesDir/analysis.json` (LRU of [maxEntries]); hints
 * live for the launch. Saves are debounced and written off-main; decode is tolerant per entry.
 */
class AudioAnalysisCache(
    private val file: File?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val saveDebounceMs: Long = 1_000,
    private val now: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
    @Serializable
    private data class Entry(val key: LoudnessCache.Key, val result: AudioAnalysis.Result, val usedAt: Double? = null)

    @Serializable
    private data class FileBody(val version: Int = 1, val entries: List<Entry> = emptyList())

    private val lock = Any()
    private val quick = HashMap<LoudnessCache.Key, AudioAnalysis.Result>()
    private val full = HashMap<LoudnessCache.Key, AudioAnalysis.Result>()
    private val usedAt = HashMap<LoudnessCache.Key, Double>()
    private val latestKey = HashMap<String, LoudnessCache.Key>()
    private var saveJob: Job? = null
    private val _revision = MutableStateFlow(0)

    /** Bumped on every store (observers re-read). */
    val revision: StateFlow<Int> get() = _revision

    init { load() }

    private fun load() {
        val f = file?.takeIf { it.isFile } ?: return
        // Tolerant: a corrupt file or foreign shape leaves an empty cache; a bad ENTRY drops only itself.
        val arr = runCatching {
            (PdjJson.lenient.parseToJsonElement(f.readText()) as? JsonObject)?.get("entries") as? JsonArray
        }.getOrNull() ?: return
        for (el in arr) {
            val e = runCatching { PdjJson.lenient.decodeFromJsonElement(Entry.serializer(), el) }.getOrNull() ?: continue
            if (e.result.kind != AudioAnalysis.Kind.full) continue
            full[e.key] = e.result
            usedAt[e.key] = e.usedAt ?: 0.0
            val cur = latestKey[e.key.songId]
            if (cur != null && (usedAt[cur] ?: 0.0) > (e.usedAt ?: 0.0)) continue
            latestKey[e.key.songId] = e.key
        }
    }

    fun quick(key: LoudnessCache.Key): AudioAnalysis.Result? = synchronized(lock) { quick[key] }
    fun full(key: LoudnessCache.Key): AudioAnalysis.Result? = synchronized(lock) { full[key] }

    /** A hint for this song + segment under ANY byte size (a growing file re-keys as it grows). */
    fun quick(songId: String, segment: com.levi.pocketdj.audio.dsp.LoudnessSegment?): AudioAnalysis.Result? =
        synchronized(lock) { quick.entries.firstOrNull { it.key.songId == songId && it.key.segment == segment }?.value }

    val fullCount: Int get() = synchronized(lock) { full.size }

    /** The best results known for a song id (any file / segment of it - the latest analysed). */
    fun results(songId: String): Pair<AudioAnalysis.Result?, AudioAnalysis.Result?> = synchronized(lock) {
        val k = latestKey[songId] ?: return null to null
        if (full[k] != null) usedAt[k] = now()
        full[k] to quick[k]
    }

    fun store(r: AudioAnalysis.Result, key: LoudnessCache.Key) {
        var save = false
        synchronized(lock) {
            when (r.kind) {
                AudioAnalysis.Kind.quick -> {
                    if (full[key] != null) return            // a hint never overwrites a final
                    quick[key] = r
                }
                AudioAnalysis.Kind.full -> {
                    // The same song + segment under another byte size is a STALE file: never two answers.
                    for (k in full.keys.toList()) if (k.songId == key.songId && k.segment == key.segment && k != key) {
                        full.remove(k); usedAt.remove(k)
                    }
                    for (k in quick.keys.toList()) if (k.songId == key.songId && k.segment == key.segment) quick.remove(k)
                    full[key] = r
                    save = true
                }
            }
            usedAt[key] = now()
            latestKey[key.songId] = key
        }
        _revision.value = _revision.value + 1
        if (save) scheduleSave()
    }

    private fun scheduleSave() {
        if (file == null) return
        synchronized(lock) {
            saveJob?.cancel()
            saveJob = scope.launch(ioDispatcher) { delay(saveDebounceMs); writeNow() }
        }
    }

    /** Write now (tests / app backgrounding): the same pruned body, synchronously. */
    fun flush() {
        synchronized(lock) { saveJob?.cancel(); saveJob = null }
        writeNow()
    }

    private val writeLock = Any()

    private fun writeNow() = synchronized(writeLock) {
        val f = file ?: return@synchronized
        val entries = synchronized(lock) {
            if (full.size > maxEntries) {
                val drop = full.keys.sortedBy { usedAt[it] ?: 0.0 }.take(full.size - maxEntries)
                for (k in drop) { full.remove(k); usedAt.remove(k); if (latestKey[k.songId] == k) latestKey.remove(k.songId) }
            }
            full.map { Entry(it.key, it.value, usedAt[it.key]) }
        }.sortedWith(compareBy({ it.key.songId }, { it.key.byteSize }, { it.key.segment?.startMs ?: -1 }))
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(PdjJson.lenient.encodeToString(FileBody(entries = entries)))
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        }
    }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 5000
    }
}
