package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.applemusic.AppleMusicTokens
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The Apple Music side of favorites (iOS `AppleMusicFavoritesTransport`), seamed for tests. */
interface FavoritesRemote {
    /** True when the account can be written to right now (signed in with a Music-User-Token). */
    suspend fun canSync(): Boolean
    suspend fun love(catalogId: String): AmResult<Unit>
    suspend fun unlove(catalogId: String): AmResult<Unit>

    /** The ★ half, chunked. */
    suspend fun star(catalogIds: List<String>): AmResult<Unit>

    /** Which of [catalogIds] the account loves; non-Ok on ANY unreadable batch (never a partial set). */
    suspend fun lovedIds(catalogIds: List<String>): AmResult<Set<String>>
}

class ApiFavoritesRemote(private val api: AppleMusicApi, private val tokens: AppleMusicTokens) : FavoritesRemote {
    override suspend fun canSync() = tokens.musicUserToken() != null
    override suspend fun love(catalogId: String) = api.rateSong(catalogId, 1)
    override suspend fun unlove(catalogId: String) = api.unrateSong(catalogId)
    override suspend fun star(catalogIds: List<String>) = api.starSongs(catalogIds)
    override suspend fun lovedIds(catalogIds: List<String>) = api.lovedSongIds(catalogIds)
}

/** The shipped seed document at `Endpoints.FAVORITES_SEED_URL` (iOS `FavoritesSyncService.Seed`). */
@Serializable
data class FavoritesSeed(
    val version: Int,
    val songIds: List<String> = emptyList(),
    val appleMusicIds: Map<String, String>? = null,
)

/**
 * Bridge between [FavoritesStore] (local ♥) and Apple Music — port of iOS `FavoritesSyncService`
 * minus the owner gate (N/A on Android): sync runs only when the per-install opt-in is ON.
 *
 *  - Opt-in OFF ⇒ ZERO Apple Music requests. The only thing it may do is the seed download,
 *    itself behind its own opt-in.
 *  - Push: favorite writes BOTH the ★ (best-effort) and the love rating; unfavorite DELETEs the
 *    rating only (the ★ cannot be retracted). A failed rating write ends the pass and the entry
 *    stays pending; `markPushed` is stamped with the SENT entry's `atMs`, so a re-toggle in
 *    flight stays pending.
 *  - Pull: loved ids fold through `applyRemote` (newer local edit wins). An unreadable batch
 *    aborts the reconcile — a partial read is indistinguishable from "no longer loved".
 *  - Single-flight: one pass at a time.
 */
class FavoritesSyncService(
    private val favorites: FavoritesStore,
    private val remote: FavoritesRemote,
    private val twoWayEnabled: suspend () -> Boolean,
    private val seedOptIn: suspend () -> Boolean,
    /** Every (songId, appleMusicId) in the catalog — the id space the pull asks about. */
    private val catalogPairs: () -> List<Pair<String, String>>,
    private val fetchSeed: suspend () -> String,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
    private val json: Json = Json { ignoreUnknownKeys = true; isLenient = true },
) {
    data class State(
        val isSyncing: Boolean = false,
        val lastError: String? = null,
        val lastSyncedAtMs: Double? = null,
    )

    private val running = AtomicBoolean(false)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    /** Launch / foreground / Settings button. Never throws (except cancellation). */
    suspend fun run() {
        if (!running.compareAndSet(false, true)) return
        _state.value = _state.value.copy(isSyncing = true)
        try {
            if (twoWayEnabled()) {
                push(null)
                pull()
                _state.value = _state.value.copy(lastSyncedAtMs = clock())
            } else {
                applySeedIfNeeded()
            }
            _state.value = _state.value.copy(lastError = null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.value = _state.value.copy(lastError = e.message ?: e.toString())
        } finally {
            running.set(false)
            _state.value = _state.value.copy(isSyncing = false)
        }
    }

    /** The ♥-tap path: push one change now. No-op when opted out or the song has no AM id. */
    suspend fun pushNow(entry: FavoriteEntry) {
        if (entry.appleMusicId == null || !twoWayEnabled()) return
        try {
            push(entry)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.value = _state.value.copy(lastError = e.message ?: e.toString())
        }
    }

    private suspend fun push(single: FavoriteEntry?) {
        if (!remote.canSync()) return
        val pending = single?.let { listOf(it) } ?: favorites.pendingPushes
        if (pending.isEmpty()) return

        val starIds = pending.filter { it.favorited }.mapNotNull { it.appleMusicId }
        // Best-effort: the ★ is cosmetic next to the rating and must never block it.
        if (starIds.isNotEmpty()) runCatching { remote.star(starIds) }

        for (entry in pending) {
            val amId = entry.appleMusicId ?: continue
            val r = if (entry.favorited) remote.love(amId) else remote.unlove(amId)
            if (r !is AmResult.Ok) throw SyncFailure("Apple Music rejected the rating write: ${describe(r)}")
            favorites.markPushed(entry.songId, entry.atMs)
        }
    }

    private suspend fun pull() {
        if (!remote.canSync()) return
        val pairs = catalogPairs()
        if (pairs.isEmpty()) return
        val now = clock()
        val loved = when (val r = remote.lovedIds(pairs.map { it.second })) {
            is AmResult.Ok -> r.value
            else -> throw SyncFailure("Could not read Apple Music loved songs: ${describe(r)}")
        }
        favorites.withCoalescedSaves {
            for ((songId, amId) in pairs) {
                val isLoved = amId in loved
                // Absence of a rating is not a decision to unfavorite: only touch songs that are
                // loved upstream or already have a local entry.
                if (isLoved || favorites.entry(songId) != null) {
                    favorites.applyRemote(songId, isLoved, amId, now)
                }
            }
        }
    }

    private suspend fun applySeedIfNeeded() {
        if (!seedOptIn()) return
        val seed = runCatching { json.decodeFromString(FavoritesSeed.serializer(), fetchSeed()) }.getOrNull() ?: return
        if (seed.version <= favorites.seedVersion) return
        favorites.applySeed(seed.songIds, seed.appleMusicIds ?: emptyMap(), seed.version)
    }

    /** Export the shareable seed: Apple-Music-sourced favorites only (vinyl/digital/studio excluded). */
    fun exportSeed(version: Int): FavoritesSeed {
        val shareable = favorites.entries().filter { it.favorited && it.appleMusicId != null }
        return FavoritesSeed(
            version,
            shareable.map { it.songId }.sorted(),
            shareable.associate { it.songId to it.appleMusicId!! },
        )
    }

    private class SyncFailure(message: String) : Exception(message)

    private fun describe(r: AmResult<*>): String = when (r) {
        is AmResult.Ok -> "ok"
        AmResult.NeedsUserToken -> "sign in to Apple Music"
        is AmResult.RateLimited -> "rate limited"
        is AmResult.Failure -> r.message
    }
}
