package com.levi.pocketdj.data.pockets.wheel

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.io.File
import kotlin.math.max

/**
 * The Pocket Wheel's colour language (iOS `PocketPaletteStore`): 12 perceptually spaced colours assigned to
 * collections automatically and kept STABLE - a slot, once given, never moves, and is freed only 30 days after
 * the collection stops being dominant anywhere (or is deleted). Synced as `pocket-palette`.
 *
 * Convergent merge: per collection the EARLIER `(assignedAtMs, slot)` wins, `lastSeenMs` is MAX-merged, a slot
 * claimed twice after a merge stays with its earlier owner and the later one is re-seated at the lowest free slot.
 *
 * File `pocketdj-pocket-palette.json`: `{"schemaVersion":1,"entries":{id:{slot,assignedAtMs,lastSeenMs}}}`,
 * decoded per entry leniently (one malformed entry never drops the palette). Unknown top-level keys are kept
 * and re-emitted (D7).
 */
class PocketPaletteStore(private val file: File) {

    data class Entry(val slot: Int, val assignedAtMs: Double, val lastSeenMs: Double)

    private val lock = Any()
    private var entriesRef: Map<String, Entry> = emptyMap()
    private var passthrough: Map<String, JsonElement> = emptyMap()

    /** Bumped on every change (observers repaint). */
    @Volatile var revision: Int = 0
        private set

    /** Fired (outside the lock) after the entries changed. */
    @Volatile var onChanged: (() -> Unit)? = null

    init {
        val doc = decode(file)
        entriesRef = normalized(doc.entries)
        passthrough = doc.extras
    }

    val entries: Map<String, Entry> get() = synchronized(lock) { entriesRef }

    /** The slot of a collection, or null (overflow / never dominant). */
    fun slot(id: String): Int? = entries[id]?.slot

    /** The colour reference for a collection id: a palette slot, the overflow hash, or mixed for null. */
    fun swatch(id: String?): PocketSwatch {
        if (id == null) return PocketSwatch.Mixed
        entries[id]?.slot?.let { return PocketSwatch.Slot(it) }
        return PocketSwatch.Overflow(PocketSwatch.overflowHue(id))
    }

    /**
     * Fold one wheel build in. [dominantOrder] = every collection dominant in at least one cell, in DESCENDING
     * global dominance. Newcomers take free slots in that order; dominant collections' lastSeen moves to [nowMs];
     * collections unseen for 30 days (or [deleted]) free their slots first. `fav_songs` is never freed.
     * Returns whether anything changed (then it saved).
     */
    fun assign(dominantOrder: List<String>, deleted: Set<String> = emptySet(), nowMs: Double): Boolean {
        val changed: Boolean
        synchronized(lock) {
            val next = entriesRef.toMutableMap()
            val dominant = dominantOrder.toSet()
            for ((id, e) in entriesRef) {
                if (id == FAV_SONGS_ID) continue
                if (deleted.contains(id) || nowMs - e.lastSeenMs > FREE_AFTER_MS) {
                    if (id in dominant && id !in deleted) continue
                    next.remove(id)
                }
            }
            for (id in dominantOrder) {
                val e = next[id] ?: continue
                next[id] = e.copy(lastSeenMs = max(e.lastSeenMs, nowMs))
            }
            val used = next.values.map { it.slot }.toMutableSet()
            for (id in dominantOrder) {
                if (next.containsKey(id) || id in deleted) continue
                val free = (0 until SLOT_COUNT).firstOrNull { it !in used } ?: break
                next[id] = Entry(free, nowMs, nowMs)
                used.add(free)
            }
            changed = next != entriesRef
            if (changed) { entriesRef = next; revision++; save() }
        }
        if (changed) onChanged?.invoke()
        return changed
    }

    /**
     * Merge a peer's document (sync pull rewrote the file). Saves only when we hold something the pulled doc
     * lacks (an unconditional save after every pull ping-pongs two devices forever). Returns true when it re-saved.
     */
    fun reloadFromDisk(): Boolean {
        val doc = decode(file)
        var resaved = false
        var changed = false
        synchronized(lock) {
            val merged = merge(entriesRef, doc.entries)
            if (merged != entriesRef) { entriesRef = merged; revision++; changed = true }
            if (doc.extras.isNotEmpty()) passthrough = passthrough + doc.extras
            if (merged != normalized(doc.entries)) { save(); resaved = true }
        }
        if (changed) onChanged?.invoke()
        return resaved
    }

