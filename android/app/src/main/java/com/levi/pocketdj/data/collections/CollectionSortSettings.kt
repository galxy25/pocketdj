package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.data.settings.ClauseDoc
import com.levi.pocketdj.data.settings.PrefKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/**
 * One collection's remembered sort + filter (iOS `BrowseState` persisted under the per-collection
 * key `pdj.collection.<id>`). Primitives only so the data layer stays independent of `screens.*`.
 * Every field is optional with a default (additive-optional iron law). The text query is
 * transient and deliberately not here.
 */
@Serializable
data class CollectionSortDoc(
    val clauses: List<ClauseDoc> = emptyList(),
    val sortKeys: List<BrowseSortKeyDoc> = emptyList(),
) {
    /** A doc that constrains nothing is equivalent to "no entry" (default order, no filter). */
    val isEmpty: Boolean get() = clauses.isEmpty() && sortKeys.isEmpty()
}

/**
 * Per-collection sort/filter persistence: ONE DataStore string holding a JSON map
 * `{"pdj.collection.<id>": CollectionSortDoc}`. Independent of the Browse session
 * (`browseSnapshotJson`) and of History (`historySnapshotJson`) so the surfaces never clobber
 * each other. Corrupt / missing JSON decodes to an empty map, never a crash.
 */
object CollectionSortSettings {
    /** Persisted DataStore key name — never rename once shipped. */
    val MAP_JSON = PrefKey.string("collectionSortMapJson", "")

    const val KEY_PREFIX = "pdj.collection."

    /** The per-collection persistence key (iOS `pdj.collection.<id>`). */
    fun key(collectionId: String): String = "$KEY_PREFIX$collectionId"

    private val mapSerializer = MapSerializer(String.serializer(), CollectionSortDoc.serializer())

    fun encode(map: Map<String, CollectionSortDoc>): String =
        PdjJson.lenient.encodeToString(mapSerializer, map)

    fun decode(raw: String?): Map<String, CollectionSortDoc> {
        if (raw.isNullOrBlank()) return emptyMap()
        return runCatching { PdjJson.lenient.decodeFromString(mapSerializer, raw) }
            .getOrDefault(emptyMap())
    }

    /** The doc for [collectionId] in [raw], or the empty default. */
    fun docFor(raw: String?, collectionId: String): CollectionSortDoc =
        decode(raw)[key(collectionId)] ?: CollectionSortDoc()

    /**
     * Pure map update: an empty doc REMOVES the entry (default order needs no storage), every
     * other collection's entry is untouched.
     */
    fun withEntry(raw: String?, collectionId: String, doc: CollectionSortDoc): String {
        val map = decode(raw).toMutableMap()
        if (doc.isEmpty) map.remove(key(collectionId)) else map[key(collectionId)] = doc
        return encode(map)
    }

    suspend fun load(store: AppSettingsStore, collectionId: String): CollectionSortDoc =
        docFor(store.get(MAP_JSON), collectionId)

    suspend fun save(store: AppSettingsStore, collectionId: String, doc: CollectionSortDoc) {
        store.update(MAP_JSON) { withEntry(it, collectionId, doc) }
    }
}
