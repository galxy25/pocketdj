package com.levi.pocketdj.widget

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/** Everything the snapshot is derived from. [positionMs] is deliberately NOT published. */
data class WidgetInputs(
    val songId: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val albumId: String? = null,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0,
    val upNext: List<NowPlayingSnapshot.Track> = emptyList(),
    val isFavorite: Boolean = false,
    val favoriteAvailable: Boolean = false,
    val appleMusicId: String? = null,
    val repeatMode: String = "off",
    val shuffleEnabled: Boolean = false,
)

/** Fetches the cover PNG bytes for a cover key (null when none / failed). */
fun interface CoverFetcher {
    suspend fun fetch(key: CoverKey): ByteArray?
}

data class CoverKey(val songId: String, val albumId: String?) {
    /** Covers are per album when known, else per song. */
    val identity: String get() = albumId ?: songId
}

/**
 * Writes the snapshot whenever its published content changes and keeps the cover file current.
 * Cover refresh uses token discipline: a fetch superseded by a later song change is dropped, so a
 * slow image never lands on the wrong track.
 */
class WidgetSync(
    private val scope: CoroutineScope,
    private val inputs: Flow<WidgetInputs>,
    private val store: NowPlayingSnapshotStore,
    private val covers: CoverFetcher,
    private val refresh: suspend () -> Unit,
) {
    private val lock = Any()
    private var current: NowPlayingSnapshot = NowPlayingSnapshot.EMPTY
    private var coverVersion = 0
    private var coverIdentity: String? = null
    private var coverToken = 0L

    fun start(): Job = scope.launch { inputs.collect { onInputs(it) } }

    internal suspend fun onInputs(i: WidgetInputs) {
        val changed = synchronized(lock) {
            val hasContent = i.songId != null
            val identity = if (hasContent) CoverKey(i.songId!!, i.albumId).identity else null
            var fetch: Pair<Long, CoverKey>? = null
            if (identity != coverIdentity) {
                coverIdentity = identity
                coverToken++
                if (identity == null) {
                    store.clearCover()
                    coverVersion++
                } else {
                    fetch = coverToken to CoverKey(i.songId!!, i.albumId)
                }
            }
            current = build(i)
            val wrote = store.write(current)
            wrote to fetch
        }
        if (changed.first) runCatching { refresh() }
        changed.second?.let { (token, key) -> fetchCover(token, key) }
    }

    private suspend fun fetchCover(token: Long, key: CoverKey) {
        val bytes = runCatching { covers.fetch(key) }.getOrNull()
        val wrote = synchronized(lock) {
            if (token != coverToken) return // superseded by a newer song
            if (bytes != null && bytes.isNotEmpty()) store.writeCover(bytes) else store.clearCover()
            coverVersion++
            current = current.copy(coverVersion = coverVersion)
            store.write(current)
        }
        if (wrote) runCatching { refresh() }
    }

    private fun build(i: WidgetInputs): NowPlayingSnapshot {
        val has = i.songId != null
        return NowPlayingSnapshot(
            isPlaying = has && i.isPlaying,
            hasContent = has,
            title = if (has) i.title.orEmpty() else "",
            artist = if (has) i.artist.orEmpty() else "",
            songId = i.songId,
            coverVersion = coverVersion,
            upNext = if (has) i.upNext.take(UP_NEXT_MAX) else emptyList(),
            isFavorite = has && i.favoriteAvailable && i.isFavorite,
            appleMusicId = if (has) i.appleMusicId else null,
            repeatMode = if (has) i.repeatMode else "off",
            shuffleEnabled = has && i.shuffleEnabled,
            favoriteAvailable = i.favoriteAvailable,
        )
    }

    companion object {
        const val UP_NEXT_MAX = 4
    }
}
