package com.levi.pocketdj.playback

import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.PresignCache

/**
 * Manifest-hit URL policy (iOS: presign the START item on demand, prefetch a few ahead without
 * blocking). The rips bucket is private, so with a server configured a hit plays the presigned
 * URL; without one it plays the direct URL. A failed presign falls back to the direct URL.
 */
class PlaybackUrlResolver(private val presigns: PresignCache?) {

    suspend fun resolve(songId: String, action: PlayAction.Stream, serverConfigured: Boolean): PlayAction.Stream {
        if (PlayResolver.isLocalUrl(action.url)) return action // burned file: never presigned
        val cache = presigns ?: return action
        if (!serverConfigured) return action
        val url = cache.urlFor(songId) ?: return action
        return action.copy(url = url)
    }

    /** Fire-and-forget presign of upcoming songs (never blocks the start of playback). */
    fun prefetch(songIds: Collection<String>, serverConfigured: Boolean) {
        if (serverConfigured) presigns?.prefetch(songIds)
    }

    /**
     * AM near-end warm (iOS `onNearEnd`): presign the NEXT row's manifest URL into the same cache the start path
     * reads, so the hand-off finds a fresh URL. Only a network manifest hit has anything to warm (burned files are
     * local, rip-on-demand has no URL yet, AM rows are resolved by the SDK). Returns true when a prefetch was issued.
     */
    fun prefetchNextRow(resolveId: String, source: com.levi.pocketdj.playback.sequencer.RowSource?, serverConfigured: Boolean): Boolean {
        val stream = (source as? com.levi.pocketdj.playback.sequencer.StreamSource)?.action ?: return false
        if (PlayResolver.isLocalUrl(stream.url) || !serverConfigured) return false
        prefetch(listOf(resolveId), true)
        return true
    }

    companion object {
        /** True when a queue item is a burned local file (must never be swapped to a network URL). */
        fun isLocalItemUrl(extraUrl: String?, uri: String?): Boolean =
            (extraUrl != null && PlayResolver.isLocalUrl(extraUrl)) || (uri != null && PlayResolver.isLocalUrl(uri))

        /** How many queue items ahead of the current one are kept freshly presigned. */
        const val AHEAD = 3

        /** Queue indices to refresh after [currentIndex] (exclusive), bounded by [count]. */
        fun aheadIndices(currentIndex: Int, count: Int): IntRange =
            (currentIndex + 1)..minOf(currentIndex + AHEAD, count - 1)
    }
}
