package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.games.puzzle.PlayRecency
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

const val REC_FEEDBACK_SCHEMA_VERSION = 1

/**
 * The 👍 / 👎 / cleared log behind every recommendation surface (port of iOS `RecFeedbackStore`,
 * file `pocketdj-rec-feedback.json`, wire-compatible).
 *
 * Invariants worth keeping:
 *  - A decision is a ROW; "cleared" is a row too, never a deletion (so undo syncs and wins by order).
 *  - Newest wins per (scope, song) by `at`, then `seq` (same-ms double-tap), then originInstallId,
 *    then id. The GLOBAL taste opinion is the newest verdict for the song in ANY scope.
 *  - A 👎 is a 7-day TOMBSTONE evaluated at READ time (no sweep): the row sinks, it is not filtered.
 *  - A 👍 in a zone/new/crate scope removes the row permanently (see ForYouGrid.excludingAccepted).
 *  - The PLAYING scope is device-local truth: adopted from disk only when the document is OURS.
 *
 * Persistence mirrors [com.levi.pocketdj.data.games.puzzle.PuzzleDecisionStore]: a debounced
 * snapshot write on [writeContext] with a monotonic generation re-checked inside the writer.
 *
 * @param identityFile device-local file holding the install id (NOT synced), so a pulled
 * document can never move it. Construction does a blocking read; build off Main.
 */
