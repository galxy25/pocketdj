package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int

const val PUZZLE_DECISIONS_SCHEMA_VERSION = 1

/**
 * The recommendation-readable log of every Gem Collector decision — which song was
 * ASSIGNED to which collection, SKIPPED, or EXPIRED (played out without the player
 * acting) — plus a snapshot of the round's weighting settings. Port of iOS
 * `PuzzleDecisionStore`; the file is `{schemaVersion, installId, decisions}` JSON and is
 * wire-compatible with iOS (ids are uppercase UUID strings, `at` epoch ms).
 *
 * PERSISTENCE (gameplay-rate records, ~1/s, MB-scale document at the 20k cap):
 *  - a burst COALESCES into one write ([saveDebounceMs]);
 *  - encode+write runs on [writeContext], serialised by a write lock;
 *  - a monotonic WRITE GENERATION is re-checked INSIDE the queued block, because
 *    cancelling the job cannot retract a block already handed to the writer: every
 *    supersession (newer schedule, [flush]/save, [clear], a cloud pull or merge) bumps
 *    it and a stale snapshot skips its write.
 *
 * @param scope owns the debounce job (production: the Games `mainScope`).
 * @param writeContext where the encode+write runs (production: `Dispatchers.IO`).
 */
class PuzzleDecisionStore(
    private val file: File,
    private val scope: CoroutineScope,
    private val writeContext: CoroutineContext = EmptyCoroutineContext,
    private val saveDebounceMs: Long = SAVE_DEBOUNCE_MS,
    private val json: Json = PdjJson.lenient,
    private val newId: () -> String = { UUID.randomUUID().toString().uppercase() },
) {
    /** One decision. `action` stays a STRING on the wire for forward-compat. */
    @Serializable
    data class Decision(
        val id: String,
        val roundId: String,
        /** Epoch ms. */
        val at: Double,
        val songId: String,
        /** "assigned" | "skipped" | "expired". */
        val action: String,
        val collectionId: String? = null,
        val collectionName: String? = null,
        val positionInRound: Int? = null,
        val settings: PuzzleSettings? = null,
        val originInstallId: String? = null,
    )

    @Serializable
    data class Document(
        val schemaVersion: Int = PUZZLE_DECISIONS_SCHEMA_VERSION,
        val installId: String,
        val decisions: List<Decision> = emptyList(),
    )

    data class State(val decisions: List<Decision>, val revision: Int)

    private val lock = Any()
    private val writeLock = Any()
    private val generation = AtomicInteger(0)

    private var rows: List<Decision> = emptyList()
    private var revisionCounter = 0
    private var saveJob: Job? = null

    @Volatile
    private var pendingSave = false

    var installId: String = ""
        private set

    private val _state = MutableStateFlow(State(emptyList(), 0))
    val state: StateFlow<State> = _state.asStateFlow()

    val decisions: List<Decision> get() = _state.value.decisions
    val revision: Int get() = _state.value.revision

    /** True while a recorded row has not reached disk yet. */
    val hasUnsavedChanges: Boolean get() = pendingSave

    init {
        val doc = readDocument()
        if (doc != null) {
            rows = doc.decisions
            installId = doc.installId
        } else {
            installId = UUID.randomUUID().toString().uppercase()
        }
        publish()
    }

    // MARK: - Recording

    fun record(
        roundId: String,
        songId: String,
        action: String,
        collectionId: String? = null,
        collectionName: String? = null,
        positionInRound: Int? = null,
        settings: PuzzleSettings? = null,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): Decision {
        val d = Decision(
            id = newId(), roundId = roundId, at = nowMs, songId = songId, action = action,
            collectionId = collectionId, collectionName = collectionName,
            positionInRound = positionInRound, settings = settings, originInstallId = installId,
        )
        append(listOf(d))
        return d
    }

    /** One row of [recordBatch]. */
    data class BatchRow(val songId: String, val action: String, val positionInRound: Int?)

    /**
     * Record several decisions with ONE persist — the ticker's drift re-sync expires every
     * song the audio passed, and a per-row save would re-encode the whole document per row.
     */
    fun recordBatch(
        rows: List<BatchRow>,
        roundId: String,
        settings: PuzzleSettings? = null,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): List<Decision> {
        if (rows.isEmpty()) return emptyList()
        val made = rows.map {
            Decision(
                id = newId(), roundId = roundId, at = nowMs, songId = it.songId, action = it.action,
                positionInRound = it.positionInRound, settings = settings, originInstallId = installId,
            )
        }
        append(made)
        return made
    }

    private fun append(added: List<Decision>) {
        synchronized(lock) {
            var next = rows + added
            if (next.size > MAX_DECISIONS) next = next.subList(next.size - MAX_DECISIONS, next.size).toList()
            rows = next
            revisionCounter++
            publish()
            scheduleSave(debounce = true)
        }
    }

    fun decisions(forRound: String): List<Decision> = decisions.filter { it.roundId == forRound }

    // MARK: - Cloud-sync seams

    /**
     * CloudSync write seam: land the pulled payload through the SAME ordered writer,
     * bumping the generation first so a stale enqueued snapshot either lands BEFORE the
     * pull (and is overwritten by it) or skips itself.
     */
    fun applyPulledPayload(data: ByteArray) {
        generation.incrementAndGet()
        synchronized(writeLock) { writeBytesAtomically(data) }
    }

    /**
     * Union-by-id merge after a CloudSync pull. Returns true when we held rows the pulled
     * document lacked (and therefore wrote the merged document back).
     */
    fun reloadFromDisk(): Boolean {
        synchronized(lock) {
            // Invalidate any not-yet-run coalesced block: its snapshot predates this merge.
            generation.incrementAndGet()
            val doc = readDocument() ?: return false
            val byId = LinkedHashMap<String, Decision>()
            for (d in rows) byId.putIfAbsent(d.id.uppercase(), d)
            var addedFromDisk = 0
            for (d in doc.decisions) {
                if (byId.putIfAbsent(d.id.uppercase(), d) == null) addedFromDisk++
            }
            val weHoldRowsTheDocLacks = byId.size > doc.decisions.size
            var merged = byId.values.sortedBy { it.at }
            if (merged.size > MAX_DECISIONS) merged = merged.subList(merged.size - MAX_DECISIONS, merged.size).toList()
            rows = merged
            if (addedFromDisk > 0 || weHoldRowsTheDocLacks) revisionCounter++
            publish()
            if (!weHoldRowsTheDocLacks) {
                // A coalesced save scheduled BEFORE this merge holds a pre-merge snapshot —
                // re-arm it on the merged document (scheduleSave cancels the stale one).
                if (pendingSave && addedFromDisk > 0) scheduleSave(debounce = true)
                return false
            }
            save()
            return true
        }
    }

    fun clear() {
        synchronized(lock) {
            rows = emptyList()
            revisionCounter++
            publish()
            save()
        }
    }

    /** Write any pending coalesced save NOW, synchronously (app backgrounding). */
    fun flush() {
        synchronized(lock) {
            if (!pendingSave) return
            save()
        }
    }

    /**
     * Round-end flush: land the pending rows promptly (no debounce) on the writer without
     * blocking the caller. `pendingSave` stays true until it lands, so a later synchronous
     * [flush] still catches a racing kill.
     */
    fun flushAsync() {
        synchronized(lock) {
            if (!pendingSave) return
            scheduleSave(debounce = false)
        }
    }

    // MARK: - Persistence

    private fun publish() {
        _state.value = State(rows, revisionCounter)
    }

    private fun scheduleSave(debounce: Boolean) {
        synchronized(lock) {
            pendingSave = true
            saveJob?.cancel()
            val doc = Document(installId = installId, decisions = rows) // immutable snapshot
            val gen = generation.incrementAndGet()
            saveJob = scope.launch {
                if (debounce) {
                    delay(saveDebounceMs)
                    if (!isActive) return@launch
                }
                withContext(writeContext) {
                    synchronized(writeLock) {
                        // Superseded ⇒ this snapshot is stale: write nothing.
                        if (generation.get() == gen) write(doc)
                    }
                }
                if (!isActive) return@launch // a newer save superseded this one
                pendingSave = false
            }
        }
    }

    /**
     * Immediate, ordered write (flush / clear / post-merge). Bumps the generation so any
     * already-enqueued coalesced block skips itself, then writes under the writer lock so
     * it lands AFTER any block already mid-flight.
     */
    private fun save() {
        synchronized(lock) {
            saveJob?.cancel()
            saveJob = null
            pendingSave = false
            generation.incrementAndGet()
            val doc = Document(installId = installId, decisions = rows)
            synchronized(writeLock) { write(doc) }
        }
    }

    private fun write(doc: Document) {
        val text = runCatching { json.encodeToString(Document.serializer(), doc) }.getOrNull() ?: return
        writeBytesAtomically(text.toByteArray(Charsets.UTF_8))
    }

    private fun writeBytesAtomically(bytes: ByteArray) {
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) {
                file.writeBytes(bytes)
                tmp.delete()
            }
        }
    }

    /** Lenient read: a missing/corrupt file is null; a bad ROW is dropped, never the log. */
    private fun readDocument(): Document? {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null
        val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
        val version = (root["schemaVersion"] as? JsonPrimitive)
            ?.let { if (it.isString) null else runCatching { it.int }.getOrNull() }
            ?: PUZZLE_DECISIONS_SCHEMA_VERSION
        val install = (root["installId"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            ?: UUID.randomUUID().toString().uppercase()
        val decisions = (root["decisions"] as? JsonArray).orEmpty().mapNotNull { el ->
            runCatching { json.decodeFromJsonElement(Decision.serializer(), el) }.getOrNull()
        }
        return Document(version, install, decisions)
    }

    private fun JsonArray?.orEmpty(): JsonArray = this ?: JsonArray(emptyList())

    companion object {
        const val MAX_DECISIONS = 20_000
        const val SAVE_DEBOUNCE_MS = 600L
    }
}
