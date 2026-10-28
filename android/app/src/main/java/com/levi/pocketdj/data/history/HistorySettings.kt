package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.data.settings.ClauseDoc
import com.levi.pocketdj.data.settings.PrefKey
import kotlinx.serialization.Serializable

/**
 * History's own persisted filter/sort state (iOS `pdj.history.v1`) — a DataStore key distinct
 * from Browse's `browseSnapshotJson` so the two surfaces never clobber each other (BRW-6).
 * The search query and the Hide-skips lens are TRANSIENT and deliberately not in here.
 * Every field is optional with a default (additive-optional iron law).
 */
@Serializable
data class HistorySnapshot(
    val clauses: List<ClauseDoc> = emptyList(),
    val sortKeys: List<BrowseSortKeyDoc> = emptyList(),
)

object HistorySettings {
    /** Persisted DataStore key name — never rename once shipped. */
    val SNAPSHOT_JSON = PrefKey.string("historySnapshotJson", "")

    fun encode(snapshot: HistorySnapshot): String =
        PdjJson.lenient.encodeToString(HistorySnapshot.serializer(), snapshot)

    /** Lenient decode: missing / blank / corrupt -> defaults, never a crash. */
    fun decode(raw: String?): HistorySnapshot {
        if (raw.isNullOrBlank()) return HistorySnapshot()
        return runCatching { PdjJson.lenient.decodeFromString(HistorySnapshot.serializer(), raw) }
            .getOrDefault(HistorySnapshot())
    }

    suspend fun load(store: AppSettingsStore): HistorySnapshot = decode(store.get(SNAPSHOT_JSON))

    suspend fun save(store: AppSettingsStore, snapshot: HistorySnapshot) =
        store.set(SNAPSHOT_JSON, encode(snapshot))
}