    /** Account deletion / reset: forget everything and remove the file. */
    fun clear() {
        synchronized(lock) {
            entriesRef = emptyMap(); passthrough = emptyMap(); revision++
            runCatching { file.delete() }
        }
        onChanged?.invoke()
    }

    private fun save() {
        runCatching {
            val bytes = encode(entriesRef, passthrough).toByteArray()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
        }
    }

    internal class Document(val entries: Map<String, Entry>, val extras: Map<String, JsonElement>)

    companion object {
        const val FILE_NAME = "pocketdj-pocket-palette.json"
        const val SYNC_KEY = "pocket-palette"
        const val SLOT_COUNT = 12
        const val FREE_AFTER_MS: Double = 30.0 * 86_400_000
        /** The Favorites pseudo-collection keeps its colour forever. */
        const val FAV_SONGS_ID = "fav_songs"

        /**
         * Resolve slot collisions deterministically: the earliest assignment keeps a slot; later claimants move to
         * the lowest free slot (or drop when none is free). Also drops out-of-range slots.
         */
        fun normalized(entries: Map<String, Entry>): Map<String, Entry> {
            val ordered = entries.entries.filter { it.value.slot in 0 until SLOT_COUNT }
                .sortedWith(compareBy({ it.value.assignedAtMs }, { it.value.slot }, { it.key }))
            val used = mutableSetOf<Int>()
            val out = LinkedHashMap<String, Entry>()
            val bumped = mutableListOf<Pair<String, Entry>>()
            for ((id, e) in ordered) if (used.add(e.slot)) out[id] = e else bumped += id to e
            for ((id, e) in bumped) {
                val free = (0 until SLOT_COUNT).firstOrNull { it !in used } ?: continue
                used.add(free)
                out[id] = e.copy(slot = free)
            }
            return out
        }

        /** The pure, order-independent merge. */
        fun merge(a: Map<String, Entry>, b: Map<String, Entry>): Map<String, Entry> {
            val out = LinkedHashMap<String, Entry>()
            for (id in a.keys + b.keys) {
                val x = a[id]; val y = b[id]
                out[id] = when {
                    x != null && y != null -> {
                        val xFirst = x.assignedAtMs < y.assignedAtMs ||
                            (x.assignedAtMs == y.assignedAtMs && x.slot <= y.slot)
                        val w = if (xFirst) x else y
                        Entry(w.slot, w.assignedAtMs, max(x.lastSeenMs, y.lastSeenMs))
                    }
                    else -> x ?: y!!
                }
            }
            return normalized(out)
        }

        internal fun decode(file: File): Document {
            val root = runCatching { Json.parseToJsonElement(file.readText()) as? JsonObject }.getOrNull()
                ?: return Document(emptyMap(), emptyMap())
            val raw = root["entries"] as? JsonObject
            val entries = LinkedHashMap<String, Entry>()
            raw?.forEach { (id, el) ->
                val o = el as? JsonObject ?: return@forEach
                val slot = (o["slot"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return@forEach
                val at = (o["assignedAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return@forEach
                val seen = (o["lastSeenMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: return@forEach
                entries[id] = Entry(slot, at, seen)
            }
            val extras = root.filterKeys { it != "schemaVersion" && it != "entries" }
            return Document(entries, extras)
        }

        /** Whole-number doubles print without ".0", as Swift's JSONEncoder does. */
        private fun num(d: Double): JsonPrimitive =
            if (d == Math.floor(d) && Math.abs(d) < 9e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)

        internal fun encode(entries: Map<String, Entry>, extras: Map<String, JsonElement>): String {
            val obj = buildJsonObject {
                extras.forEach { (k, v) -> put(k, v) }
                put("schemaVersion", 1)
                put("entries", buildJsonObject {
                    entries.toSortedMap().forEach { (id, e) ->
                        put(id, buildJsonObject {
                            put("slot", e.slot)
                            put("assignedAtMs", num(e.assignedAtMs))
                            put("lastSeenMs", num(e.lastSeenMs))
                        })
                    }
                })
            }
            return obj.toString()
        }
    }
}
