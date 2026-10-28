package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.PlaylistSerializer
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.sanitizePocketFlags
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Why a collection zip could not be read (iOS `PlaylistZipError` / `PocketZipError`). */
class CollectionZipException(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { NOT_AN_EXPORT, ARCHIVE_UNREADABLE, MISSING_ROOT }
}

/**
 * Reads / writes the single-playlist transfer — `.playlist.pocketdj.zip` / the `.playlist.pdjcollection`
 * rename of it (iOS `Services/PlaylistZip.swift`, PWA `playlistTransfer.ts`).
 *
 * Entries: `manifest.json` ({app, kind:"playlist", schemaVersion:1, portable, exportedAt,
 * playlistName, counts:{items,pockets,setlists,art}}), `playlist.json`, `pockets.json` (DAG-expanded,
 * may be `[]`), and in PORTABLE mode `items.json` ([PortableItems], PWA `MusicItem[]` shape). `art/`
 * and `setlists.json` are tolerated on read, never consumed.
 *
 * Unlike iOS' fresh-id reminting import, [read] PRESERVES ids so the importer's match-by-id merge makes
 * a re-import a no-op (COL-14 doctrine); [remintBundle] is kept for a deliberate "import as copy".
 */
object PlaylistZip {
    const val FILENAME_SUFFIX = ".playlist.pocketdj.zip"
    const val COLLECTION_SUFFIX = ".playlist.pdjcollection"

    data class Bundle(val playlist: Playlist, val pockets: List<Pocket>, val items: PortableItems.Payload)

    /**
     * Build the zip. PORTABLE (items.json bundled) whenever the caller hands a non-empty catalog;
     * otherwise the slim pass-1 shape.
     */
    fun export(
        playlist: Playlist,
        pocketsById: Map<String, Pocket>,
        songsById: Map<String, IndexSong> = emptyMap(),
        albumsById: Map<String, IndexAlbum> = emptyMap(),
        nowMs: Long = System.currentTimeMillis(),
        json: Json = PdjJson.lenient,
    ): ByteArray {
        val pockets = referencedPockets(playlist, pocketsById)
        val portable = songsById.isNotEmpty() || albumsById.isNotEmpty()
        var itemsData: ByteArray? = null
        var itemCount = 0
        if (portable) {
            val ids = PortableItems.referencedIds(playlist, pockets)
            val arr = PortableItems.encodeElement(ids.songs, ids.albums, songsById, albumsById, nowMs)
            itemCount = arr.size
            itemsData = ZipIo.bytes(arr, json)
        }
        val manifest = buildJsonObject {
            put("app", "pocketdj"); put("kind", "playlist"); put("schemaVersion", 1)
            put("portable", portable)
            put("exportedAt", ZipIo.iso8601(nowMs))
            put("playlistName", playlist.name)
            put("counts", buildJsonObject {
                put("items", itemCount); put("pockets", pockets.size); put("setlists", 0); put("art", 0)
            })
        }
        val files = linkedMapOf(
            "manifest.json" to ZipIo.bytes(manifest, json),
            "playlist.json" to ZipIo.bytes(json.encodeToJsonElement(PlaylistSerializer, playlist), json),
            "pockets.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(Pocket.serializer()), pockets), json),
        )
        if (itemsData != null) files["items.json"] = itemsData
        return ZipIo.write(files)
    }

