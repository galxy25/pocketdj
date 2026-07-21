package com.levi.pocketdj.playback

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Where a play came from (specs/history.md §2, §4). The [source] tokens are the
 * PERSISTED history values — never rename:
 * `browser | playlist | pocket | album | setlist | mix | artist`.
 * Android P1 emits only `browser` and `album`; the full plumbing ships now so
 * P2/P3 add callers, not store shapes.
 *
 * The context is captured ONCE at queue-start (the iOS captured-origin
 * doctrine) so a later rename can't retag earlier rows.
 */
data class PlayContext(
    val source: String,
    val contextId: String? = null,
    val contextName: String? = null,
) {
    companion object {
        const val SOURCE_BROWSER = "browser"
        const val SOURCE_PLAYLIST = "playlist"
        const val SOURCE_POCKET = "pocket"
        const val SOURCE_ALBUM = "album"
        const val SOURCE_SETLIST = "setlist"
        const val SOURCE_MIX = "mix"
        const val SOURCE_ARTIST = "artist"

        /** A standalone Browser single: no contextId, no contextName. */
        val BROWSER = PlayContext(SOURCE_BROWSER)

        fun album(albumId: String, albumName: String?) =
            PlayContext(SOURCE_ALBUM, contextId = albumId, contextName = albumName)
    }
}

/**
 * Fired the moment a NEW song id starts playing (track start — not a
 * listened-duration threshold). Emitted from the playback service's
 * `onMediaItemTransition` behind an id-changed gate, reproducing the iOS
 * "nowPlaying.songId changed" semantics; History's 30 s same-song window
 * absorbs anything that slips through (specs/history.md §4).
 */
data class PlayStarted(
    val songId: String,
    /** Title/artist snapshots for history rows that outlive the catalog. */
    val title: String?,
    val artist: String?,
    val context: PlayContext,
    /** Epoch ms. */
    val atMs: Long,
)

/**
 * The play-event seam History consumes: collect [events] and call
 * `PlayHistoryStore.record(...)` per emission. Process-wide singleton so the
 * service (emitter) and the history store (collector) need no direct wiring.
 */
object PlayEventBus {
    private val _events = MutableSharedFlow<PlayStarted>(extraBufferCapacity = 64)
    val events: SharedFlow<PlayStarted> = _events.asSharedFlow()

    fun emit(event: PlayStarted) {
        _events.tryEmit(event)
    }
}
