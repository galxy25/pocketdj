package com.levi.pocketdj.data.applemusic

/** Why a write-back delivery failed. Messages are user-facing (Settings > Apple Music). */
sealed class WriteBackException(message: String) : Exception(message) {
    class UnsupportedPlatform : WriteBackException("Apple Music playlists can’t be edited from this device.")
    class NotAuthorized : WriteBackException("PocketDJ isn’t connected to Apple Music.")
    class SongNotFound(id: String) :
        WriteBackException("Couldn’t find this song in the Apple Music catalog ($id).")
    class PlaylistNotFound(name: String) :
        WriteBackException("Couldn’t find an Apple Music playlist named “$name” in your library.")

    /** A previously-resolved playlist id no longer resolves; the queue re-resolves by name once. */
    class PlaylistGone(id: String) :
        WriteBackException("That Apple Music playlist is no longer in your library ($id).")
    class Http(val status: Int) : WriteBackException("Apple Music API error ($status)")
    class RateLimited : WriteBackException("Apple Music is rate-limiting requests; will retry shortly.")
    class Transport(detail: String) : WriteBackException(detail)
}

/**
 * The Apple Music seam of the write-back queue (iOS `PlaylistWriteBackTransport`): the only thing
 * in the path that touches the network, so every retry rule is unit-testable against a stub.
 */
interface PlaylistWriteBackTransport {
    /** PERMANENT capability. False settles jobs as NOT_APPLICABLE. */
    val isSupported: Boolean

    /** Can a write go out RIGHT NOW (Music-User-Token present)? False leaves jobs queued. */
    suspend fun canWrite(): Boolean

    /**
     * Resolve an indexed playlist to its STABLE library-playlist id. [expectedAppleMusicIds] is a
     * SAMPLE used only to break a tie between same-named playlists, never a membership test.
     */
    suspend fun resolvePlaylistId(name: String, expectedAppleMusicIds: List<String>): String?

    /** Add the catalog song to the library playlist; throws [WriteBackException.PlaylistGone] on 404. */
    suspend fun addSong(appleMusicId: String, toPlaylistId: String)

    /** Resolve a song with NO known catalog id; null = searched, no confident match (terminal). */
    suspend fun resolveCatalogId(song: WriteBackSong): String? = null

    /** Set by [resolvePlaylistId] when the answer was a GUESS (duplicate names, no overlap). */
    val lastResolutionNote: String? get() = null

    /**
     * Reconcile an EXISTING app-created library playlist to [orderedAppleMusicIds] (remove-missing +
     * reorder, the half an append-only push cannot do). Defaulted to UNSUPPORTED so stubs need not care.
     */
    suspend fun reconcile(playlistId: String, orderedAppleMusicIds: List<String>): PlaylistReconcileResult =
        PlaylistReconcileResult.Unsupported
}

/** The three-tier library-playlist name match: exact -> trimmed -> case/diacritic folded. */
object WriteBackPlaylistMatcher {
    fun candidates(name: String, playlists: List<AmLibraryPlaylist>): List<AmLibraryPlaylist> {
        val exact = playlists.filter { it.name == name }
        if (exact.isNotEmpty()) return exact

        val target = name.trim()
        val trimmed = playlists.filter { it.name.trim() == target }
        if (trimmed.isNotEmpty()) return trimmed

        val folded = WriteBackMatcher.fold(target)
        return playlists.filter { WriteBackMatcher.fold(it.name.trim()) == folded }
    }
}

/**
 * Android's write-back transport: the Apple Music WEB API (decision D12, SVC-15) with the dev
 * token + Music-User-Token. Port of iOS `WebAPIPlaylistWriteBackTransport`.
 *
 * Create + append only: no remove/reorder route exists. Every non-idempotent append is preceded
 * by a membership pre-check of the playlist's tracks (a duplicate in the user's real playlist
 * cannot be removed from here).
 */
