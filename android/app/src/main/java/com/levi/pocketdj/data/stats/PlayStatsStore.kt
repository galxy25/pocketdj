package com.levi.pocketdj.data.stats

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

/** iOS `playStatsSchemaVersion`. */
const val PLAY_STATS_SCHEMA_VERSION = 1

/**
 * Per-song play aggregate (iOS `PlayStatsStore`): WHEN and HOW OFTEN each song was played on this
 * device — the ordering signal of the storage soft-cap LRP prune. File `pocketdj-play-stats.json`
 * in the iOS `Document` shape (so a synced/exported doc decodes on either platform).
 *
 * Invariants carried over verbatim:
 *  - plays of the same song within [RECOUNT_WINDOW_MS] refresh `lastPlayedAt` but do not re-count
 *    (a seek/restart or the double hook is not a second listen);
 *  - `appleCount` tags plays Apple also counted; `preTagPlayCount` is stamped ONCE by the migration
 *    and is 0 on every row created afterwards (a nil means "an older build wrote this");
 *  - new fields are additive-optional, no schema bump (a bump has discarded user data before);
 *  - [reloadFromDisk] replaces the map, bumps [revision], and keeps the OLDER migration mark.
 */
class PlayStatsStore(
    private val file: File,
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
    nowMs: Long = System.currentTimeMillis(),
) {
    @Serializable
    data class Stat(
        val playCount: Int = 0,
        /** Epoch ms of the most recent play (refreshed even inside the re-count window). */
        val lastPlayedAt: Double = 0.0,
        val appleCount: Int? = null,
        val preTagPlayCount: Int? = null,
        val skipCount: Int? = null,
    )

    @Serializable
    data class Document(
        val schemaVersion: Int = PLAY_STATS_SCHEMA_VERSION,
        val stats: Map<String, Stat> = emptyMap(),
        val appleTaggingMigratedAtMs: Double? = null,
    )

    private val json = PdjJson.lenient
    private val lock = Any()
    private val version = AtomicLong()

    @Volatile private var stats: Map<String, Stat> = emptyMap()
    @Volatile private var migratedAtMs: Double? = null
    private val _revision = MutableStateFlow(0)

    /** Bumped on EVERY mutation (play, reload, clear, migration) so revision-keyed memos invalidate. */
    val revision: StateFlow<Int> = _revision.asStateFlow()
    val appleTaggingMigratedAtMs: Double? get() = migratedAtMs

    /** PEER-PLAY SEAM: last play on ANOTHER device (derived at query time, never accumulated). */
    @Volatile var peerLastPlayedAt: ((String) -> Double?)? = null

    init {
        decode()?.let { doc ->
            stats = doc.stats
            migratedAtMs = doc.appleTaggingMigratedAtMs
        }
        synchronized(lock) { migrateUntaggedRows(nowMs.toDouble()) }
    }

    private fun decode(): Document? = runCatching {
        if (!file.isFile) null else json.decodeFromString(Document.serializer(), file.readText())
    }.getOrNull()

    /** Caller holds [lock]. Stamp every row that predates source tagging; flag lands even when empty. */
    private fun migrateUntaggedRows(now: Double) {
        var changed = false
        val next = HashMap(stats)
        for ((id, s) in stats) if (s.preTagPlayCount == null) {
            next[id] = s.copy(preTagPlayCount = s.playCount)
            changed = true
        }
        if (migratedAtMs == null) { migratedAtMs = now; changed = true }
        if (changed) {
            stats = next
            _revision.value += 1
            save()
        }
    }

    fun notePlayed(songId: String, atMs: Long = System.currentTimeMillis(), appleCounted: Boolean = false) {
        if (songId.isEmpty()) return
        val now = atMs.toDouble()
        synchronized(lock) {
            val cur = stats[songId]
            val updated = if (cur != null) {
                var s = cur
                if (now - s.lastPlayedAt >= RECOUNT_WINDOW_MS) {
                    s = s.copy(
                        playCount = s.playCount + 1,
                        appleCount = if (appleCounted) (s.appleCount ?: 0) + 1 else s.appleCount,
                    )
                }
                s.copy(lastPlayedAt = maxOf(s.lastPlayedAt, now))
            } else {
                // preTagPlayCount = 0 is load-bearing: it makes a nil elsewhere mean "legacy row".
                Stat(playCount = 1, lastPlayedAt = now, appleCount = if (appleCounted) 1 else null, preTagPlayCount = 0)
            }
            stats = stats + (songId to updated)
            _revision.value += 1
            save()
        }
    }

    /** A SKIP verdict (advanced away under 50% played). No re-count window: each verdict is distinct. */
    fun noteSkipped(songId: String, atMs: Long = System.currentTimeMillis()) {
        if (songId.isEmpty()) return
        synchronized(lock) {
            val cur = stats[songId]
            val updated = cur?.copy(skipCount = (cur.skipCount ?: 0) + 1)
                ?: Stat(playCount = 0, lastPlayedAt = atMs.toDouble(), preTagPlayCount = 0, skipCount = 1)
            stats = stats + (songId to updated)
            save()
        }
    }

    fun skipCountsSnapshot(): Map<String, Int> =
        stats.mapNotNull { (k, v) -> (v.skipCount ?: 0).takeIf { it > 0 }?.let { k to it } }.toMap()

    fun skipCount(songId: String): Int = stats[songId]?.skipCount ?: 0

    /** Epoch ms of the last play on ANY device, or null if never played (=> pruned first). */
    fun lastPlayedAt(songId: String): Double? {
        val local = stats[songId]?.lastPlayedAt
        val peer = peerLastPlayedAt?.invoke(songId) ?: return local
        return if (local == null) peer else maxOf(local, peer)
    }

    fun lastPlayedAtLocally(songId: String): Double? = stats[songId]?.lastPlayedAt

    fun playCount(songId: String): Int = stats[songId]?.playCount ?: 0

    fun stat(songId: String): Stat? = stats[songId]

    /** Plays Apple did NOT also count; see iOS doc — an under-count is the recoverable direction. */
    fun nonApplePlayCount(songId: String, appleKnowsSong: Boolean = false): Int =
        stats[songId]?.let { nonAppleCount(it, appleKnowsSong) } ?: 0

    fun nonApplePlayCountsSnapshot(appleKnownSongIds: Set<String> = emptySet()): Map<String, Int> {
        val out = HashMap<String, Int>(stats.size)
        for ((id, s) in stats) {
            val n = nonAppleCount(s, id in appleKnownSongIds)
            if (n > 0) out[id] = n
        }
        return out
    }

    fun playCountsSnapshot(): Map<String, Int> = stats.mapValues { it.value.playCount }
    fun lastPlayedSnapshot(): Map<String, Double> = stats.mapValues { it.value.lastPlayedAt }

    /** Re-decode the on-disk doc after a cloud pull (whole-document LWW). Keeps the OLDER migration mark. */
    fun reloadFromDisk(nowMs: Long = System.currentTimeMillis()) {
        val doc = decode() ?: return
        synchronized(lock) {
            stats = doc.stats
            _revision.value += 1
            migratedAtMs = listOfNotNull(migratedAtMs, doc.appleTaggingMigratedAtMs).minOrNull()
            migrateUntaggedRows(nowMs.toDouble())
        }
    }

    /** Wipe all play history (in-memory map + the persisted doc). */
    fun clear() {
        synchronized(lock) {
            stats = emptyMap()
            _revision.value += 1
            writer.deleteNow(version.incrementAndGet())
        }
    }

    fun flush() = synchronized(lock) { saveNow() }

    private fun render(): String =
        json.encodeToString(Document.serializer(), Document(stats = stats, appleTaggingMigratedAtMs = migratedAtMs))

    private fun save() {
        val snapshot = render()
        writer.write(version.incrementAndGet()) { snapshot }
    }

    private fun saveNow() {
        val snapshot = render()
        writer.flushNow(version.incrementAndGet()) { snapshot }
    }

    companion object {
        const val FILE_NAME = "pocketdj-play-stats.json"
        const val RECOUNT_WINDOW_MS = 30_000.0

        private fun nonAppleCount(s: Stat, appleKnowsSong: Boolean): Int {
            val untrusted = if (appleKnowsSong) (s.preTagPlayCount ?: 0) else 0
            return maxOf(0, s.playCount - (s.appleCount ?: 0) - untrusted)
        }
    }
}
