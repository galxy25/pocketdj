package com.levi.pocketdj.data.credentials

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

/** iOS `SourceConfig` wire shape (`urlString`, UUID `id`). Decoded for compat; Android neither pushes nor applies it. */
@Serializable
data class SyncedSource(
    val id: String = "",
    val name: String = "",
    val urlString: String = "",
    val enabled: Boolean = true,
)

/**
 * The iCloud/S3-synced connection subset ("settings-credentials" doc, file
 * `pocketdj-settings-credentials.json`). Field names are the iOS Codable keys so the document is
 * wire-compatible. Optional fields are omitted when null (Swift's synthesized encode does the same).
 *
 * Android never pushes [sources] (its source ids are not UUIDs, which would fail the iOS decode of
 * the whole document) and never applies a pulled list; [appleMusicPrivateSync] is not an Android setting.
 */
@Serializable
data class SettingsCredentialsDocument(
    val schemaVersion: Int = 1,
    val ripServerURL: String = "",
    val ripToken: String = "",
    val jukeboxServerURL: String = "",
    val jukeboxToken: String = "",
    val jukeboxTokensRequiredByDefault: Boolean = true,
    val searchAccessKeyID: String = "",
    val searchSecretKey: String = "",
    val searchEndpoint: String = "",
    val appleMusicPrivateSync: Boolean? = null,
    val sources: List<SyncedSource>? = null,
) {
    /**
     * Every user-entered synced field at its fresh-install value => the doc must not materialize.
     * (sources / appleMusicPrivateSync are deliberately ignored, as on iOS.)
     */
    val credentialsAreBlank: Boolean
        get() = ripServerURL.isEmpty() && ripToken.isEmpty() &&
            jukeboxServerURL.isEmpty() && jukeboxToken.isEmpty() &&
            jukeboxTokensRequiredByDefault &&
            searchAccessKeyID.isEmpty() && searchSecretKey.isEmpty() && searchEndpoint.isEmpty()

    companion object {
        const val KEY = "settings-credentials"
        const val FILE_NAME = "pocketdj-settings-credentials.json"

        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /**
         * Deterministic bytes (recursively sorted keys, nulls dropped) so equal content encodes
         * identically on every device: the content compare and the pull -> re-persist round trip depend
         * on it, or every pull would re-dirty the file and LWW would ping-pong.
         */
        fun encode(doc: SettingsCredentialsDocument): ByteArray =
            canonical(json.encodeToJsonElement(serializer(), doc)).toString().toByteArray(Charsets.UTF_8)

        fun decode(bytes: ByteArray): SettingsCredentialsDocument? =
            runCatching { json.decodeFromString(serializer(), bytes.toString(Charsets.UTF_8)) }.getOrNull()

        internal fun canonical(e: JsonElement): JsonElement = when (e) {
            is JsonObject -> JsonObject(
                e.entries.filter { it.value !is JsonNull }.sortedBy { it.key }
                    .associate { it.key to canonical(it.value) }, // LinkedHashMap keeps the sorted order
            )
            is JsonArray -> JsonArray(e.map { canonical(it) })
            else -> e
        }
    }
}
