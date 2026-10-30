package com.levi.pocketdj.data.backup

import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.settings.SourceConfig
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Full-backup `.pocketdj.zip` models (iOS `Services/BackupZip.swift`). The manifest mirrors the PWA's
 * `ExportManifest`; `kind` is absent in PWA exports (native writes "backup"). Every field decodes
 * leniently.
 */
data class BackupManifest(
    val app: String = "pocketdj",
    val kind: String? = "backup",
    val schemaVersion: Int = BackupZip.SCHEMA_VERSION,
    val portable: Boolean? = false,
    val exportedAt: String = "",
    val counts: Counts = Counts(),
) {
    data class Counts(
        val sources: Int = 0,
        val items: Int = 0,
        val art: Int = 0,
        val pockets: Int = 0,
        val playlists: Int = 0,
        val setlists: Int = 0,
    )
}

/**
 * Decoded payload of a native full backup. [sourcesJson], [editsData] and [favoritesData] stay RAW so the
 * owning stores' own codecs decide what to adopt (iOS keeps `edits`/`favorites` as `Data`). Null in a
 * backup that lacks the entry (PWA / pre-favorites backups) ⇒ "nothing to merge".
 */
data class BackupPayload(
    val sourcesJson: JsonArray = JsonArray(emptyList()),
    val pockets: List<Pocket> = emptyList(),
    val playlists: List<Playlist> = emptyList(),
    val setlists: List<Setlist> = emptyList(),
    val folders: List<PlaylistFolder> = emptyList(),
    val editsData: ByteArray? = null,
    val favoritesData: ByteArray? = null,
)

/** Catalog items / art present in a backup but not consumed by native (the remote catalog resolves by id). */
data class SkippedCatalog(val items: Int, val art: Int)

/**
 * iOS `SourceConfig` wire shape ({id: UUID string, name, urlString, enabled}) ⇄ Android [SourceConfig]
 * ({id, name, url, enabled}). Entries that aren't objects with a name + url are dropped (a PWA
 * `DataSource[]` carries no `urlString`, so it is skipped, never fatal).
 */
object BackupSources {
    /**
     * iOS `SourceConfig.id` is a `UUID` and the whole array decodes strictly, so ONE non-UUID id would drop
     * every source on restore. Android ids ("vinyl", "apple-music") become a deterministic name-based UUID.
     */
    fun wireId(id: String): String =
        runCatching { java.util.UUID.fromString(id).toString().uppercase() }.getOrNull()
            ?: java.util.UUID.nameUUIDFromBytes(id.toByteArray(Charsets.UTF_8)).toString().uppercase()

    fun toWire(sources: List<SourceConfig>): JsonArray = JsonArray(sources.map {
        buildJsonObject {
            put("id", wireId(it.id)); put("name", it.name); put("urlString", it.url); put("enabled", it.enabled)
        }
    })

    /** The local source an incoming (wire) source denotes: wire-id, then url, then name; null = genuinely new. */
    fun matchLocal(local: List<SourceConfig>, incoming: SourceConfig): SourceConfig? =
        local.firstOrNull { wireId(it.id) == wireId(incoming.id) }
            ?: local.firstOrNull { it.url.trim().equals(incoming.url.trim(), ignoreCase = true) }
            ?: local.firstOrNull { it.name.trim().equals(incoming.name.trim(), ignoreCase = true) }

    /** SET-2 merge helper: keep every local source as-is, append only incoming sources with no local match. */
    fun merge(local: List<SourceConfig>, incoming: List<SourceConfig>): List<SourceConfig> {
        val out = ArrayList(local)
        for (inc in incoming) if (matchLocal(out, inc) == null) out += inc
        return out
    }

    fun fromWire(arr: JsonArray): List<SourceConfig> = arr.mapNotNull { el: JsonElement ->
        val o = el as? JsonObject ?: return@mapNotNull null
        fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val name = s("name") ?: return@mapNotNull null
        val url = s("urlString") ?: s("url") ?: return@mapNotNull null
        val id = s("id") ?: return@mapNotNull null
        SourceConfig(id = id, name = name, url = url, enabled = (o["enabled"] as? JsonPrimitive)?.booleanOrNull ?: true)
    }
}