    /**
     * Pockets a playlist references, DAG-expanded (child pockets pulled in), resolved against
     * [pocketsById]. Cycle-guarded; only USER pockets travel.
     */
    fun referencedPockets(playlist: Playlist, pocketsById: Map<String, Pocket>): List<Pocket> {
        val roots = ArrayList<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) when (n.kind) {
                PlaylistNode.Kind.POCKET -> n.pocketId?.let(roots::add)
                PlaylistNode.Kind.SEQUENCE -> walk(n.children.orEmpty())
                else -> Unit
            }
        }
        walk(playlist.sequences)
        val out = ArrayList<Pocket>()
        val seen = HashSet<String>()
        val queue = ArrayDeque(roots)
        while (queue.isNotEmpty()) {
            val pid = queue.removeLast()
            if (!seen.add(pid)) continue
            val p = pocketsById[pid] ?: continue
            out += p
            queue.addAll(p.childPocketIds)
        }
        return out
    }

    /**
     * Read the zip into its playlist + referenced pockets with ids PRESERVED. Version-tolerant: a
     * missing manifest is allowed, extra manifest fields ignored; a manifest that self-identifies as
     * something other than a pocketdj playlist export is refused.
     */
    fun read(data: ByteArray, json: Json = PdjJson.lenient): Bundle {
        val entries = ZipIo.read(data)
            ?: throw CollectionZipException(CollectionZipException.Reason.ARCHIVE_UNREADABLE, "Couldn't read the playlist zip.")
        ZipManifest.requireKind(entries, "playlist", json) {
            CollectionZipException(CollectionZipException.Reason.NOT_AN_EXPORT, "Not a PocketDJ playlist export.")
        }
        val plRaw = entries["playlist.json"]
            ?: throw CollectionZipException(CollectionZipException.Reason.MISSING_ROOT, "Playlist export is missing playlist.json.")
        val playlist = try {
            json.decodeFromString(PlaylistSerializer, String(plRaw, Charsets.UTF_8))
        } catch (_: Exception) {
            throw CollectionZipException(CollectionZipException.Reason.NOT_AN_EXPORT, "Not a PocketDJ playlist export.")
        }
        val pockets = ZipManifest.decodePockets(entries["pockets.json"], json)
        val items = entries["items.json"]?.let { PortableItems.decode(it, json) } ?: PortableItems.Payload()
        return Bundle(playlist, pockets, items)
    }

    /**
     * Mint fresh ids for the playlist + its pockets + every node id and remap intra-bundle refs (iOS
     * `remintBundle`). amPlaylistId is stripped. Refs to pockets NOT in the bundle stay as-is.
     */
    fun remintBundle(playlist: Playlist, pockets: List<Pocket>, nowMs: Double = System.currentTimeMillis().toDouble()): Pair<Playlist, List<Pocket>> {
        val idMap = pockets.associate { it.id to CollectionsFactory.newPocketId() }
        val newPockets = pockets.map { p ->
            p.copy(
                id = idMap[p.id] ?: CollectionsFactory.newPocketId(),
                childPocketIds = p.childPocketIds.map { idMap[it] ?: it },
                createdAt = nowMs, updatedAt = nowMs, amPlaylistId = null,
            )
        }
        fun remint(n: PlaylistNode): PlaylistNode = n.copy(
            nodeId = CollectionsFactory.newNodeId(),
            pocketId = n.pocketId?.let { idMap[it] ?: it },
            children = n.children?.map(::remint),
        )
        val pl = playlist.copy(
            id = CollectionsFactory.newPlaylistId(),
            sequences = playlist.sequences.map(::remint),
            createdAt = nowMs, updatedAt = nowMs, amPlaylistId = null,
        )
        return pl to newPockets
    }
}

/** Manifest sniffing + shared `pockets.json` decode for the zip codecs. */
internal object ZipManifest {
    fun parse(entries: Map<String, ByteArray>, json: Json): JsonObject? =
        entries["manifest.json"]?.let {
            runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)) }.getOrNull() as? JsonObject
        }

    fun str(o: JsonObject, k: String): String? = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** A present, decodable manifest must say app=pocketdj + [kind]; absent/undecodable passes (version tolerance). */
    fun requireKind(entries: Map<String, ByteArray>, kind: String, json: Json, err: () -> Exception) {
        val man = parse(entries, json) ?: return
        if ((str(man, "app") ?: "") != "pocketdj" || (str(man, "kind") ?: "") != kind) throw err()
    }

    fun decodePockets(raw: ByteArray?, json: Json): List<Pocket> {
        raw ?: return emptyList()
        val arr = runCatching { json.parseToJsonElement(String(raw, Charsets.UTF_8)) }.getOrNull() as? JsonArray
            ?: return emptyList()
        return arr.mapNotNull { el ->
            runCatching { json.decodeFromJsonElement(Pocket.serializer(), sanitizePocketFlags(el)) }.getOrNull()
        }
    }
}
