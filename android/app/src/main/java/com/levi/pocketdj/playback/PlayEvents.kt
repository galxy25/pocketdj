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
    /** Game-run tag stamped on rows appended with `appendRows(runTag)`; null for ordinary plays. */
    val runTag: String? = null,
) {
    companion object {
        const val SOURCE_BROWSER = "browser"
        const val SOURCE_PLAYLIST = "playlist"
        const val SOURCE_POCKET = "pocket"
        const val SOURCE_ALBUM = "album"
        const val SOURCE_SETLIST = "setlist"
        const val SOURCE_MIX = "mix"
        const val SOURCE_ARTIST = "artist"
        const val SOURCE_GAME = "game"

        /** A standalone Browser single: no contextId, no contextName. */
        val BROWSER = PlayContext(SOURCE_BROWSER)

        fun album(albumId: String, albumName: String?) =
            PlayContext(SOURCE_ALBUM, contextId = albumId, contextName = albumName)

        // P2 companions (specs/realize-play.md §7): for queue runs the
        // contextId is the RUN's setlist id (`set_now_playing` for ▶/🔀 runs,
        // the frozen setlist's own id otherwise) and the contextName is the
        // originating collection's name — the values History persists.

        fun playlist(setlistId: String, name: String?) =
            PlayContext(SOURCE_PLAYLIST, contextId = setlistId, contextName = name)

        fun pocket(setlistId: String, name: String?) =
            PlayContext(SOURCE_POCKET, contextId = setlistId, contextName = name)

        fun setlist(setlistId: String, name: String?) =
            PlayContext(SOURCE_SETLIST, contextId = setlistId, contextName = name)

        /** A game-driven play: rows read "Game · <label>" (iOS shape); [runTag] tags the run's rows. */
        fun game(runTag: String?, label: String?) =
            PlayContext(SOURCE_GAME, contextId = runTag, contextName = label, runTag = runTag)

        fun artist(artistKey: String, name: String?) =
            PlayContext(SOURCE_ARTIST, contextId = artistKey, contextName = name)
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
    /**
     * The navigable origin collection (playlist/pocket id) of a `set_now_playing` run; set by the
     * sequencer so History rows can attribute the play to the collection it came from.
     */
    val originCollectionId: String? = null,
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

    private val _progress = MutableSharedFlow<PlayProgress>(extraBufferCapacity = 16)
    val progress: SharedFlow<PlayProgress> = _progress.asSharedFlow()
    fun emit(event: PlayProgress) { _progress.tryEmit(event) }

    private val _advancedAway = MutableSharedFlow<PlayAdvancedAway>(extraBufferCapacity = 16)
    val advancedAway: SharedFlow<PlayAdvancedAway> = _advancedAway.asSharedFlow()
    fun emit(event: PlayAdvancedAway) { _advancedAway.tryEmit(event) }

    private val _stopped = MutableSharedFlow<PlayStopped>(extraBufferCapacity = 16)
    val stopped: SharedFlow<PlayStopped> = _stopped.asSharedFlow()
    fun emit(event: PlayStopped) { _stopped.tryEmit(event) }
}

/** ~1 Hz position sample of the sounding row (fed by the sequencer ticker). */
data class PlayProgress(val songId: String, val positionMs: Long, val durationMs: Long?)

/**
 * The listener advanced away from [songId] (skip, jump, play-now, fresh play over a run). Never
 * emitted for natural end, repeat, dead-source advance, previous or stop. [positionMs] null = unknown.
 */
data class PlayAdvancedAway(val songId: String, val positionMs: Long?, val durationMs: Long?)

/** The run was torn down (stop / natural end of the set). */
data class PlayStopped(val songId: String?)
