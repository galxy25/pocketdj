package com.levi.pocketdj.data.history

import android.content.Context
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayEventBus
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Durable, append-only log of every song play on this device — the Android
 * mirror of iOS `PlayHistoryStore` (specs/history.md §2–§3). One row per play;
 * deliberately NOT an aggregate stats store (same song three times = three
 * rows). Persisted as a single JSON document written atomically (temp file +
 * rename) synchronously-ordered after every mutation, decoded leniently so a
 * later field addition never wipes the log.
 *
 * Thread-safe: mutations are serialized on an internal lock; the UI observes
 * [state] (revision-keyed — the event count pins once the cap is hit).
 *
 * Recording semantics live HERE, not at the call site: the 30 s same-song
 * re-count window absorbs seeks/restarts and any double-hook where two engines
 * both fire for one play.
 */
class PlayHistoryStore(
    private val file: File,
    private val json: Json = PdjJson.lenient,
    /** Injectable for tests; production uses [DEFAULT_MAX_EVENTS]. */
    private val maxEvents: Int = DEFAULT_MAX_EVENTS,
) {
    /** One immutable snapshot for Compose; recompute keys off [revision]. */
    data class State(
        /** The log, oldest → newest. */
        val events: List<PlayEvent>,
        /** Stable identity of THIS install (merge key for future sync). */
        val installId: String,
        /** Monotonic; bumped on every real mutation. */
        val revision: Int,
    )

    private val lock = Any()

    // Derived, non-persisted indexes rebuilt on load / trim / replace.
    private val lastPlayedIndex = HashMap<String, Double>()
    private val countIndex = HashMap<String, Int>()

    private val _state: MutableStateFlow<State>
    val state: StateFlow<State>

    /**
     * The on-disk doc couldn't be READ (transient IO — not corrupt JSON): the
     * intact file must not be clobbered by an empty in-memory log. [save] tries
     * to re-read + merge (union by event id) before its first overwrite.
     */
    private var salvagePending = false

    init {
        var loaded: PlayHistoryDocument? = null
        var needsSave = false
        when (val read = readDocument()) {
            is ReadResult.Ok -> loaded = read.doc
            ReadResult.Absent -> Unit // first launch — mint below, persist once
            ReadResult.Corrupt -> {
                // Decode failure only (lenient decode absorbs schema evolution):
                // quarantine the bytes instead of silently overwriting them.
                runCatching { file.renameTo(File(file.parentFile, file.name + ".bak")) }
            }
            ReadResult.Unreadable -> salvagePending = true // EIO/EMFILE etc.
        }
        if (loaded == null || loaded.installId.isBlank()) {
            loaded = PlayHistoryDocument(
                installId = UUID.randomUUID().toString(),
                events = loaded?.events ?: emptyList(),
            )
            // A transiently-unreadable file keeps its persisted identity+events;
            // deferring the save leaves them intact until salvage runs.
            needsSave = !salvagePending
        }
        var events = loaded.events
        if (events.size > maxEvents) {
            events = events.takeLast(maxEvents)
            needsSave = true
        }
        rebuildIndexes(events)
        _state = MutableStateFlow(State(events, loaded.installId, revision = 0))
        state = _state.asStateFlow()
        if (needsSave) synchronized(lock) { save() }
    }

    val events: List<PlayEvent> get() = _state.value.events
    val installId: String get() = _state.value.installId
    val revision: Int get() = _state.value.revision

    /** songId → most-recent `playedAt` (epoch ms). */
    fun lastPlayedAt(songId: String): Double? = synchronized(lock) { lastPlayedIndex[songId] }

    /** songId → total number of play events in the log. */
    fun playCount(songId: String): Int = synchronized(lock) { countIndex[songId] ?: 0 }

    /**
     * The one write path (specs/history.md §3). Returns the appended event, or
     * null when the play was ignored (empty songId) or absorbed by the 30 s
     * same-song re-count window. Direction guard is load-bearing: an OLDER
     * timestamp (`nowMs < last`) is a genuinely distinct play and IS recorded —
     * a negative delta must never read as "within the window".
     */
    fun record(
        songId: String,
        title: String? = null,
        artist: String? = null,
        context: PlayContext = PlayContext.BROWSER,
        nowMs: Long = System.currentTimeMillis(),
    ): PlayEvent? = synchronized(lock) {
        if (songId.isEmpty()) return null
        val nowDouble = nowMs.toDouble()
        val last = lastPlayedIndex[songId]
        if (last != null && nowDouble >= last && nowDouble - last < RECOUNT_WINDOW_MS) {
            return null // Same listen: seek / restart / double-hook.
        }
        val event = PlayEvent(
            id = UUID.randomUUID().toString(),
            songId = songId,
            playedAt = nowDouble,
            source = PlaySource.fromToken(context.source),
            contextId = context.contextId,
            contextName = context.contextName,
            title = title,
            artist = artist,
        )
        var events = _state.value.events + event
        // Max, not assignment: an out-of-order append can't move last-played back.
        lastPlayedIndex[songId] = max(lastPlayedIndex[songId] ?: 0.0, nowDouble)
        countIndex[songId] = (countIndex[songId] ?: 0) + 1
        if (events.size > maxEvents) {
            events = events.takeLast(maxEvents)
            rebuildIndexes(events)
        }
        publish(events)
        save()
        event
    }

    /** Wipe the log but KEEP the installId (Settings "clear history"). */
    fun clear() {
        synchronized(lock) {
            salvagePending = false // deliberate wipe — don't resurrect disk rows
            rebuildIndexes(emptyList())
            publish(emptyList())
            save()
        }
    }

    /** Test/merge seam: swap the whole log, re-cap, rebuild indexes, persist. */
    fun replaceAll(newEvents: List<PlayEvent>) {
        synchronized(lock) {
            salvagePending = false // deliberate swap — the new log is the truth
            val capped = if (newEvents.size > maxEvents) newEvents.takeLast(maxEvents) else newEvents
            rebuildIndexes(capped)
            publish(capped)
            save()
        }
    }

    // MARK: - Internals (call under lock)

    private fun publish(events: List<PlayEvent>) {
        _state.value = _state.value.copy(events = events, revision = _state.value.revision + 1)
    }

    private fun rebuildIndexes(events: List<PlayEvent>) {
        lastPlayedIndex.clear()
        countIndex.clear()
        for (event in events) {
            lastPlayedIndex[event.songId] = max(lastPlayedIndex[event.songId] ?: 0.0, event.playedAt)
            countIndex[event.songId] = (countIndex[event.songId] ?: 0) + 1
        }
    }

    private sealed interface ReadResult {
        data class Ok(val doc: PlayHistoryDocument) : ReadResult
        data object Absent : ReadResult

        /** Bytes read fine but didn't decode — schema evolution is absorbed by
         *  the lenient decode, so this is genuine corruption. */
        data object Corrupt : ReadResult

        /** The READ itself failed (transient IO) — the file may be intact. */
        data object Unreadable : ReadResult
    }

    private fun readDocument(): ReadResult {
        if (!file.exists()) return ReadResult.Absent
        val text = try {
            file.readText()
        } catch (_: Exception) {
            return ReadResult.Unreadable
        }
        return try {
            ReadResult.Ok(json.decodeFromString<PlayHistoryDocument>(text))
        } catch (_: Exception) {
            ReadResult.Corrupt
        }
    }

    /**
     * One-shot recovery for a launch-time transient read failure: re-read the
     * doc before the first overwrite; on success adopt its installId and union
     * its events (by event id) with anything recorded since. Call under lock.
     */
    private fun salvageIfPending() {
        if (!salvagePending) return
        salvagePending = false
        val disk = (readDocument() as? ReadResult.Ok)?.doc ?: return
        if (disk.events.isEmpty() && disk.installId.isBlank()) return
        val memory = _state.value
        val seen = disk.events.mapTo(HashSet()) { it.id }
        var events = disk.events + memory.events.filterNot { it.id in seen }
        events = events.sortedBy { it.playedAt }
        if (events.size > maxEvents) events = events.takeLast(maxEvents)
        rebuildIndexes(events)
        _state.value = State(
            events = events,
            installId = disk.installId.ifBlank { memory.installId },
            revision = memory.revision + 1,
        )
    }

    /** Atomic write: temp file + rename, ordered after every mutation. */
    private fun save() {
        salvageIfPending()
        val snapshot = _state.value
        val doc = PlayHistoryDocument(
            schemaVersion = PLAY_HISTORY_SCHEMA_VERSION,
            installId = snapshot.installId,
            events = snapshot.events,
        )
        try {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(PlayHistoryDocument.serializer(), doc))
            if (!tmp.renameTo(file)) {
                file.delete()
                if (!tmp.renameTo(file)) tmp.copyTo(file, overwrite = true)
            }
        } catch (_: Exception) {
            // Persistence is best-effort; the in-memory log stays authoritative.
        }
    }

    companion object {
        /** iOS parity: `pocketdj-play-history.json` in the app-private dir. */
        const val FILE_NAME = "pocketdj-play-history.json"

        /** Append-only cap; oldest events are dropped past it. */
        const val DEFAULT_MAX_EVENTS = 20_000

        /** Same-song re-count window (specs/history.md §3 step 2). */
        const val RECOUNT_WINDOW_MS = 30_000L

        @Volatile
        private var instance: PlayHistoryStore? = null

        /**
         * Process-wide store; the first call also starts collecting the core
         * play-event seam ([PlayEventBus]) so every play records regardless of
         * which screen is open. Call once at app launch (ideally off-main —
         * construction reads the log from disk).
         */
        fun get(context: Context): PlayHistoryStore =
            instance ?: synchronized(this) {
                instance ?: PlayHistoryStore(
                    File(context.applicationContext.filesDir, FILE_NAME),
                ).also { store ->
                    instance = store
                    CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
                        PlayEventBus.events.collect { played ->
                            store.record(
                                songId = played.songId,
                                title = played.title,
                                artist = played.artist,
                                context = played.context,
                                nowMs = played.atMs,
                            )
                        }
                    }
                }
            }
    }
}
