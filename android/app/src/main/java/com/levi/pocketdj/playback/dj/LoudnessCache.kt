package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.dsp.LoudnessCancelFlag
import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlin.coroutines.cancellation.CancellationException

/**
 * Measured loudness per local file (port of iOS `LoudnessCache`), persisted as `filesDir/loudness.json`,
 * keyed songId + file BYTE SIZE + the measured SEGMENT (a song on a shared album side is its own slice).
 * One analysis per key (a second caller awaits it), failures remembered for the launch, cancellable.
 * A growing file is never measured until complete. Unknown loudness => 0 dB.
 */
class LoudnessCache(
    private val file: File?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val saveDebounceMs: Long = 750,
    private val measure: (path: String, segment: LoudnessSegment?, cancel: LoudnessCancelFlag) -> Double? =
        { p, s, c -> LoudnessAnalyzer.analyzeSync(p, s, true, c) },
    private val log: (String) -> Unit = {},
) {
    @Serializable
    data class Key(val songId: String, val byteSize: Long, val segment: LoudnessSegment? = null)

    @Serializable
    private data class Entry(val songId: String, val byteSize: Long, val segment: LoudnessSegment? = null, val lufs: Double? = null)

    @Serializable
    private data class FileBody(val version: Int = 1, val entries: List<Entry> = emptyList())

    sealed class Outcome {
        data class Measured(val lufs: Double?) : Outcome()
        data class Cached(val lufs: Double?) : Outcome()
        object Failed : Outcome()
        object Cancelled : Outcome()
        /** The file is still growing: nothing measured, nothing remembered. */
        object NotReady : Outcome()
    }

    private val lock = Any()
    /** key -> measured lufs (null = analyzed, nothing measurable). */
    private val table = HashMap<Key, Double?>()
    private val inFlight = HashMap<Key, CompletableDeferred<Outcome>>()
    private val flags = HashMap<Key, LoudnessCancelFlag>()
    private val failed = HashSet<Key>()
    private var saveJob: Job? = null

    init { load() }

    private fun load() {
        val f = file?.takeIf { it.isFile } ?: return
        // Tolerant decode: a corrupt file or foreign shape leaves an empty table, never throws.
        val body = runCatching { PdjJson.lenient.decodeFromString<FileBody>(f.readText()) }.getOrNull() ?: return
        for (e in body.entries) table[Key(e.songId, e.byteSize, e.segment)] = e.lufs
    }

    fun contains(key: Key): Boolean = synchronized(lock) { table.containsKey(key) }
    fun isAnalyzing(key: Key): Boolean = synchronized(lock) { inFlight.containsKey(key) }
    fun hasFailed(key: Key): Boolean = synchronized(lock) { key in failed }
    fun isSettledOrRunning(key: Key): Boolean = synchronized(lock) { table.containsKey(key) || key in failed || inFlight.containsKey(key) }

    /** The measured loudness; null when unknown or unmeasurable. */
    fun lufs(key: Key): Double? = synchronized(lock) { table[key] }

    /** The leveling gain, dB; null when unknown (callers play at 0 dB). */
    fun gainDb(key: Key): Double? = LoudnessLeveling.gainDb(lufs(key))

    fun store(lufs: Double?, key: Key) {
        synchronized(lock) { table[key] = lufs; failed.remove(key) }
        scheduleSave()
    }

    /**
     * Measures [key]'s file once. [isComplete] false => [Outcome.NotReady] (a growing file's size and
     * bytes are not final). A call while the key is in flight awaits it and reports Cached.
     */
    suspend fun analyze(key: Key, path: String, isComplete: () -> Boolean = { true }): Outcome {
        val running: CompletableDeferred<Outcome>
        val mine: Boolean
        val flag = LoudnessCancelFlag()
        synchronized(lock) {
            if (table.containsKey(key)) return Outcome.Cached(table[key])
            if (key in failed) return Outcome.Failed
            if (!isComplete()) return Outcome.NotReady
            val existing = inFlight[key]
            if (existing != null) { running = existing; mine = false }
            else {
                running = CompletableDeferred(); inFlight[key] = running; flags[key] = flag; mine = true
            }
        }
        if (!mine) {
            val r = running.await()
            return if (r is Outcome.Measured) Outcome.Cached(r.lufs) else r
        }
        scope.launch(ioDispatcher) {
            val outcome: Outcome = try {
                val v = measure(path, key.segment, flag)
                synchronized(lock) { inFlight.remove(key); flags.remove(key) }
                store(v, key)
                log("level song=${key.songId} lufs=${v?.let { "%.1f".format(it) } ?: "nil"}")
                Outcome.Measured(v)
            } catch (_: CancellationException) {
                synchronized(lock) { inFlight.remove(key); flags.remove(key) }
                Outcome.Cancelled
            } catch (t: Throwable) {
                synchronized(lock) { inFlight.remove(key); flags.remove(key); failed.add(key) }
                log("level song=${key.songId} analyze failed (not retried): ${t.message}")
                Outcome.Failed
            }
            running.complete(outcome)
        }
        return running.await()
    }

    /** Analyze once per songId + size (+ segment); returns lufs (measured now or cached), null otherwise. */
    suspend fun analyzeIfNeeded(
        songId: String, file: File, startMs: Int? = null, lengthMs: Int? = null, isComplete: () -> Boolean = { true },
    ): Double? {
        val key = key(songId, file, startMs, lengthMs) ?: return null
        return when (val o = analyze(key, file.path, isComplete)) {
            is Outcome.Measured -> o.lufs
            is Outcome.Cached -> o.lufs
            else -> null
        }
    }

    /** Stop every running analysis (DJ off / session ended). Nothing is remembered for them. */
    fun cancelAll() {
        synchronized(lock) { flags.values.forEach { it.cancel() } }
    }

    private fun scheduleSave() {
        if (file == null) return
        synchronized(lock) {
            saveJob?.cancel()
            saveJob = scope.launch(ioDispatcher) { delay(saveDebounceMs); writeNow() }
        }
    }

    /** Writes immediately (tests / app backgrounding). */
    fun flush() {
        synchronized(lock) { saveJob?.cancel(); saveJob = null }
        writeNow()
    }

    private fun writeNow() {
        val f = file ?: return
        val entries = synchronized(lock) {
            table.map { Entry(it.key.songId, it.key.byteSize, it.key.segment, it.value) }
        }.sortedWith(compareBy({ it.songId }, { it.byteSize }, { it.segment?.startMs ?: -1 }))
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(PdjJson.lenient.encodeToString(FileBody(entries = entries)))
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        }
    }

    companion object {
        /** The key for a local file (null when its size can't be read). */
        fun key(songId: String, file: File, startMs: Int? = null, lengthMs: Int? = null): Key? {
            if (!file.isFile) return null
            return Key(songId, file.length(), startMs?.let { LoudnessSegment(it, lengthMs) })
        }
    }
}
