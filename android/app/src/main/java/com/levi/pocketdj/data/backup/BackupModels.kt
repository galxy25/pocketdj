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
