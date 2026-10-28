package com.levi.pocketdj.data.activity

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json

/**
 * Device-local, APPEND-ONLY log of user collection acts (add / heart / unheart
 * / remove) — the Android mirror of iOS `CollectionActivityStore`
 * (specs/activity-favorites.md §2–§3).
 *
 * Deliberately a SEPARATE store from PlayHistoryStore: an add/heart/remove has
 * no re-count window and no per-song aggregate; bolting it onto PlayEvent would
 * corrupt the play-log reads. Same durable-JSON idiom though: atomic writes,
 * corrupt-quarantine to `.bak`, transient-IO salvage (union by event id),
 * revision-keyed Compose state.
 *
 * USER-ONLY GUARANTEE: events are recorded only for acts the user performs —
 * the collections store fires its `onActivity` hook exclusively from the
 * user-facing add/remove choke points (never source-sync reconcile or decode),
 * and this store simply records what arrives.
 */
class CollectionActivityStore(
    private val file: File,
    private val json: Json = PdjJson.lenient,
    /** Injectable for tests; production uses [DEFAULT_MAX_EVENTS]. */
    private val maxEvents: Int = DEFAULT_MAX_EVENTS,
    /** Version-ordered writer; production wires a background executor. */
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
) {
    private var saveVersion = 0L

    /** One immutable snapshot; recompute keys off [revision], never `events.size`. */
    data class State(
        /** The log, oldest → newest. No derived indexes — aggregate-free by design. */
        val events: List<ActivityEvent>,
        /** Stable identity of THIS install (merge attribution key). */
        val installId: String,
        /** Monotonic; bumped on every real mutation. */
        val revision: Int,
    )

    private val lock = Any()
    private val _state: MutableStateFlow<State>
    val state: StateFlow<State>

    /** See PlayHistoryStore: an unreadable (not corrupt) file must not be clobbered. */
    private var salvagePending = false

    init {
        var loaded: ActivityDocument? = null
        var needsSave = false
        when (val read = readDocument()) {
            is ReadResult.Ok -> loaded = read.doc
            ReadResult.Absent -> Unit
            ReadResult.Corrupt -> {
                runCatching { file.renameTo(File(file.parentFile, file.name + ".bak")) }
            }
            ReadResult.Unreadable -> salvagePending = true
        }
        if (loaded == null || loaded.installId.isBlank()) {
            loaded = ActivityDocument(
                installId = UUID.randomUUID().toString(),
                events = loaded?.events ?: emptyList(),
            )
            needsSave = !salvagePending
        }
        var events = loaded.events
        if (events.size > maxEvents) {
            events = events.takeLast(maxEvents)
            needsSave = true
        }
        _state = MutableStateFlow(State(events, loaded.installId, revision = 0))
        state = _state.asStateFlow()
        if (needsSave) synchronized(lock) { save() }
    }

    val events: List<ActivityEvent> get() = _state.value.events
    val installId: String get() = _state.value.installId
    val revision: Int get() = _state.value.revision

    /**
     * The one write path. Returns the appended event, or null when ignored
     * (empty itemId). NO dedup window — every user act is its own event (a
     * deliberate contrast with the play log's 30 s window: a window here would
     * eat a legitimate quick add-then-remove).
     */
    fun record(
        kind: ActivityKind,
        itemId: String,
        itemTitle: String? = null,
        collectionId: String? = null,
        collectionKind: String? = null,
        collectionName: String? = null,
        atMs: Double = System.currentTimeMillis().toDouble(),
        itemArtist: String? = null,
        libraryWrite: String? = null,
    ): ActivityEvent? = synchronized(lock) {
        if (itemId.isEmpty()) return null
        val event = ActivityEvent(
            id = UUID.randomUUID().toString(),
            at = atMs,
            kind = kind,
            itemId = itemId,
            itemTitle = itemTitle,
            itemArtist = itemArtist,
            collectionId = collectionId,
            collectionKind = collectionKind,
            collectionName = collectionName,
            originInstallId = _state.value.installId,
            libraryWrite = libraryWrite,
        )
        var events = _state.value.events + event
        if (events.size > maxEvents) events = events.takeLast(maxEvents)
        publish(events)
        save()
        event
    }

    /**
     * Batch write path: appends one event per [Entry] under ONE publish + ONE
     * save (a select-all add is one write). Empty itemIds are skipped.
     */
    fun recordAll(kind: ActivityKind, entries: List<Entry>, atMs: Double = System.currentTimeMillis().toDouble()): Int =
        synchronized(lock) {
            val fresh = entries.filter { it.itemId.isNotEmpty() }.map {
                ActivityEvent(
                    id = UUID.randomUUID().toString(),
                    at = atMs,
                    kind = kind,
                    itemId = it.itemId,
                    itemTitle = it.itemTitle,
                    itemArtist = it.itemArtist,
                    collectionId = it.collectionId,
                    collectionKind = it.collectionKind,
                    collectionName = it.collectionName,
                    originInstallId = _state.value.installId,
                )
            }
            if (fresh.isEmpty()) return 0
            var events = _state.value.events + fresh
            if (events.size > maxEvents) events = events.takeLast(maxEvents)
            publish(events)
            save()
            fresh.size
        }

    data class Entry(
        val itemId: String,
        val itemTitle: String? = null,
        val itemArtist: String? = null,
        val collectionId: String? = null,
        val collectionKind: String? = null,
        val collectionName: String? = null,
    )

    /** Test/merge seam: swap the whole log, re-cap, bump, persist. */
    fun replaceAll(newEvents: List<ActivityEvent>) {
        synchronized(lock) {
            salvagePending = false // deliberate swap — the new log is the truth
            val capped = if (newEvents.size > maxEvents) newEvents.takeLast(maxEvents) else newEvents
            publish(capped)
            save()
        }
    }

    /**
     * Wipe the log — deletes the on-disk file entirely (no residual empty
     * JSON), KEEPS the installId, bumps revision. No Settings UI calls this on
     * P2 (iOS's only caller is account deletion); it exists for tests/future.
     */
    fun clear() {
        synchronized(lock) {
            salvagePending = false
            publish(emptyList())
            dirty = false
            writer.delete(++saveVersion)
        }
    }

    // MARK: Internals (call under lock)

    private fun publish(events: List<ActivityEvent>) {
        _state.value = _state.value.copy(events = events, revision = _state.value.revision + 1)
    }

    private sealed interface ReadResult {
        data class Ok(val doc: ActivityDocument) : ReadResult
        data object Absent : ReadResult
        data object Corrupt : ReadResult
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
            ReadResult.Ok(json.decodeFromString<ActivityDocument>(text))
        } catch (_: Exception) {
            ReadResult.Corrupt
        }
    }

    /** One-shot union-by-event-id recovery before the first overwrite. */
    private fun salvageIfPending() {
        if (!salvagePending) return
        salvagePending = false
        val disk = (readDocument() as? ReadResult.Ok)?.doc ?: return
        if (disk.events.isEmpty() && disk.installId.isBlank()) return
        val memory = _state.value
        val seen = disk.events.mapTo(HashSet()) { it.id }
        var events = disk.events + memory.events.filterNot { it.id in seen }
        events = events.sortedBy { it.at }
        if (events.size > maxEvents) events = events.takeLast(maxEvents)
        _state.value = State(
            events = events,
            installId = disk.installId.ifBlank { memory.installId },
            revision = memory.revision + 1,
        )
    }

    /** Atomic write: temp file + rename, ordered after every mutation. */
    /** True when a mutation was handed to the writer and no inline flush has superseded it. */
    private var dirty = false

    private fun save() {
        salvageIfPending()
        dirty = true
        val snapshot = _state.value
        val doc = ActivityDocument(
            schemaVersion = COLLECTION_ACTIVITY_SCHEMA_VERSION,
            installId = snapshot.installId,
            events = snapshot.events,
        )
        val version = ++saveVersion
        writer.write(version) { json.encodeToString(ActivityDocument.serializer(), doc) }
    }

    /** ON_STOP barrier: supersede queued writes, write the latest log inline. */
    fun flushNow() = synchronized(lock) {
        // Untouched since the last write: never rewrite (an Unreadable launch must not clobber disk).
        if (!dirty) return@synchronized
        salvageIfPending()
        dirty = false
        val snapshot = _state.value
        val doc = ActivityDocument(
            schemaVersion = COLLECTION_ACTIVITY_SCHEMA_VERSION,
            installId = snapshot.installId,
            events = snapshot.events,
        )
        val version = ++saveVersion
        writer.flushNow(version) { json.encodeToString(ActivityDocument.serializer(), doc) }
    }

    companion object {
        /** iOS parity: `pocketdj-collection-activity.json` in the app-private dir. */
        const val FILE_NAME = "pocketdj-collection-activity.json"

        /** Append-only cap; the oldest events drop past it (same as the play log). */
        const val DEFAULT_MAX_EVENTS = 20_000
    }
}
