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

    /**
     * The store id to actually add: the recognized id swapped for its preferred-edition (clean/explicit) sibling
     * when one verifiably exists (iOS `VariantResolver.preferredStoreID`). Best-effort and never throws; the
     * default keeps the recognized id (no preference chosen / unavailable).
     */
    suspend fun preferredEdition(storeId: String, title: String, artist: String): String = storeId
}

/** One catalog song row as the edition swap sees it (title/artist/duration/explicit flag). */
data class EditionRow(
    val storeId: String,
    val title: String,
    val artist: String,
    /** null = unclassified (no explicit/clean marker). */
    val explicit: Boolean?,
    val durationSec: Double? = null,
)

/**
 * Recognizer edition swap (iOS `VariantResolver.preferredStoreID` + `AppleMusicProvider.editionMatches`): before the
 * library add / rip+burn, replace the recognized store id with its preferred-edition twin. Deliberately NOT applied
 * to Discover adds (a tapped edition row there is the user's authoritative pick).
 */
object RecognizerEdition {
    const val DURATION_TOLERANCE_MS = 7_000

    /** Same recording, the wanted edition, durations agree - never a different cut. */
    fun matches(row: EditionRow, name: String, artist: String, lengthMs: Int?, wantExplicit: Boolean): Boolean {
        if (row.explicit != wantExplicit) return false
        val nt = ShazamCatalogMatch.norm(name)
        if (nt.isEmpty() || ShazamCatalogMatch.norm(row.title) != nt) return false
        val na = ShazamCatalogMatch.norm(artist)
        if (na.isNotEmpty()) {
            val ra = ShazamCatalogMatch.norm(row.artist)
            if (!(ra == na || ra.contains(na) || na.contains(ra))) return false
        }
        val d = row.durationSec
        if (lengthMs != null && lengthMs > 0 && d != null) {
            if (kotlin.math.abs(Math.round(d * 1000).toInt() - lengthMs) > DURATION_TOLERANCE_MS) return false
        }
        return true
    }

    /**
     * [preferExplicit] is the tri-state setting: null = never chosen, nothing is substituted. [search] returns catalog
     * rows for a "title artist" term; the recognized row is found among them by id. ANY miss keeps [storeId].
     */
    suspend fun preferredStoreId(
        storeId: String, title: String, artist: String, preferExplicit: Boolean?,
        search: suspend (term: String) -> List<EditionRow>,
    ): String {
        val prefer = preferExplicit ?: return storeId
        if (storeId.isBlank()) return storeId
        val rows = try {
            search("$title $artist".trim())
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            return storeId
        }
        val row = rows.firstOrNull { it.storeId == storeId } ?: return storeId
        // Already the preferred edition (or unclassified): keep the input.
        if (row.explicit != !prefer) return storeId
        val lengthMs = row.durationSec?.let { Math.round(it * 1000).toInt() }
        return rows.firstOrNull { matches(it, title, artist, lengthMs, prefer) }?.storeId ?: storeId
    }
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
    /** Fired once per CONFIRMED library add (History `catalogAdd`): (burnSongId, title, artist). */
    @Volatile var onCatalogAdd: ((id: String, title: String, artist: String) -> Unit)? = null

    private val _states = kotlinx.coroutines.flow.MutableStateFlow<Map<String, RecognitionAddState>>(emptyMap())
    val states: kotlinx.coroutines.flow.StateFlow<Map<String, RecognitionAddState>> = _states

    private fun patch(storeId: String, f: (RecognitionAddState) -> RecognitionAddState) =
        _states.update { it + (storeId to f(it[storeId] ?: RecognitionAddState())) }

    /**
     * [catalogSongId] is the indexed id when the track is already in the catalog. The preferred edition is resolved
     * FIRST (the add and the rip+burn use the swapped id); [catalogSongIdFor] re-resolves the indexed id for it.
     * Order: edition swap -> add to the Apple Music library -> THEN rip+burn.
     */
    fun add(
        storeId: String, title: String, artist: String, catalogSongId: String?,
        catalogSongIdFor: ((chosenStoreId: String) -> String?)? = null,
    ): kotlinx.coroutines.Job? {
        val cur = _states.value[storeId]
        if (cur != null && (cur.adding || cur.added)) return null // latch: never invite a duplicate add
        patch(storeId) { RecognitionAddState(adding = true) }
        return scope.launch {
            try {
                val chosen = try {
                    port.preferredEdition(storeId, title, artist).ifBlank { storeId }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                    storeId
                }
                if (!port.addSongToLibrary(chosen)) {
                    patch(storeId) { it.copy(addError = "Couldn’t add to Apple Music") }
                    return@launch
                }
                val indexed = if (chosen != storeId && catalogSongIdFor != null) catalogSongIdFor(chosen) else catalogSongId
                val id = AppleMusicRecognition.burnSongId(indexed, chosen)
                patch(storeId) { it.copy(added = true, burnSongId = id) }
                runCatching { onCatalogAdd?.invoke(id, title, artist) }
                try {
                    if (port.startRipAndBurn(id, title, artist, chosen) == RipStart.NO_SERVER) {
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
