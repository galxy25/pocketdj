package com.levi.pocketdj.data.timeline

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonObject

/**
 * Named bookmarks on the Collection timeline's add-date axis (iOS `TimelineCueStore`). NOT the
 * Studio/Mix audio cues. Whole-document JSON (`pocketdj-timeline-cues.json`), lenient per-cue
 * decode (one bad cue is dropped, not the list), always sorted oldest to newest by atMs.
 */
class TimelineCueStore(
    private val file: File,
    private val json: Json = PdjJson.lenient,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
) {
    @Serializable
    data class Cue(
        val id: String,
        val name: String,
        val atMs: Double,
        val createdAtMs: Double? = null,
        val note: String? = null,
    )

    data class State(val cues: List<Cue>, val revision: Int)

    private val lock = Any()
    private var saveVersion = 0L
    private val _state = MutableStateFlow(State(load(), 0))
    val state: StateFlow<State> = _state.asStateFlow()

    val cues: List<Cue> get() = _state.value.cues

    private fun load(): List<Cue> = decode(file)?.sortedWith(ORDER) ?: emptyList()

    private fun decode(f: File): List<Cue>? {
        val text = runCatching { f.readText() }.getOrNull() ?: return null
        return decodeDocument(text, json)
    }

    fun add(name: String, atMs: Double, nowMs: Double = System.currentTimeMillis().toDouble()): Cue? {
        val n = clean(name)
        if (n.isEmpty() || atMs <= 0) return null
        val cue = Cue(UUID.randomUUID().toString(), n, atMs, nowMs)
        synchronized(lock) { publish(trimToCap(cues + cue)) }
        return cue
    }

    fun rename(id: String, to: String): Boolean = synchronized(lock) {
        val n = clean(to)
        val i = cues.indexOfFirst { it.id == id }
        if (n.isEmpty() || i < 0 || cues[i].name == n) return false
        publish(cues.toMutableList().also { it[i] = it[i].copy(name = n) })
        true
    }

    fun move(id: String, toMs: Double): Boolean = synchronized(lock) {
        val i = cues.indexOfFirst { it.id == id }
        if (toMs <= 0 || i < 0 || cues[i].atMs == toMs) return false
        publish(cues.toMutableList().also { it[i] = it[i].copy(atMs = toMs) })
        true
    }

    fun remove(id: String): Boolean = synchronized(lock) {
        if (cues.none { it.id == id }) return false
        publish(cues.filterNot { it.id == id })
        true
    }

    fun replaceAll(newCues: List<Cue>) = synchronized(lock) { publish(trimToCap(newCues)) }

    /** Account deletion: remove the persisted file entirely. */
    fun clear() = synchronized(lock) {
        writer.delete(++saveVersion)
        _state.value = State(emptyList(), _state.value.revision + 1)
    }

    /** The cue nearest [atMs] within [toleranceMs], else null. */
    fun nearest(atMs: Double, toleranceMs: Double): Cue? =
        cues.minByOrNull { kotlin.math.abs(it.atMs - atMs) }?.takeIf { kotlin.math.abs(it.atMs - atMs) <= toleranceMs }

    /** Adopt the on-disk document after a sync pull (whole-document LWW). Always returns false. */
    fun reloadFromDisk(): Boolean = synchronized(lock) {
        val incoming = decode(file)?.sortedWith(ORDER) ?: return false
        if (incoming != cues) _state.value = State(incoming, _state.value.revision + 1)
        false
    }

    private fun trimToCap(list: List<Cue>): List<Cue> {
        if (list.size <= MAX_CUES) return list
        val doomed = list.sortedBy { it.createdAtMs ?: 0.0 }.take(list.size - MAX_CUES).map { it.id }.toSet()
        return list.filterNot { it.id in doomed }
    }

    private fun publish(list: List<Cue>) {
        val sorted = list.sortedWith(ORDER)
        _state.value = State(sorted, _state.value.revision + 1)
        val doc = encodeDocument(sorted, json)
        writer.write(++saveVersion) { doc }
    }

    companion object {
        const val FILE_NAME = "pocketdj-timeline-cues.json"
        const val SCHEMA_VERSION = 1
        const val MAX_CUES = 500
        const val MAX_NAME_LENGTH = 60

        private val ORDER = Comparator<Cue> { a, b ->
            if (a.atMs != b.atMs) a.atMs.compareTo(b.atMs) else a.id.uppercase().compareTo(b.id.uppercase())
        }

        fun clean(s: String): String = s.trim().take(MAX_NAME_LENGTH)

        /** Lenient: missing `cues` gives empty, an undecodable cue is dropped. Null if not JSON at all. */
        fun decodeDocument(text: String, json: Json = PdjJson.lenient): List<Cue>? {
            val root = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return null
            val arr = root["cues"] as? JsonArray ?: return emptyList()
            return arr.mapNotNull { el ->
                runCatching { json.decodeFromJsonElement(Cue.serializer(), el) }.getOrNull()
            }
        }

        fun encodeDocument(cues: List<Cue>, json: Json = PdjJson.lenient): String {
            val obj: JsonObject = buildJsonObject {
                put("schemaVersion", SCHEMA_VERSION)
                put("cues", JsonArray(cues.map { json.encodeToJsonElement(Cue.serializer(), it) }))
            }
            return json.encodeToString(JsonObject.serializer(), obj)
        }
    }
}