class RecFeedbackStore(
    private val file: File,
    private val scope: CoroutineScope,
    private val identityFile: File? = null,
    private val writeContext: CoroutineContext = Dispatchers.IO,
    private val saveDebounceMs: Long = SAVE_DEBOUNCE_MS,
    private val maxDecisions: Int = MAX_DECISIONS,
    private val json: Json = PdjJson.lenient,
    private val newId: () -> String = { UUID.randomUUID().toString().uppercase() },
) {
    enum class Verdict(val raw: String) {
        ACCEPTED("accepted"), REJECTED("rejected"), CLEARED("cleared");

        companion object {
            fun fromRaw(raw: String?): Verdict? = entries.firstOrNull { it.raw == raw }
        }
    }

    enum class Surface(val raw: String) {
        TILE("tile"), NOW_PLAYING("nowPlaying"), CAR_PLAY("carPlay"), WIDGET("widget"), SONG_DETAIL("songDetail")
    }

    /** One verdict row. [verdict] and [surface] stay STRINGS on the wire for forward-compat. */
    data class Decision(
        val id: String,
        /** Epoch ms. */
        val at: Double,
        val songId: String,
        /** A collection id, or the reserved "zone" / "new". */
        val scope: String,
        val verdict: String,
        val surface: String = Surface.TILE.raw,
        val artistKey: String? = null,
        val genre: String? = null,
        val originInstallId: String? = null,
        val seq: Int = 0,
    ) {
        val verdictValue: Verdict? get() = Verdict.fromRaw(verdict)
    }

    data class PlayingScope(val scope: String, val songIds: List<String>, val atMs: Double)

    data class Document(
        val schemaVersion: Int = REC_FEEDBACK_SCHEMA_VERSION,
        val installId: String,
        val decisions: List<Decision> = emptyList(),
        val playing: PlayingScope? = null,
        val seq: Int = 0,
    )

    /** Compose recompute key: bumped on every real change (record, playing scope, merge, clear). */
    data class State(val revision: Int)

    private class Derived(
        val byScope: Map<String, Verdict> = emptyMap(),
        val rejectedAt: Map<String, Double> = emptyMap(),
        val acceptedAt: Map<String, Double> = emptyMap(),
        val rejectedByScope: Map<String, Map<String, Double>> = emptyMap(),
        val acceptedByScope: Map<String, Map<String, Double>> = emptyMap(),
    )

    private val lock = Any()
    private val writeLock = Any()
    private val generation = AtomicInteger(0)

    private var rows: List<Decision> = emptyList()
    private var nextSeq = 0
    private var revisionCounter = 0
    private var saveJob: Job? = null

    @Volatile
    private var pendingSave = false

    @Volatile
    private var derived = Derived()

    var installId: String = ""
        private set

    @Volatile
    var playing: PlayingScope? = null
        private set

    private val _state = MutableStateFlow(State(0))
    val state: StateFlow<State> = _state.asStateFlow()
    val revision: Int get() = _state.value.revision

    val decisions: List<Decision> get() = synchronized(lock) { rows }
    val hasUnsavedChanges: Boolean get() = pendingSave

    init {
        val doc = readDocument()
        val stored = identityFile?.let { f -> runCatching { f.readText().trim() }.getOrNull() }?.takeIf { it.isNotEmpty() }
        if (stored != null) {
            installId = stored
        } else {
            installId = doc?.installId ?: newId()
            identityFile?.let { f ->
                runCatching { f.parentFile?.mkdirs(); f.writeText(installId) }
            }
        }
        if (doc != null) {
            rows = doc.decisions
            playing = if (doc.installId == installId) doc.playing else null
            nextSeq = maxOf(doc.seq, (doc.decisions.maxOfOrNull { it.seq } ?: 0) + 1)
        }
        rebuildIndex()
    }

    // ── Derived state ───────────────────────────────────────────────────────────────────

    private fun rebuildIndex() {
        fun newer(a: Decision, b: Decision): Boolean {
            if (a.at != b.at) return a.at > b.at
            if (a.seq != b.seq) return a.seq > b.seq
            val ao = a.originInstallId.orEmpty()
            val bo = b.originInstallId.orEmpty()
            if (ao != bo) return ao > bo
            return a.id.uppercase() > b.id.uppercase()
        }
        val bestScoped = HashMap<String, Decision>()
        val bestGlobal = HashMap<String, Decision>()
        for (d in rows) {
            val k = key(d.scope, d.songId)
            val cur = bestScoped[k]
            if (cur == null || newer(d, cur)) bestScoped[k] = d
            val g = bestGlobal[d.songId]
            if (g == null || newer(d, g)) bestGlobal[d.songId] = d
        }
        val byScope = HashMap<String, Verdict>()
        val rejectedByScope = HashMap<String, HashMap<String, Double>>()
        val acceptedByScope = HashMap<String, HashMap<String, Double>>()
        for ((k, d) in bestScoped) {
            val v = d.verdictValue ?: continue
            if (v == Verdict.CLEARED) continue
            byScope[k] = v
            if (v == Verdict.REJECTED) rejectedByScope.getOrPut(d.scope) { HashMap() }[d.songId] = d.at
            if (v == Verdict.ACCEPTED) acceptedByScope.getOrPut(d.scope) { HashMap() }[d.songId] = d.at
        }
        // The global taste opinion is the newest verdict in ANY scope (a "cleared" newest erases it).
        val rejectedAt = HashMap<String, Double>()
        val acceptedAt = HashMap<String, Double>()
        for ((songId, d) in bestGlobal) {
            when (d.verdictValue) {
                Verdict.REJECTED -> rejectedAt[songId] = d.at
                Verdict.ACCEPTED -> acceptedAt[songId] = d.at
                else -> Unit
            }
        }
        derived = Derived(byScope, rejectedAt, acceptedAt, rejectedByScope, acceptedByScope)
    }

    private fun publish() {
        _state.value = State(revisionCounter)
    }

    // ── Read ────────────────────────────────────────────────────────────────────────────

    /** The standing verdict for (song, scope); null when none or cleared. */
    fun verdict(songId: String, scope: String): Verdict? = derived.byScope[key(scope, songId)]

    /** The song's global taste verdict (rejected wins a tie, as iOS checks it first). */
    fun anyVerdict(songId: String): Verdict? {
        val d = derived
        if (d.rejectedAt[songId] != null) return Verdict.REJECTED
        if (d.acceptedAt[songId] != null) return Verdict.ACCEPTED
        return null
    }

    /** songId -> rejection time for rows still inside the 7-day window, evaluated NOW. */
    fun activeTombstones(scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): Map<String, Double> {
        val rows = derived.rejectedByScope[scope] ?: return emptyMap()
        // A FUTURE stamp (clock skew) is kept: the listener really did reject it.
        return rows.filterValues { nowMs - it < TOMBSTONE_MS }
    }

    fun acceptedInScope(scope: String): Map<String, Double> = derived.acceptedByScope[scope] ?: emptyMap()

    fun isSuppressed(songId: String, scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): Boolean {
        val at = derived.rejectedByScope[scope]?.get(songId) ?: return false
        return nowMs - at < TOMBSTONE_MS
    }

    /** Decayed taste weights (floor 0.05) for the global 👍 or 👎 set. */
    fun weights(verdict: Verdict, nowMs: Double = System.currentTimeMillis().toDouble()): Map<String, Double> {
        val d = derived
        val source = when (verdict) {
            Verdict.REJECTED -> d.rejectedAt
            Verdict.ACCEPTED -> d.acceptedAt
            Verdict.CLEARED -> emptyMap()
        }
        return source.mapValues { maxOf(0.05, PlayRecency.decay((nowMs - it.value) / MS_PER_DAY)) }
    }

    /** [ids] with tombstoned rows SUNK to the bottom (never filtered). */
    fun rankedIds(ids: List<String>, scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): List<String> {
        val p = partition(ids, scope, nowMs)
        return p.live + p.sunk
    }

    data class Partition(val live: List<String>, val sunk: List<String>)

    fun partition(ids: List<String>, scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): Partition =
        RecFeedbackOrder.sink(ids, activeTombstones(scope, nowMs))

    /** How many of [ids] are still live (not tombstoned) in [scope]. */
    fun visibleCount(ids: List<String>, scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): Int {
        val tombs = activeTombstones(scope, nowMs)
        if (tombs.isEmpty()) return ids.size
        return ids.count { it !in tombs }
    }

    /** The ZoneEngine projection for one list. Skip penalties are added by the caller. */
    fun zoneFeedback(scope: String, nowMs: Double = System.currentTimeMillis().toDouble()): ZoneEngine.Feedback {
        val suppressed = HashSet(activeTombstones(scope, nowMs).keys)
        derived.acceptedByScope[scope]?.let { suppressed.addAll(it.keys) }
        return ZoneEngine.Feedback(
            accepted = weights(Verdict.ACCEPTED, nowMs),
            rejected = weights(Verdict.REJECTED, nowMs),
            suppressed = suppressed,
        )
    }

    // ── Write ───────────────────────────────────────────────────────────────────────────

    /** Append one row. Blank song/scope -> null (nothing recorded). */
    fun record(
        songId: String,
        scope: String,
        verdict: Verdict,
        surface: Surface,
        artistKey: String? = null,
        genre: String? = null,
        atMs: Double = System.currentTimeMillis().toDouble(),
    ): Decision? {
        if (songId.isEmpty() || scope.isEmpty()) return null
        synchronized(lock) {
            nextSeq++
            val d = Decision(
                id = newId(), at = atMs, songId = songId, scope = scope, verdict = verdict.raw,
                surface = surface.raw, artistKey = artistKey, genre = genre,
                originInstallId = installId, seq = nextSeq,
            )
            var next = rows + d
            if (next.size > maxDecisions) next = next.subList(next.size - maxDecisions, next.size).toList()
            rows = next
            rebuildIndex()
            revisionCounter++
            publish()
            scheduleSave(debounce = true)
            return d
        }
    }

    /** Tap the same verdict again to undo it (writes a CLEARED row). Returns the standing verdict or null. */
    fun toggle(
        songId: String,
        to: Verdict,
        scope: String,
        surface: Surface,
        artistKey: String? = null,
        genre: String? = null,
        atMs: Double = System.currentTimeMillis().toDouble(),
    ): Verdict? {
        val next = if (verdict(songId, scope) == to) Verdict.CLEARED else to
        record(songId, scope, next, surface, artistKey, genre, atMs)
        return if (next == Verdict.CLEARED) null else next
    }

    /** Rows at or after [sinceMs], oldest first (at, then seq). */
    fun decisionsSince(sinceMs: Double): List<Decision> =
        decisions.filter { it.at >= sinceMs }.sortedWith(compareBy<Decision> { it.at }.thenBy { it.seq })

    // ── The playing scope (what a SYNC accept/reject acts on) ───────────────────────────

    /** Stamp "this queue came from [scope] and holds [songIds]" when a tile row/▶/🔀 starts playback. */
    fun beginPlayback(scope: String, songIds: List<String>, atMs: Double = System.currentTimeMillis().toDouble()) {
        synchronized(lock) {
            playing = PlayingScope(scope, songIds, atMs)
            revisionCounter++
            publish()
            scheduleSave(debounce = true)
        }
    }

    fun endPlaybackScope() {
        synchronized(lock) {
            if (playing == null) return
            playing = null
            revisionCounter++
            publish()
            scheduleSave(debounce = true)
        }
    }

    /** The scope a now-playing 👍/👎 files against: only when [songId] is in the stamped queue. */
    fun scopeForPlaying(songId: String?): String? {
        val p = playing ?: return null
        if (songId == null || songId !in p.songIds) return null
        return p.scope
    }

    // ── CloudSync + lifecycle ───────────────────────────────────────────────────────────

    /** CloudSync write seam: land the pulled payload; any stale snapshot write skips itself. */
    fun applyPulledPayload(data: ByteArray) {
        generation.incrementAndGet()
        synchronized(writeLock) { writeBytesAtomically(data) }
    }

    /** Union-by-id merge after a pull. True when we held rows the document lacked (written back). */
    fun reloadFromDisk(): Boolean {
        synchronized(lock) {
            generation.incrementAndGet()
            val doc = readDocument() ?: return false
            val byId = LinkedHashMap<String, Decision>()
            for (d in rows) byId.putIfAbsent(d.id.uppercase(), d)
            var addedFromDisk = 0
            for (d in doc.decisions) if (byId.putIfAbsent(d.id.uppercase(), d) == null) addedFromDisk++
            val weHoldRowsTheDocLacks = byId.size > doc.decisions.size
            var merged = byId.values.sortedWith(compareBy<Decision> { it.at }.thenBy { it.seq }.thenBy { it.id })
            if (merged.size > maxDecisions) merged = merged.subList(merged.size - maxDecisions, merged.size).toList()
            rows = merged
            nextSeq = maxOf(nextSeq, (merged.maxOfOrNull { it.seq } ?: 0) + 1)
            rebuildIndex()
            if (addedFromDisk > 0 || weHoldRowsTheDocLacks) {
                revisionCounter++
                publish()
            }
            if (!weHoldRowsTheDocLacks) {
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
            playing = null
            derived = Derived()
            revisionCounter++
            publish()
            save()
        }
    }

    /** Write any pending coalesced save NOW (app backgrounding). */
    fun flush() {
        synchronized(lock) {
            if (!pendingSave) return
            save()
        }
    }

    // ── Persistence ─────────────────────────────────────────────────────────────────────

    private fun scheduleSave(debounce: Boolean) {
        synchronized(lock) {
            pendingSave = true
            saveJob?.cancel()
            val doc = Document(installId = installId, decisions = rows, playing = playing, seq = nextSeq)
            val gen = generation.incrementAndGet()
            saveJob = scope.launch {
                if (debounce) {
                    delay(saveDebounceMs)
                    if (!isActive) return@launch
                }
                withContext(writeContext) {
                    synchronized(writeLock) { if (generation.get() == gen) write(doc) }
                }
                if (!isActive) return@launch
                synchronized(lock) { if (saveJob === coroutineContext[Job]) pendingSave = false }
            }
        }
    }

    private fun save() {
        synchronized(lock) {
            saveJob?.cancel()
            saveJob = null
            pendingSave = false
            generation.incrementAndGet()
            val doc = Document(installId = installId, decisions = rows, playing = playing, seq = nextSeq)
            synchronized(writeLock) { write(doc) }
        }
    }

    private fun write(doc: Document) {
        writeBytesAtomically(encodeDocument(doc).toByteArray(Charsets.UTF_8))
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

    private fun readDocument(): Document? {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return null
        return decodeDocument(text, json) { newId() }
    }

    companion object {
        const val TOMBSTONE_DAYS = 7.0
        const val MS_PER_DAY = 86_400_000.0
        const val TOMBSTONE_MS = TOMBSTONE_DAYS * MS_PER_DAY
        const val MAX_DECISIONS = 20_000
        const val SAVE_DEBOUNCE_MS = 600L

        private fun key(scope: String, songId: String) = "$scope\u0001$songId"

        private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        private fun JsonElement?.dbl(): Double? = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.doubleOrNull
        private fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.intOrNull

        /** Lenient row decode: required at/songId/scope/verdict; anything else optional. Null = skip row. */
        internal fun decodeDecision(el: JsonElement, newId: () -> String): Decision? {
            val o = el as? JsonObject ?: return null
            val at = o["at"].dbl() ?: return null
            val songId = o["songId"].str() ?: return null
            val scope = o["scope"].str() ?: return null
            val verdict = o["verdict"].str() ?: return null
            if (songId.isEmpty() || scope.isEmpty()) return null
            return Decision(
                id = o["id"].str()?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }?.uppercase() ?: newId(),
                at = at, songId = songId, scope = scope, verdict = verdict,
                surface = o["surface"].str() ?: Surface.TILE.raw,
                artistKey = o["artistKey"].str(),
                genre = o["genre"].str(),
                originInstallId = o["originInstallId"].str(),
                seq = o["seq"].int() ?: 0,
            )
        }

        /** Whole-document lenient decode (iOS `Document.init(from:)`); null when not a JSON object. */
        fun decodeDocument(text: String, json: Json = PdjJson.lenient, newId: () -> String = { UUID.randomUUID().toString().uppercase() }): Document? {
            val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            val decisions = (root["decisions"] as? JsonArray).orEmpty()
                .mapNotNull { decodeDecision(it, newId) }
                .filter { it.songId.isNotEmpty() && it.scope.isNotEmpty() }
            val playing = (root["playing"] as? JsonObject)?.let { p ->
                val scope = p["scope"].str()
                val atMs = p["atMs"].dbl()
                val ids = (p["songIds"] as? JsonArray)?.map { it.str() }
                if (scope == null || atMs == null || ids == null || ids.any { it == null }) null
                else PlayingScope(scope, ids.filterNotNull(), atMs)
            }
            return Document(
                schemaVersion = root["schemaVersion"].int() ?: REC_FEEDBACK_SCHEMA_VERSION,
                installId = root["installId"].str() ?: newId(),
                decisions = decisions,
                playing = playing,
                seq = root["seq"].int() ?: 0,
            )
        }

        private fun JsonArray?.orEmpty(): JsonArray = this ?: JsonArray(emptyList())

        private fun num(d: Double): JsonPrimitive =
            if (d == Math.floor(d) && Math.abs(d) < 9.0e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)

        fun encodeDocument(doc: Document): String = buildJsonObject {
            put("schemaVersion", doc.schemaVersion)
            put("installId", doc.installId)
            put("decisions", buildJsonArray {
                for (d in doc.decisions) add(buildJsonObject {
                    put("id", d.id)
                    put("at", num(d.at))
                    put("songId", d.songId)
                    put("scope", d.scope)
                    put("verdict", d.verdict)
                    put("surface", d.surface)
                    d.artistKey?.let { put("artistKey", it) }
                    d.genre?.let { put("genre", it) }
                    d.originInstallId?.let { put("originInstallId", it) }
                    put("seq", d.seq)
                })
            })
            doc.playing?.let { p ->
                put("playing", buildJsonObject {
                    put("scope", p.scope)
                    put("songIds", buildJsonArray { p.songIds.forEach { add(JsonPrimitive(it)) } })
                    put("atMs", num(p.atMs))
                })
            }
            put("seq", doc.seq)
        }.toString()
    }
}

/** Tombstone ordering (port of iOS `RecFeedbackOrder`). */
object RecFeedbackOrder {
    /**
     * Live rows keep their order (deduped); tombstoned rows SINK to the end, oldest rejection first
     * (ties by id). Tombstones for ids absent from [ids] are appended too, so a rejected row that a
     * refresh dropped is still reachable from the "sunk" section.
     */
    fun sink(ids: List<String>, tombstones: Map<String, Double>): RecFeedbackStore.Partition {
        if (tombstones.isEmpty()) return RecFeedbackStore.Partition(ids, emptyList())
        val live = ArrayList<String>(ids.size)
        val sunk = ArrayList<String>()
        val seen = HashSet<String>()
        for (id in ids) {
            if (!seen.add(id)) continue
            if (tombstones.containsKey(id)) sunk.add(id) else live.add(id)
        }
        for (id in tombstones.keys) if (id !in seen) sunk.add(id)
        sunk.sortWith { a, b ->
            val ta = tombstones[a] ?: 0.0
            val tb = tombstones[b] ?: 0.0
            if (ta != tb) ta.compareTo(tb) else a.compareTo(b)
        }
        return RecFeedbackStore.Partition(live, sunk)
    }
}