class WebApiPlaylistWriteBackTransport(
    private val api: AppleMusicApi,
    private val tokens: AppleMusicTokens,
) : PlaylistWriteBackTransport {

    private var storefront: String? = null

    override val isSupported: Boolean get() = true

    override suspend fun canWrite(): Boolean =
        try { tokens.musicUserToken() != null } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Throwable) { false }

    @Volatile
    override var lastResolutionNote: String? = null
        private set

    override suspend fun resolvePlaylistId(name: String, expectedAppleMusicIds: List<String>): String? {
        if (!canWrite()) throw WriteBackException.NotAuthorized()
        lastResolutionNote = null

        val all = unwrap(api.allLibraryPlaylists())
        val candidates = WriteBackPlaylistMatcher.candidates(name, all).filter { it.canEdit }
        if (candidates.isEmpty()) return null
        if (candidates.size == 1) return candidates[0].id

        // Several playlists share the name: break the tie on track overlap with the index's sample.
        val wanted = expectedAppleMusicIds.toSet()
        if (wanted.isNotEmpty()) {
            var bestId: String? = null
            var bestHits = 0
            for (c in candidates) {
                val hits = (api.allPlaylistTrackCatalogIds(c.id) as? AmResult.Ok)?.value?.count { it in wanted } ?: 0
                if (hits > bestHits) { bestId = c.id; bestHits = hits }
            }
            if (bestId != null) return bestId
        }
        lastResolutionNote = "Several Apple Music playlists are called “$name” — picked one."
        return candidates[0].id
    }

    override suspend fun addSong(appleMusicId: String, toPlaylistId: String) {
        if (!canWrite()) throw WriteBackException.NotAuthorized()

        // IDEMPOTENT DELIVERY: the POST is not idempotent, so a re-delivery would append a SECOND
        // copy. A 404 on the tracks GET means an EMPTY playlist (handled inside the api client).
        val present = unwrap(api.allPlaylistTrackCatalogIds(toPlaylistId))
        if (appleMusicId in present) return

        when (val r = api.addTracksToPlaylist(toPlaylistId, listOf(appleMusicId))) {
            is AmResult.Ok -> return
            // Only the POST route's 404 means the playlist is gone.
            is AmResult.Failure -> throw if (r.status == 404) WriteBackException.PlaylistGone(toPlaylistId) else failure(r)
            else -> unwrap(r)
        }
    }

    override suspend fun resolveCatalogId(song: WriteBackSong): String? {
        if (!canWrite()) throw WriteBackException.NotAuthorized()
        if (song.title.isEmpty() || song.artist.isEmpty()) return null
        val sf = currentStorefront()
        val res = unwrap(
            api.searchCatalog("${song.title} ${song.artist}", setOf(AmSearchType.SONGS), limit = 10, storefront = sf),
        )
        val candidates = res.songs.items.map {
            WriteBackCatalogCandidate(it.id, it.title, it.artist, it.album, it.durationSec)
        }
        // The SAME pure judge everywhere, so two devices resolve an identity-only song identically.
        return WriteBackMatcher.bestMatch(song, candidates)
    }

    /**
     * Web-API reconcile (fail-closed). The live rows are read FIRST and load-bearing (a read failure
     * throws; the sync absorbs it and retries next pass). The first DELETE decides editability: if
     * Apple refuses it nothing was touched => NotEditable. A later failure throws; the next push
     * re-appends whatever is missing, so a half-applied reorder converges instead of losing songs.
     */
    override suspend fun reconcile(playlistId: String, orderedAppleMusicIds: List<String>): PlaylistReconcileResult {
        if (!canWrite()) throw WriteBackException.NotAuthorized()
        if (orderedAppleMusicIds.isEmpty()) return PlaylistReconcileResult.SkippedEmpty
        val live = unwrap(api.allPlaylistTrackRows(playlistId))
        when (val plan = PlaylistReconcilePlanner.plan(live, orderedAppleMusicIds)) {
            is PlaylistReconcilePlanner.Plan.AlreadyInSync -> return PlaylistReconcileResult.AlreadyInSync
            is PlaylistReconcilePlanner.Plan.Unsafe -> return PlaylistReconcileResult.NotEditable
            is PlaylistReconcilePlanner.Plan.Edit -> {
                var first = true
                for (batch in AppleMusicApi.batches(plan.deleteLibraryIds)) {
                    when (val r = api.removeTracksFromPlaylist(playlistId, batch)) {
                        is AmResult.Ok -> {}
                        is AmResult.Failure ->
                            if (first && PlaylistReconcilePlanner.isRefusal(r.status)) return PlaylistReconcileResult.NotEditable
                            else throw failure(r)
                        else -> unwrap(r)
                    }
                    first = false
                }
                for (batch in AppleMusicApi.batches(plan.appendCatalogIds)) unwrap(api.addTracksToPlaylist(playlistId, batch))
                return PlaylistReconcileResult.Edited(orderedAppleMusicIds.size, plan.added, plan.removed)
            }
        }
    }

    /** THROWS on failure: nil from [resolveCatalogId] is the TERMINAL "not on Apple Music" verdict. */
    private suspend fun currentStorefront(): String {
        storefront?.let { return it }
        val sf = unwrap(api.userStorefront())
        storefront = sf
        return sf
    }

    private fun <T> unwrap(r: AmResult<T>): T = when (r) {
        is AmResult.Ok -> r.value
        AmResult.NeedsUserToken -> throw WriteBackException.NotAuthorized()
        is AmResult.RateLimited -> throw WriteBackException.RateLimited()
        is AmResult.Failure -> throw failure(r)
    }

    private fun failure(r: AmResult.Failure): WriteBackException {
        val s = r.status
        return when {
            s == null -> WriteBackException.Transport(r.message)
            s == 401 || s == 403 -> WriteBackException.NotAuthorized()
            else -> WriteBackException.Http(s)
        }
    }
}
