package com.levi.pocketdj.data.collections

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Hand-written (de)serializers for the parts of the collections document where
 * kotlinx codegen can't express the iOS contract (specs/collections-schema.md §4):
 *
 * 1. LOSSY PER-ELEMENT decode — the document's `playlists` array, every
 *    playlist's `sequences` array, and every node's `children` array drop an
 *    element that fails WITHOUT zeroing the list (the v5 total-loss insurance).
 * 2. `PlaylistNode.nodeId`/`kind` are REQUIRED with NO defaults, and an unknown
 *    `kind` string THROWS (so the enclosing lossy array drops just that node) —
 *    never silently coerce an unknown kind to a known one.
 * 3. `Playlist`'s five required fields (`id`/`name`/`sequences`/`createdAt`/
 *    `updatedAt`) throw when missing, so a broken playlist drops (that playlist
 *    only).
 *
 * Encoding stays symmetric with iOS: nulls omitted, timestamps as plain numeric
 * epoch ms (integral when possible).
 */

// MARK: - Strict field readers (present-but-wrong-type THROWS, like iOS decodeIfPresent)

private fun JsonObject.stringOrThrow(key: String): String {
    val el = this[key] ?: throw SerializationException("missing $key")
    return (el as? JsonPrimitive)?.takeIf { it.isString }?.content
        ?: throw SerializationException("$key must be a string")
}

private fun JsonObject.optString(key: String): String? {
    val el = this[key] ?: return null
    if (el is JsonNull) return null
    return (el as? JsonPrimitive)?.takeIf { it.isString }?.content
        ?: throw SerializationException("$key must be a string")
}

private fun JsonObject.optLong(key: String): Long? {
    val el = this[key] ?: return null
    if (el is JsonNull) return null
    val p = el as? JsonPrimitive ?: throw SerializationException("$key must be a number")
    if (p.isString) throw SerializationException("$key must be a number")
    return p.longOrNull ?: p.doubleOrNull?.toLong()
        ?: throw SerializationException("$key must be a number")
}

private fun JsonObject.optInt(key: String): Int? = optLong(key)?.toInt()

private fun JsonObject.optDouble(key: String): Double? {
    val el = this[key] ?: return null
    if (el is JsonNull) return null
    val p = el as? JsonPrimitive ?: throw SerializationException("$key must be a number")
    if (p.isString) throw SerializationException("$key must be a number")
    return p.doubleOrNull ?: throw SerializationException("$key must be a number")
}

private fun JsonObject.doubleOrThrow(key: String): Double =
    optDouble(key) ?: throw SerializationException("missing $key")

private fun JsonObject.optBoolean(key: String): Boolean? {
    val el = this[key] ?: return null
    if (el is JsonNull) return null
    val p = el as? JsonPrimitive ?: throw SerializationException("$key must be a boolean")
    return when (p.content) {
        "true" -> true
        "false" -> false
        else -> throw SerializationException("$key must be a boolean")
    }
}

