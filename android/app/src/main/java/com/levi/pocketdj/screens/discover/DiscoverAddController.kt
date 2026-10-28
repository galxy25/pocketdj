package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.discover.DiscoverAddState
import com.levi.pocketdj.data.discover.DiscoverAddsStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine

/** What the rip server did with one `POST /rip` (iOS `RipsStore.RequestOutcome`, trimmed to what Discover reads). */
sealed interface DiscoverRipOutcome {
    /** Already ripped / finished. */
    data object Ready : DiscoverRipOutcome

    /** Accepted (queued or in flight); [jobId] is polled to ready in the background. */
    data class Queued(val jobId: String?) : DiscoverRipOutcome

    /** No import server configured - a serverless add is legitimate (streams via the catalog id). */
    data object NoServer : DiscoverRipOutcome

    /** Rejected / errored / unreachable - the track must NOT be recorded (no dead row). */
    data object Failed : DiscoverRipOutcome
}

/** The rip-server half of an add. */
interface DiscoverRipPort {
    suspend fun configured(): Boolean
    suspend fun request(songId: String, title: String, artist: String, appleMusicId: String, lengthMs: Int?): DiscoverRipOutcome

    /** `GET /album-tracks` (subscription-free). Empty on any failure. */
    suspend fun serverAlbumTracks(collectionId: String): List<DiscoverAlbumTrack>

    /** Keep watching a queued job so the manifest refreshes when it lands. */
    fun watch(songId: String, jobId: String)
    suspend fun refreshManifest()
}

/** The Apple Music library-write half of an add. Outcomes are TOKENS (see [LibraryWrite]). */
interface DiscoverLibraryPort {
    suspend fun addSong(appleMusicId: String): String
    suspend fun addAlbum(appleMusicId: String): String

    /** Album tracks via the catalog REST API (tier 1); empty when unavailable. */
    suspend fun albumTracks(appleMusicId: String): List<DiscoverAlbumTrack>
}

/** The library-write outcome tokens persisted on the entry / History event (iOS `storageToken`). */
object LibraryWrite {
    /** API accepted the write (the Web API's 2xx is its confirmation; there is no membership probe on Android). */
    const val CONFIRMED_WEB = "confirmed (web)"
    const val SKIPPED_NO_CONNECTION = "Apple Music write skipped: no Apple Music connection"
    fun failed(message: String) = "Apple Music write failed: $message"
}

/** What an album add owes BEYOND the library write (iOS `AlbumAddIntent`). */
enum class AlbumAddIntent { LIBRARY_ONLY, AND_PREPARE_COPIES }

data class DiscoverAddOutcome(
    /** The provisional rows were recorded (the add stands). */
    val accepted: Boolean,
    val libraryWrite: String,
    /** Human reason when [accepted] is false. */
    val error: String? = null,
)

/**
 * Discover "+ Add" flows (iOS `RipsStore.discoverAdd` / `discoverAddAlbum`):
 *
 * - SONG: library write (never aborts the add; its outcome is recorded truthfully) + `requestRip(amrec_<id>)`.
 *   Recorded as a provisional catalog row when the server ACCEPTED the request, already holds the media, or no
 *   server is configured (serverless add streams through the catalog id).
 * - ALBUM: library write, expand tracks (REST, else `/album-tracks`), fan out per-track rips for
 *   [AlbumAddIntent.AND_PREPARE_COPIES] collecting ONLY accepted tracks, then ONE batched record so the catalog is
 *   rebuilt once for the album. Zero accepted tracks records nothing.
 */
