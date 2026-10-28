package com.levi.pocketdj.data.credentials

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

/**
 * The iCloud/S3-synced connection subset ("settings-credentials" doc, file
 * `pocketdj-settings-credentials.json`). Field names are the iOS Codable keys so the document is
 * wire-compatible. Optional fields are omitted when null (Swift's synthesized encode does the same).
 *
 * Android never adopts [sources] / [appleMusicPrivateSync] but RE-EMITS whatever was last pulled or on disk
 * (as raw JSON), so an iOS doc round-trips through Android without losing its catalog.
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
    /** Pass-through (raw JSON, never interpreted): re-emitted exactly as pulled so iOS keeps its catalog. */
    val appleMusicPrivateSync: JsonElement? = null,
    /** Pass-through (raw JSON, unknown SourceConfig fields survive): Android never adopts or edits it. */
    val sources: JsonElement? = null,
) {
    /** Strings trimmed (the settings setters trim) and pass-through dropped: the CONTENT used for change detection. */
    fun normalized(): SettingsCredentialsDocument = copy(
        ripServerURL = ripServerURL.trim(), ripToken = ripToken.trim(),
        jukeboxServerURL = jukeboxServerURL.trim(), jukeboxToken = jukeboxToken.trim(),
        searchAccessKeyID = searchAccessKeyID.trim(), searchSecretKey = searchSecretKey.trim(),
        searchEndpoint = searchEndpoint.trim(),
        appleMusicPrivateSync = null, sources = null,
    )

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
         * Deterministic bytes (recursively sorted keys, nulls dropped). NOT byte-identical to Swift (which
         * escapes `/`), so change detection is by decoded CONTENT ([normalized]), never by bytes.
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