private fun JsonObject.optStringList(key: String): List<String>? {
    val el = this[key] ?: return null
    if (el is JsonNull) return null
    val arr = el as? JsonArray ?: throw SerializationException("$key must be an array")
    return arr.map {
        (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content
            ?: throw SerializationException("$key must contain strings")
    }
}

/** Decode a JsonArray element-lossily: a failing element drops, the list survives. */
internal fun <T> lossyElements(json: Json, array: JsonArray, serializer: KSerializer<T>): List<T> =
    array.mapNotNull { element ->
        runCatching { json.decodeFromJsonElement(serializer, element) }.getOrNull()
    }

// MARK: - PlaylistNode

object PlaylistNodeSerializer : KSerializer<PlaylistNode> {
    override val descriptor = buildClassSerialDescriptor("PlaylistNode")

    override fun deserialize(decoder: Decoder): PlaylistNode {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("PlaylistNode decodes from JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("node must be an object")
        // REQUIRED — a missing nodeId/kind throws; an UNKNOWN kind string throws
        // (the point: the enclosing lossy array drops just this node; a default
        // here would silently rewrite data and persist the corruption).
        val nodeId = obj.stringOrThrow("nodeId")
        val kindToken = obj.stringOrThrow("kind")
        val kind = PlaylistNode.Kind.fromToken(kindToken)
            ?: throw SerializationException("unknown node kind: $kindToken")
        // `children` recurses lossily, so a bad grandchild drops only itself.
        val children: List<PlaylistNode>? = obj["children"]?.let { el ->
            if (el is JsonNull) {
                null
            } else {
                val arr = el as? JsonArray ?: throw SerializationException("children must be an array")
                lossyElements(input.json, arr, PlaylistNodeSerializer)
            }
        }
        return PlaylistNode(
            nodeId = nodeId,
            kind = kind,
            songId = obj.optString("songId"),
            albumId = obj.optString("albumId"),
            pocketId = obj.optString("pocketId"),
            text = obj.optString("text"),
            name = obj.optString("name"),
            targetMs = obj.optLong("targetMs"),
            children = children,
            note = obj.optString("note"),
            repeatCount = obj.optInt("repeatCount"),
        )
    }

    override fun serialize(encoder: Encoder, value: PlaylistNode) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("PlaylistNode encodes to JSON only")
        output.encodeJsonElement(nodeToJson(value))
    }

    private fun nodeToJson(node: PlaylistNode): JsonObject = buildJsonObject {
        put("nodeId", node.nodeId)
        put("kind", node.kind.token)
        node.songId?.let { put("songId", it) }
        node.albumId?.let { put("albumId", it) }
        node.pocketId?.let { put("pocketId", it) }
        node.text?.let { put("text", it) }
        node.name?.let { put("name", it) }
        node.targetMs?.let { put("targetMs", it) }
        node.children?.let { kids -> put("children", JsonArray(kids.map(::nodeToJson))) }
        node.note?.let { put("note", it) }
        node.repeatCount?.let { put("repeatCount", it) }
    }
}

// MARK: - Playlist

object PlaylistSerializer : KSerializer<Playlist> {
    override val descriptor = buildClassSerialDescriptor("Playlist")

    override fun deserialize(decoder: Decoder): Playlist {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("Playlist decodes from JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("playlist must be an object")
        // Five REQUIRED fields (iOS parity): a playlist missing one is dropped by
        // the document's lossy [Playlist] — that playlist only, never the list.
        val sequencesEl = obj["sequences"] as? JsonArray
            ?: throw SerializationException("sequences must be an array")
        return Playlist(
            id = obj.stringOrThrow("id"),
            name = obj.stringOrThrow("name"),
            description = obj.optString("description"),
            // LOSSY per element: one undecodable / unknown-kind chapter node
            // drops that chapter slot only.
            sequences = lossyElements(input.json, sequencesEl, PlaylistNodeSerializer),
            targetMs = obj.optLong("targetMs"),
            folderId = obj.optString("folderId"),
            sourcePlaylistId = obj.optString("sourcePlaylistId"),
            sourceName = obj.optString("sourceName"),
            sourceSongIds = obj.optStringList("sourceSongIds"),
            sourceSyncEnabled = obj.optBoolean("sourceSyncEnabled"),
            sourceSyncedAt = obj.optDouble("sourceSyncedAt"),
            lastPlayedAt = obj.optDouble("lastPlayedAt"),
            createdAt = obj.doubleOrThrow("createdAt"),
            updatedAt = obj.doubleOrThrow("updatedAt"),
        )
    }

    override fun serialize(encoder: Encoder, value: Playlist) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("Playlist encodes to JSON only")
        val obj = buildJsonObject {
            put("id", value.id)
            put("name", value.name)
            value.description?.let { put("description", it) }
            put(
                "sequences",
                JsonArray(
                    value.sequences.map { output.json.encodeToJsonElement(PlaylistNodeSerializer, it) },
                ),
            )
            value.targetMs?.let { put("targetMs", it) }
            value.folderId?.let { put("folderId", it) }
            value.sourcePlaylistId?.let { put("sourcePlaylistId", it) }
            value.sourceName?.let { put("sourceName", it) }
            value.sourceSongIds?.let { ids -> put("sourceSongIds", JsonArray(ids.map(::JsonPrimitive))) }
            value.sourceSyncEnabled?.let { put("sourceSyncEnabled", it) }
            value.sourceSyncedAt?.let { put("sourceSyncedAt", epochMsPrimitive(it)) }
            value.lastPlayedAt?.let { put("lastPlayedAt", epochMsPrimitive(it)) }
            put("createdAt", epochMsPrimitive(value.createdAt))
            put("updatedAt", epochMsPrimitive(value.updatedAt))
        }
        output.encodeJsonElement(obj)
    }
}

// MARK: - Document codec + migration

object CollectionsCodec {
    /**
     * Field-level lenient document decode (iOS `CollectionsDocument.init(from:)`):
     * every field coalesces to its default on failure — a bad `pockets` value can
     * never wipe `playlists` — and the `playlists` list drops undecodable elements
     * per element. A non-object root throws (genuine corruption → the store
     * quarantines the file).
     */
    fun decode(json: Json, text: String): CollectionsDocument {
        val root = json.parseToJsonElement(text) as? JsonObject
            ?: throw SerializationException("collections document must be a JSON object")

        fun <T> lossyList(key: String, serializer: KSerializer<T>): List<T> {
            val arr = root[key] as? JsonArray ?: return emptyList()
            return lossyElements(json, arr, serializer)
        }

        val doc = CollectionsDocument(
            schemaVersion = (root["schemaVersion"] as? JsonPrimitive)?.intOrNull ?: 0,
            pockets = lossyList("pockets", Pocket.serializer()),
            playlists = lossyList("playlists", PlaylistSerializer),
            setlists = lossyList("setlists", Setlist.serializer()),
            folders = lossyList("folders", PlaylistFolder.serializer()),
            lastAddTarget = root["lastAddTarget"]?.let { el ->
                runCatching { json.decodeFromJsonElement(AddTarget.serializer(), el) }.getOrNull()
            },
            recentAddTargets = root["recentAddTargets"]?.let { el ->
                runCatching {
                    json.decodeFromJsonElement(ListSerializer(AddTarget.serializer()), el)
                }.getOrNull()
            },
        )
        return if (doc.schemaVersion < COLLECTIONS_SCHEMA_VERSION) {
            CollectionsMigration.migrate(doc)
        } else {
            doc
        }
    }

    fun encode(json: Json, doc: CollectionsDocument): String =
        json.encodeToString(CollectionsDocument.serializer(), doc)
}

object CollectionsMigration {
    /**
     * Migrate an older document forward. Every step v0→v7 is the identity no-op
     * — each addition was an optional field whose lenient-decode default IS the
     * migrated value (see specs/collections-schema.md §2.2 for the bump history).
     * Kept as an explicit seam (exactly like iOS) so a future non-identity
     * transform has a home and the version stamp is visible.
     */
    fun migrate(document: CollectionsDocument): CollectionsDocument =
        document.copy(schemaVersion = COLLECTIONS_SCHEMA_VERSION)
}
