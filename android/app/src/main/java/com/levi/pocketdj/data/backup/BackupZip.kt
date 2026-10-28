package com.levi.pocketdj.data.backup

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.data.collections.PlaylistSerializer
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.io.ZipIo
import com.levi.pocketdj.data.collections.sanitizePocketFlags
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.put

class BackupZipException(val notABackup: Boolean, message: String) : Exception(message)

/**
 * Reads / writes the full backup `.pocketdj.zip` — entry names identical to iOS `BackupZip.swift` and the
 * PWA `exportZip.ts`: `manifest.json`, `sources.json`, `pockets.json`, `playlists.json`, `setlists.json`,
 * `folders.json`, `edits.json` (+ optional `favorites.json`). The remote catalog (`items.json` / `art/`) is
 * NOT bundled (`portable:false`, zero counts); on read those are counted as skipped.
 */
object BackupZip {
    const val FILENAME_SUFFIX = ".pocketdj.zip"
    const val SCHEMA_VERSION = 2

    fun export(
        payload: BackupPayload,
        nowMs: Long = System.currentTimeMillis(),
        json: Json = PdjJson.lenient,
    ): ByteArray {
        val manifest = buildJsonObject {
            put("app", "pocketdj"); put("kind", "backup"); put("schemaVersion", SCHEMA_VERSION)
            put("portable", false)
            put("exportedAt", ZipIo.iso8601(nowMs))
            put("counts", buildJsonObject {
                put("sources", payload.sourcesJson.size); put("items", 0); put("art", 0)
                put("pockets", payload.pockets.size); put("playlists", payload.playlists.size)
                put("setlists", payload.setlists.size)
            })
        }
        val files = linkedMapOf(
            "manifest.json" to ZipIo.bytes(manifest, json),
            "sources.json" to ZipIo.bytes(payload.sourcesJson, json),
            "pockets.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(Pocket.serializer()), payload.pockets), json),
            "playlists.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(PlaylistSerializer), payload.playlists), json),
            "setlists.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(Setlist.serializer()), payload.setlists), json),
            "folders.json" to ZipIo.bytes(json.encodeToJsonElement(ListSerializer(PlaylistFolder.serializer()), payload.folders), json),
            "edits.json" to (payload.editsData ?: "{}".toByteArray()),
        )
        payload.favoritesData?.let { files["favorites.json"] = it }
        return ZipIo.write(files)
    }

    /** Tolerates PWA schemaVersion 1|2, a missing `kind`, and a backup without `items.json`/`art`. */
    fun import(data: ByteArray, json: Json = PdjJson.lenient): Pair<BackupPayload, SkippedCatalog> {
        val entries = ZipIo.read(data) ?: throw BackupZipException(false, "Couldn't read the backup zip.")
        parseManifest(entries["manifest.json"], json)?.let {
            if (it.app != "pocketdj") throw BackupZipException(true, "Not a PocketDJ backup.")
        }

        fun <T> list(name: String, ser: KSerializer<T>, pre: (kotlinx.serialization.json.JsonElement) -> kotlinx.serialization.json.JsonElement = { it }): List<T> {
            val arr = entries[name]?.let { runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)) }.getOrNull() } as? JsonArray
                ?: return emptyList()
            return arr.mapNotNull { runCatching { json.decodeFromJsonElement(ser, pre(it)) }.getOrNull() }
        }

        val sources = (entries["sources.json"]?.let { runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)) }.getOrNull() } as? JsonArray)
            ?: JsonArray(emptyList())
        val payload = BackupPayload(
            sourcesJson = sources,
            pockets = list("pockets.json", Pocket.serializer(), ::sanitizePocketFlags),
            playlists = list("playlists.json", PlaylistSerializer),
            setlists = list("setlists.json", Setlist.serializer()),
            folders = list("folders.json", PlaylistFolder.serializer()),
            editsData = entries["edits.json"],
            favoritesData = entries["favorites.json"],
        )
        val itemCount = (entries["items.json"]?.let { runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)) }.getOrNull() } as? JsonArray)?.size ?: 0
        val artCount = entries.keys.count { it.startsWith("art/") && it.endsWith(".webp") }
        return payload to SkippedCatalog(itemCount, artCount)
    }

    fun parseManifest(raw: ByteArray?, json: Json = PdjJson.lenient): BackupManifest? {
        raw ?: return null
        val o = runCatching { json.parseToJsonElement(String(raw, Charsets.UTF_8)) }.getOrNull() as? JsonObject ?: return null
        fun s(k: String, src: JsonObject = o) = (src[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun n(k: String, src: JsonObject) = (src[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: 0
        val c = o["counts"] as? JsonObject ?: JsonObject(emptyMap())
        return BackupManifest(
            app = s("app") ?: "", kind = s("kind"),
            schemaVersion = n("schemaVersion", o),
            portable = (o["portable"] as? JsonPrimitive)?.booleanOrNull,
            exportedAt = s("exportedAt") ?: "",
            counts = BackupManifest.Counts(n("sources", c), n("items", c), n("art", c), n("pockets", c), n("playlists", c), n("setlists", c)),
        )
    }
}
