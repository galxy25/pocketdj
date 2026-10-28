package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey

/**
 * Storage soft-cap preferences (iOS `storageSoftCapGB` / `storageSoftCapSongs` /
 * `lastStoragePruneAt`). The DataStore has no nullable keys, so "unset" (iOS nil) is a
 * non-positive value: no cap set => the app NEVER deletes media on its own.
 */
object StorageSettings {
    val SOFT_CAP_GB = PrefKey.double("storageSoftCapGB", 0.0)
    val SOFT_CAP_SONGS = PrefKey.int("storageSoftCapSongs", 0)
    val LAST_PRUNE_AT = PrefKey.long("lastStoragePruneAt", 0L)

    /** Decimal GB (1 GB = 10^9 bytes) — what Files/Settings show the user. */
    const val BYTES_PER_GB = 1_000_000_000.0

    /** 20 h (not 24) so a "daily at breakfast" cadence keeps qualifying instead of drifting. */
    const val PRUNE_INTERVAL_MS = 20L * 3600 * 1000

    /** Evictions per chunk before yielding. */
    const val EVICTION_CHUNK = 25
}

/** The cap in force; a null field is "no such cap". Both null never happens (resolve returns null instead). */
data class ActiveCap(val bytes: Long?, val songs: Int?)

/** What the prune engine needs from settings — a port so JVM tests need no DataStore. */
interface StorageSettingsPort {
    suspend fun capGB(): Double?
    suspend fun capSongs(): Int?
    suspend fun lastPruneAt(): Long?
    /** Durable before it returns: this stamp is what breaks a crash loop. */
    suspend fun stampPrune(nowMs: Long)
}

class DataStoreStorageSettings(private val store: AppSettingsStore) : StorageSettingsPort {
    override suspend fun capGB(): Double? = store.get(StorageSettings.SOFT_CAP_GB).takeIf { it > 0.0 }
    override suspend fun capSongs(): Int? = store.get(StorageSettings.SOFT_CAP_SONGS).takeIf { it > 0 }
    override suspend fun lastPruneAt(): Long? = store.get(StorageSettings.LAST_PRUNE_AT).takeIf { it > 0L }
    override suspend fun stampPrune(nowMs: Long) = store.set(StorageSettings.LAST_PRUNE_AT, nowMs)

    suspend fun setCapGB(gb: Double?) = store.set(StorageSettings.SOFT_CAP_GB, gb?.takeIf { it > 0.0 } ?: 0.0)
    suspend fun setCapSongs(n: Int?) = store.set(StorageSettings.SOFT_CAP_SONGS, n?.takeIf { it > 0 } ?: 0)
}

/** Resolve settings into the cap in force; null => pruning OFF (fully manual storage). */
fun resolveActiveCap(gb: Double?, songs: Int?): ActiveCap? {
    val bytes = gb?.takeIf { it > 0.0 }?.let { (it * StorageSettings.BYTES_PER_GB).toLong() }
    val n = songs?.takeIf { it > 0 }
    return if (bytes != null || n != null) ActiveCap(bytes, n) else null
}
