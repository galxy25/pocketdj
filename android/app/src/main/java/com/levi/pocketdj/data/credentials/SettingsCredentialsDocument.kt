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
    /** Pass-through (raw JSON, never interpreted): re-emitted exactly as pulled so iOS keeps its catalog. */
    val appleMusicPrivateSync: JsonElement? = null,
    /** Pass-through (raw JSON, unknown SourceConfig fields survive): Android never adopts or edits it. */
    val sources: JsonElement? = null,
    /**
     * Q10: the online-search key pair + endpoint are DEVICE-LOCAL on Android (Keystore / DataStore) and are never
     * read from or written to this document. iOS decodes `searchAccessKeyID` / `searchSecretKey` / `searchEndpoint`
     * as REQUIRED strings, so empty strings are ALWAYS emitted; a carried value ([passThroughSearch], decode only) is
     * scrubbed on the next sync. NOT serialized by the plugin (see [encode]/[decode]).
     */
    @kotlinx.serialization.Transient
    val passThroughSearch: JsonObject? = null,
) {
    /** True when a decoded doc still carries a non-empty search value (legacy Android / iOS) that must be scrubbed. */
    val carriesSearchValues: Boolean
        get() = passThroughSearch?.values?.any { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.isNotEmpty() == true } == true

    /** Strings trimmed (the settings setters trim) and pass-through dropped: the CONTENT used for change detection. */
    fun normalized(): SettingsCredentialsDocument = copy(
        ripServerURL = ripServerURL.trim(), ripToken = ripToken.trim(),
        jukeboxServerURL = jukeboxServerURL.trim(), jukeboxToken = jukeboxToken.trim(),
        appleMusicPrivateSync = null, sources = null, passThroughSearch = null,
    )

    /**
     * Every user-entered synced field at its fresh-install value => the doc must not materialize.
     * (sources / appleMusicPrivateSync are deliberately ignored, as on iOS.)
     */
    val credentialsAreBlank: Boolean
        get() = ripServerURL.isEmpty() && ripToken.isEmpty() &&
            jukeboxServerURL.isEmpty() && jukeboxToken.isEmpty() &&
            jukeboxTokensRequiredByDefault

    companion object {
        const val KEY = "settings-credentials"
        const val FILE_NAME = "pocketdj-settings-credentials.json"

        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /**
         * Deterministic bytes (recursively sorted keys, nulls dropped). NOT byte-identical to Swift (which
         * escapes `/`), so change detection is by decoded CONTENT ([normalized]), never by bytes.
         */
        fun encode(doc: SettingsCredentialsDocument): ByteArray {
            val base = json.encodeToJsonElement(serializer(), doc) as JsonObject
            val withSearch = JsonObject(base + searchWireKeys(doc.passThroughSearch))
            return canonical(withSearch).toString().toByteArray(Charsets.UTF_8)
        }

        fun decode(bytes: ByteArray): SettingsCredentialsDocument? = runCatching {
            val text = bytes.toString(Charsets.UTF_8)
            val doc = json.decodeFromString(serializer(), text)
            val obj = json.parseToJsonElement(text) as? JsonObject
            val search = obj?.let { o -> SEARCH_KEYS.filter { it in o }.associateWith { o.getValue(it) } }
            doc.copy(passThroughSearch = search?.takeIf { it.isNotEmpty() }?.let(::JsonObject))
        }.getOrNull()

        /** The iOS wire keys Android never interprets (see [passThroughSearch]). */
        val SEARCH_KEYS = listOf("searchAccessKeyID", "searchSecretKey", "searchEndpoint")

        /** Q10: ALWAYS blank strings (iOS requires the keys); a carried value is never re-emitted. */
        private fun searchWireKeys(@Suppress("UNUSED_PARAMETER") kept: JsonObject?): Map<String, JsonElement> =
            SEARCH_KEYS.associateWith { kotlinx.serialization.json.JsonPrimitive("") }

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
