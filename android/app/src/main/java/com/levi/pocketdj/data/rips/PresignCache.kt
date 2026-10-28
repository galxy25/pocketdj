package com.levi.pocketdj.data.rips

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Presigned-URL cache + prefetch (iOS `RipsStore.prefetchPresigned`). The rips bucket is
 * private, so every cached song costs a bearer-gated `/rips/presign` round trip; resolving the
 * NEXT songs' URLs while the current one plays removes that round trip (and its failure mode)
 * from the silent gap at the song boundary.
 *
 * URLs are minted with a 6 h TTL and trusted for 5 h. Concurrent requests for the same id
 * share one network call. Serverless (not configured) => null everywhere, never an error.
 */
class PresignCache(
    private val scope: CoroutineScope,
    private val isConfigured: suspend () -> Boolean,
    /** Mints one presigned URL; throws on failure. */
    private val presigner: suspend (songId: String, ttlSeconds: Int) -> String,
    private val clock: () -> Long = System::currentTimeMillis,
    private val usableMs: Long = RipSettings.PREFETCH_USABLE_MS,
    private val ttlSeconds: Int = RipSettings.PREFETCH_TTL_SECONDS,
    private val onTrace: (String) -> Unit = {},
) {
    private data class Entry(val url: String, val at: Long)

    private val entries = ConcurrentHashMap<String, Entry>()
    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<String?>>()

    /** A still-fresh cached URL for [songId], else null (a stale entry is dropped). */
    fun cached(songId: String): String? {
        val e = entries[songId] ?: return null
        if (clock() - e.at >= usableMs) {
            entries.remove(songId, e)
            return null
        }
        return e.url
    }

    /**
     * The presigned URL for [songId]: cached, else one (deduplicated) network call. Null when
     * serverless or when minting fails (the caller falls back to the direct URL).
     */
    suspend fun urlFor(songId: String): String? {
        cached(songId)?.let { return it }
        if (!isConfigured()) return null
        val mine = CompletableDeferred<String?>()
        val existing = inFlight.putIfAbsent(songId, mine)
        if (existing != null) return existing.await()
        try {
            val url = try {
                presigner(songId, ttlSeconds)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                null
            }
            if (url != null) entries[songId] = Entry(url, clock())
            onTrace("presign $songId ${if (url != null) "ok" else "FAILED"}")
            mine.complete(url)
            return url
        } catch (error: CancellationException) {
            mine.complete(null)
            throw error
        } finally {
            inFlight.remove(songId, mine)
        }
    }

    /**
     * Fire-and-forget: presign the given ids so upcoming songs start with no round trip.
     * Callers pass only ripped rows; ids already cached or in flight are skipped.
     */
    fun prefetch(songIds: Collection<String>) {
        for (id in songIds.distinct()) {
            if (cached(id) != null || inFlight.containsKey(id)) continue
            scope.launch { urlFor(id) }
        }
    }

    fun clear() {
        entries.clear()
    }
}
