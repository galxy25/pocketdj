package com.levi.pocketdj.data.rips

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
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
    private val inFlight = ConcurrentHashMap<String, Deferred<String?>>()

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
        // The mint runs in the CACHE's scope, so one caller's cancellation (a screen scope torn
        // down mid-play) never hands the other waiters a null (=> unsigned 403 URL).
        val minted = inFlight.computeIfAbsent(songId) {
            scope.async(start = CoroutineStart.LAZY) { mint(songId) }
        }
        minted.invokeOnCompletion { inFlight.remove(songId, minted) }
        minted.start()
        return minted.await()
    }

    private suspend fun mint(songId: String): String? {
        val url = try {
            presigner(songId, ttlSeconds)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            null
        }
        if (url != null) entries[songId] = Entry(url, clock())
        onTrace("presign $songId ${if (url != null) "ok" else "FAILED"}")
        return url
    }

    /** Drop a cached URL (e.g. it 403'd) so the next [urlFor] mints a fresh one. */
    fun invalidate(songId: String) {
        entries.remove(songId)
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
