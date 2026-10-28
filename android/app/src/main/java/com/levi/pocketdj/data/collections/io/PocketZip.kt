package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.sanitizePocketFlags
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Standalone single-pocket transfer — `.pocket.pocketdj.zip` / `.pocket.pdjcollection` (iOS
 * `Services/PocketZip.swift`). Entries: `manifest.json` ({app, kind:"pocket", schemaVersion:1,
 * portable, exportedAt, pocketName, counts:{pockets,art,items}}), `pocket.json` (the root),
 * `pockets.json` (DAG-expanded children, root NOT duplicated), optional `items.json`.
 */
object PocketZip {
    const val FILENAME_SUFFIX = ".pocket.pocketdj.zip"
    const val COLLECTION_SUFFIX = ".pocket.pdjcollection"

    data class Bundle(val pocket: Pocket, val children: List<Pocket>, val items: PortableItems.Payload)

    fun export(
        pocket: Pocket,
        pocketsById: Map<String, Pocket>,
        songsById: Map<String, IndexSong> = emptyMap(),
        albumsById: Map<String, IndexAlbum> = emptyMap(),
        nowMs: Long = System.currentTimeMillis(),
        json: Json = PdjJson.lenient,
    ): ByteArray {
        val children = referencedChildren(pocket, pocketsById)
        val portable = songsById.isNotEmpty() || albumsById.isNotEmpty()
        var itemsData: ByteArray? = null
        var itemCount = 0
        if (portable) {
            val ids = PortableItems.referencedIds(pocket, children)
            val arr = PortableItems.encodeElement(ids.songs, ids.albums, songsById, albumsById, nowMs)
            itemCount = arr.size
            itemsData = ZipIo.bytes(arr, json)
        }
        val manifest = buildJsonObject {
            put("app", "pocketdj"); put("kind", "pocket"); put("schemaVersion", 1)
            put("portable", portable)
            put("exportedAt", ZipIo.iso8601(nowMs))
            put("pocketName", pocket.name)
            put("counts", buildJsonObject {
                put("pockets", children.size + 1); put("art", 0); put("items", itemCount)
            })
        }
        val files = linkedMapOf(
            "manifest.json" to ZipIo.bytes(manifest, json),
            "pocket.json" to ZipIo.bytes(json.encodeToJsonElement(Pocket.serializer(), pocket), json),
            "pockets.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(Pocket.serializer()), children), json),
        )
        if (itemsData != null) files["items.json"] = itemsData
        return ZipIo.write(files)
    }

    /** Child pockets a pocket references, DAG-expanded (grandchildren too), cycle-guarded, root excluded. */
    fun referencedChildren(pocket: Pocket, pocketsById: Map<String, Pocket>): List<Pocket> {
        val out = ArrayList<Pocket>()
        val seen = hashSetOf(pocket.id)
        val queue = ArrayDeque(pocket.childPocketIds)
        while (queue.isNotEmpty()) {
            val pid = queue.removeLast()
            if (!seen.add(pid)) continue
            val p = pocketsById[pid] ?: continue
            out += p
            queue.addAll(p.childPocketIds)
        }
        return out
    }

    /** Read with ids PRESERVED (see [PlaylistZip.read]). */
    fun read(data: ByteArray, json: Json = PdjJson.lenient): Bundle {
        val entries = ZipIo.read(data)
            ?: throw CollectionZipException(CollectionZipException.Reason.ARCHIVE_UNREADABLE, "Couldn't read the pocket zip.")
        ZipManifest.requireKind(entries, "pocket", json) {
            CollectionZipException(CollectionZipException.Reason.NOT_AN_EXPORT, "Not a PocketDJ pocket export.")
        }
        val rootRaw = entries["pocket.json"]
            ?: throw CollectionZipException(CollectionZipException.Reason.MISSING_ROOT, "Pocket export is missing pocket.json.")
        val root = try {
            json.decodeFromJsonElement(
                Pocket.serializer(),
                sanitizePocketFlags(json.parseToJsonElement(String(rootRaw, Charsets.UTF_8))),
            )
        } catch (_: Exception) {
            throw CollectionZipException(CollectionZipException.Reason.NOT_AN_EXPORT, "Not a PocketDJ pocket export.")
        }
        val children = ZipManifest.decodePockets(entries["pockets.json"], json)
        val items = entries["items.json"]?.let { PortableItems.decode(it, json) } ?: PortableItems.Payload()
        return Bundle(root, children, items)
    }

    /** Fresh ids for the root + every child; child refs remapped (iOS `remintBundle`). */
    fun remintBundle(root: Pocket, children: List<Pocket>, nowMs: Double = System.currentTimeMillis().toDouble()): Pair<Pocket, List<Pocket>> {
        val idMap = HashMap<String, String>()
        idMap[root.id] = CollectionsFactory.newPocketId()
        children.forEach { idMap[it.id] = CollectionsFactory.newPocketId() }
        fun remint(p: Pocket) = p.copy(
            id = idMap[p.id] ?: CollectionsFactory.newPocketId(),
            childPocketIds = p.childPocketIds.map { idMap[it] ?: it },
            createdAt = nowMs, updatedAt = nowMs,
        )
        return remint(root) to children.map(::remint)
    }
}