/**
 * `edits.json` (iOS `EditsDocument`): `{schemaVersion, albums:{id:AlbumEdit}, songs:{id:SongEdit}, meta?}`.
 * Kept at JSON level so unknown/future edit fields round-trip untouched. Merge = iOS `EditsStore.importData`:
 * per id the IMPORTED edit wins; ids absent from the import are kept.
 */
object BackupEdits {
    const val SCHEMA_VERSION = 2

    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    private fun parse(data: ByteArray?): JsonObject? =
        data?.let { runCatching { json.parseToJsonElement(String(it, Charsets.UTF_8)) }.getOrNull() } as? JsonObject

    private fun map(o: JsonObject?, k: String): JsonObject = o?.get(k) as? JsonObject ?: JsonObject(emptyMap())

    /** Number of per-item edits (albums + songs) in [data]; 0 for junk/empty. */
    fun count(data: ByteArray?): Int = parse(data)?.let { map(it, "albums").size + map(it, "songs").size } ?: 0

    /** Number of incoming per-item edits that are new or differ from [local] (what a merge would change). */
    fun changedCount(local: ByteArray?, incoming: ByteArray?): Int {
        val inc = parse(incoming) ?: return 0
        val loc = parse(local)
        return listOf("albums", "songs").sumOf { k ->
            val l = map(loc, k)
            map(inc, k).count { (id, v) -> l[id] != v }
        }
    }

    /** Re-stamp schemaVersion + meta (iOS `EditsStore.exportData` does the same) so exports never carry a stale origin. */
    fun restamp(data: ByteArray?, appVersion: String = "", now: java.time.Instant = java.time.Instant.now()): ByteArray? {
        val o = parse(data) ?: return data
        val out = buildJsonObject {
            put("schemaVersion", SCHEMA_VERSION)
            put("albums", map(o, "albums"))
            put("songs", map(o, "songs"))
            o.forEach { (k, v) -> if (k !in setOf("schemaVersion", "albums", "songs", "meta")) put(k, v) }
            put("meta", buildJsonObject {
                put("exportedAt", now.toString()); put("appVersion", appVersion); put("platform", "Android")
            })
        }
        return out.toString().toByteArray(Charsets.UTF_8)
    }

    /** Merged document bytes, or null when [incoming] is junk / carries no edits (nothing to change). */
    fun merge(local: ByteArray?, incoming: ByteArray?): ByteArray? {
        val inc = parse(incoming) ?: return null
        if (count(incoming) == 0) return null
        val loc = parse(local)
        val albums = LinkedHashMap(map(loc, "albums")).apply { putAll(map(inc, "albums")) }
        val songs = LinkedHashMap(map(loc, "songs")).apply { putAll(map(inc, "songs")) }
        val out = buildJsonObject {
            put("schemaVersion", SCHEMA_VERSION)
            put("albums", JsonObject(albums))
            put("songs", JsonObject(songs))
            (loc?.get("meta") ?: inc["meta"])?.let { put("meta", it) }
        }
        return out.toString().toByteArray(Charsets.UTF_8)
    }
}

/**
 * File-backed `edits.json`. KNOWN GAP (COL-14 PARTIAL): no catalog overlay consumes it on Android yet, so restored
 * edits are preserved and round-trip to iOS backups but are NOT applied to Browse/Now Playing/Mix.
 */
class BackupEditsStore(private val file: java.io.File) {
    @Synchronized fun exportData(): ByteArray? = rawBytes()?.let { BackupEdits.restamp(it) }

    private fun rawBytes(): ByteArray? = runCatching { file.takeIf { it.exists() }?.readBytes() }.getOrNull()

    /** Merge a backup's edits; returns how many incoming edits were new or changed (0 = already up to date). */
    @Synchronized fun importMerging(incoming: ByteArray?): Int {
        val local = rawBytes()
        val changed = BackupEdits.changedCount(local, incoming)
        if (changed == 0) return 0
        val merged = BackupEdits.merge(local, incoming) ?: return 0
        file.parentFile?.mkdirs()
        val tmp = java.io.File(file.path + ".tmp")
        tmp.writeBytes(merged)
        if (!tmp.renameTo(file)) { file.writeBytes(merged); tmp.delete() }
        return changed
    }
}
