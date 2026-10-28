package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.applemusic.AppleMusicAlbumRef
import com.levi.pocketdj.data.applemusic.AppleMusicResolution
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the Apple Music block of the result sheet offers (iOS AppleMusicRecognitionAction). */
sealed interface AppleMusicRecognitionAction {
    data object Unavailable : AppleMusicRecognitionAction
    data object Connect : AppleMusicRecognitionAction
    data object Checking : AppleMusicRecognitionAction
    data object NotFound : AppleMusicRecognitionAction
    data class OpenIndexAlbum(val albumId: String) : AppleMusicRecognitionAction
    data class OpenRecognizedAlbum(val album: AppleMusicAlbumRef) : AppleMusicRecognitionAction
    data object InLibrary : AppleMusicRecognitionAction
    data class OpenInMusicApp(val url: String) : AppleMusicRecognitionAction
    data class AddToLibrary(val storeId: String, val title: String, val artist: String) : AppleMusicRecognitionAction
}

/** Pure helpers for the recognizer -> Apple Music library flow (iOS AppleMusicRecognition). */
object AppleMusicRecognition {

    fun action(
        available: Boolean,
        canContribute: Boolean,
        canAdd: Boolean,
        resolving: Boolean,
        resolution: AppleMusicResolution?,
        indexAlbumId: String?,
    ): AppleMusicRecognitionAction {
        if (!available) return AppleMusicRecognitionAction.Unavailable
        if (!canContribute) return AppleMusicRecognitionAction.Connect
        if (resolving) return AppleMusicRecognitionAction.Checking
        val r = resolution ?: return AppleMusicRecognitionAction.NotFound
        if (r.inLibrary) {
            if (indexAlbumId != null) return AppleMusicRecognitionAction.OpenIndexAlbum(indexAlbumId)
            r.album?.let { return AppleMusicRecognitionAction.OpenRecognizedAlbum(it) }
            return AppleMusicRecognitionAction.InLibrary
        }
        if (canAdd) return AppleMusicRecognitionAction.AddToLibrary(r.songStoreId, r.title, r.artist)
        r.songUrl?.let { return AppleMusicRecognitionAction.OpenInMusicApp(it) }
        return AppleMusicRecognitionAction.NotFound
    }

    /** Catalog album matching a resolved Apple Music album by normalized title + compatible artist. */
    fun indexAlbum(ref: AppleMusicAlbumRef, albums: Collection<IndexAlbum>): IndexAlbum? {
        val title = ShazamCatalogMatch.norm(ref.title)
        if (title.isEmpty()) return null
        val artist = ShazamCatalogMatch.norm(ref.artist)
        return albums.firstOrNull { album ->
            if (ShazamCatalogMatch.norm(album.name) != title) return@firstOrNull false
            artist.isEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(album.artist), artist)
        }
    }

    /** Catalog id when the track is indexed, else a colon-free `amrec_<storeId>`. */
    fun burnSongId(catalogSongId: String?, storeId: String): String =
        if (!catalogSongId.isNullOrEmpty()) catalogSongId else "amrec_$storeId"

    /** The namespaced catalog id of an Apple Music (Local) song. */
    fun namespacedSongId(storeId: String): String = "am:$storeId"

    /** Already-indexed song for a recognized track: `am:<id>`, stamped appleMusicId, else title+artist. */
    fun indexSong(storeId: String, title: String?, artist: String?, songs: Collection<IndexSong>): IndexSong? {
        val namespaced = namespacedSongId(storeId)
        songs.firstOrNull { it.id == namespaced || it.appleMusicId == storeId }?.let { return it }
        val nt = title?.let(ShazamCatalogMatch::norm)
        if (nt.isNullOrEmpty()) return null
        val na = artist?.let(ShazamCatalogMatch::norm)
        return songs.firstOrNull { song ->
            if (ShazamCatalogMatch.norm(song.name) != nt) return@firstOrNull false
            na.isNullOrEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(song.artist), na)
        }
    }
}

/** Seam the Compose section drives; the production adapter lives in [com.levi.pocketdj.di.BrowseGraph]. */
interface AppleMusicRecognitionPort {
    /** Apple Music is usable in this build (the Web API is always compiled in on Android). */
    val available: Boolean
    /** The account is linked (Music-User-Token present). */
    suspend fun canContribute(): Boolean
    /** Web-API library writes work on Android. */
    val canAdd: Boolean
    suspend fun resolve(storeId: String?, title: String?, artist: String?): AppleMusicResolution?
    /** Saves the song to the user's own Apple Music library; false = rejected. */
    suspend fun addSongToLibrary(storeId: String): Boolean
    /**
     * Registers a burn-when-ripped intent for [songId], asks the rip server to prepare it and (once
     * ready) burns it to this device (iOS BurnStore.startRipAndBurn). Throws when the request fails.
     */
    suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String): RipStart
}

enum class RipStart { REQUESTED, NO_SERVER }

/** Per-recognized-song add/burn progress (survives the result sheet being dismissed). */
data class RecognitionAddState(
    val adding: Boolean = false,
    val added: Boolean = false,
    val burnSongId: String? = null,
    val addError: String? = null,
    val burnError: String? = null,
)

/**
 * App-scoped add -> rip -> burn orchestration (iOS keeps this store-owned so dismissing the sheet
 * never cancels it). [scope] must outlive the UI.
 */
class RecognitionAddController(
    private val scope: kotlinx.coroutines.CoroutineScope,
    private val port: AppleMusicRecognitionPort,
) {
    private val _states = kotlinx.coroutines.flow.MutableStateFlow<Map<String, RecognitionAddState>>(emptyMap())
    val states: kotlinx.coroutines.flow.StateFlow<Map<String, RecognitionAddState>> = _states

    private fun patch(storeId: String, f: (RecognitionAddState) -> RecognitionAddState) =
        _states.update { it + (storeId to f(it[storeId] ?: RecognitionAddState())) }

    /** [catalogSongId] is the indexed id when the track is already in the catalog. */
    fun add(storeId: String, title: String, artist: String, catalogSongId: String?): kotlinx.coroutines.Job? {
        val cur = _states.value[storeId]
        if (cur != null && (cur.adding || cur.added)) return null // latch: never invite a duplicate add
        patch(storeId) { RecognitionAddState(adding = true) }
        return scope.launch {
            try {
                if (!port.addSongToLibrary(storeId)) {
                    patch(storeId) { it.copy(addError = "Couldn’t add to Apple Music") }
                    return@launch
                }
                val id = AppleMusicRecognition.burnSongId(catalogSongId, storeId)
                patch(storeId) { it.copy(added = true, burnSongId = id) }
                try {
                    if (port.startRipAndBurn(id, title, artist, storeId) == RipStart.NO_SERVER) {
                        patch(storeId) { it.copy(burnError = "No rip server — can’t download a copy to this device") }
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    patch(storeId) { it.copy(burnError = e.message ?: "Couldn’t request a copy for this device") }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                patch(storeId) { it.copy(addError = e.message ?: "Couldn’t add to Apple Music") }
            } finally {
                patch(storeId) { it.copy(adding = false) }
            }
        }
    }
}

/** Title + compatible artist match of Web-API library rows (the iOS isInLibrary probe). */
fun libraryRowsContain(rows: List<Pair<String, String>>, title: String, artist: String): Boolean {
    val nt = ShazamCatalogMatch.norm(title)
    val na = ShazamCatalogMatch.norm(artist)
    return rows.any { (n, a) ->
        ShazamCatalogMatch.norm(n) == nt && (na.isEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(a), na))
    }
}