class DiscoverAddController(
    private val store: DiscoverAddsStore,
    private val rips: DiscoverRipPort,
    private val library: DiscoverLibraryPort,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    suspend fun addSong(hit: DiscoverHit): DiscoverAddOutcome {
        val songId = hit.id
        val write = library.addSong(hit.appleMusicId)
        val outcome = requestRip(songId, hit.title, hit.artist, hit.appleMusicId, hit.durationMs)
        if (outcome == DiscoverRipOutcome.Failed) {
            return DiscoverAddOutcome(false, write, DiscoverAddWording.ADD_FAILED)
        }
        store.add(
            DiscoverAddsStore.Entry(
                songId = songId, appleMusicId = hit.appleMusicId, title = hit.title, artist = hit.artist,
                album = hit.album, artworkUrl = hit.artworkUrl ?: hit.albumArtworkUrl, durationMs = hit.durationMs,
                addedAtMs = nowMs(),
                // The album IDENTITY makes the added song's album tappable; a song-scope add records NO provisional
                // album row (albumId stays null) - minting a one-track album would dangle.
                albumAppleMusicId = hit.albumAppleMusicId, albumArtworkUrl = hit.albumArtworkUrl,
                trackNumber = hit.trackNumber, discNumber = hit.discNumber, year = hit.year, explicit = hit.explicit,
                libraryWrite = write,
            ),
        )
        return DiscoverAddOutcome(true, write)
    }

    suspend fun addAlbum(hit: DiscoverAlbumHit, intent: AlbumAddIntent): DiscoverAddOutcome {
        val write = library.addAlbum(hit.appleMusicId)
        var tracks = library.albumTracks(hit.appleMusicId)
        if (tracks.isEmpty()) tracks = rips.serverAlbumTracks(hit.appleMusicId)
        if (tracks.isEmpty()) {
            return DiscoverAddOutcome(false, write, "Couldn’t read the album’s tracks — try again.")
        }
        val prepare = intent == AlbumAddIntent.AND_PREPARE_COPIES
        val serverUp = prepare && rips.configured()
        val addedAt = nowMs()
        val accepted = ArrayList<DiscoverAddsStore.Entry>()
        for (t in tracks) {
            val songId = "amrec_${t.id}"
            if (prepare) {
                val o = requestRip(songId, t.title, t.artist, t.id, t.durationMs)
                if (o == DiscoverRipOutcome.Failed) continue // a per-track miss records nothing - no dead row
            }
            accepted += DiscoverAddsStore.Entry(
                songId = songId, appleMusicId = t.id, title = t.title, artist = t.artist, album = hit.title,
                artworkUrl = hit.artworkUrl, durationMs = t.durationMs, addedAtMs = addedAt,
                // The album identity on EVERY track so its detail resolves a real IndexAlbum.
                albumId = hit.id, albumAppleMusicId = hit.appleMusicId, albumArtworkUrl = hit.artworkUrl,
                trackNumber = t.trackNumber, discNumber = t.discNumber, year = hit.year,
            )
        }
        if (accepted.isEmpty()) return DiscoverAddOutcome(false, write, DiscoverAddWording.ADD_FAILED)
        store.addAlbumBatch(
            DiscoverAddsStore.AlbumEntry(
                albumId = hit.id, appleMusicId = hit.appleMusicId, title = hit.title, artist = hit.artist,
                trackIds = accepted.map { it.songId }, artworkUrl = hit.artworkUrl, year = hit.year,
                trackCount = hit.trackCount ?: accepted.size, url = hit.url, addedAtMs = addedAt,
                // Whether there is any capture to WAIT ON: a library-only add (or a serverless one, where no rip
                // can ever land) settles to Added at once instead of spinning at 0/n.
                preparedCopies = serverUp,
                libraryWrite = write,
            ),
            accepted,
        )
        return DiscoverAddOutcome(true, write)
    }

    /** Request one rip and wire its follow-up (manifest refresh or background poll). Never throws. */
    private suspend fun requestRip(songId: String, title: String, artist: String, amId: String, lengthMs: Int?): DiscoverRipOutcome {
        val outcome = try {
            rips.request(songId, title, artist, amId, lengthMs)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            DiscoverRipOutcome.Failed
        }
        when (outcome) {
            DiscoverRipOutcome.Ready -> runCatching { rips.refreshManifest() }
            is DiscoverRipOutcome.Queued -> outcome.jobId?.let { rips.watch(songId, it) }
            else -> Unit
        }
        return outcome
    }

    /** Fired after a USER "Remove from Library" with the removed item - the app logs `catalogRemove`. */
    @Volatile var onUserCatalogRemove: ((DiscoverAddsStore.CatalogItem) -> Unit)? = null

    /**
     * "Remove from Library": drop a user-added provisional song from its backing store (the catalog rebuild follows
     * through the store's change hook) and log it. DISTINCT from the supersede removals (which yield an id to its
     * indexed twin). No-op (false) for sources that are not user-removable. [removeImported] drops an Imported row.
     */
    fun removeFromLibrary(
        songId: String,
        sourceName: String?,
        title: String,
        artist: String?,
        removeImported: (String) -> Unit = {},
    ): Boolean {
        val item = when (sourceName) {
            DiscoverAddsStore.SOURCE_NAME -> store.userRemove(songId)
            com.levi.pocketdj.data.catalog.ImportedSongsStore.SOURCE_NAME -> {
                removeImported(songId)
                DiscoverAddsStore.CatalogItem(songId, title, artist)
            }
            else -> null
        } ?: return false
        onUserCatalogRemove?.invoke(item)
        return true
    }

    /**
     * Per-album settle state for every recorded provisional album: ready = tracks in the rips manifest, errored =
     * tracks whose job is in a terminal error phase.
     */
    fun albumStates(readyIds: Flow<Set<String>>, erroredIds: Flow<Set<String>>): Flow<Map<String, DiscoverAddState>> =
        combine(store.state, readyIds, erroredIds) { snap, ready, errored ->
            snap.albums.associate { it.albumId to DiscoverAddState.of(it, ready, errored) }
        }

    companion object {
        /** Pure: the rip server's job view -> outcome. Error phase = rejected; anything else with a job = accepted. */
        fun outcomeOf(job: com.levi.pocketdj.data.rips.RipJob): DiscoverRipOutcome = when {
            job.isReady -> DiscoverRipOutcome.Ready
            job.phase == com.levi.pocketdj.data.rips.RipJob.PHASE_ERROR -> DiscoverRipOutcome.Failed
            else -> DiscoverRipOutcome.Queued(job.jobId)
        }
    }
}

/** True for a catalog source the user can "Remove from Library" from (Discover adds and Imported transfers). */
fun isRemovableFromLibrary(sourceName: String?): Boolean =
    sourceName == DiscoverAddsStore.SOURCE_NAME || sourceName == com.levi.pocketdj.data.catalog.ImportedSongsStore.SOURCE_NAME
