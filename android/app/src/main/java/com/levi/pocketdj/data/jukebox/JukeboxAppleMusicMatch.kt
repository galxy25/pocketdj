package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.applemusic.AmSearchType
import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.shazam.AppleMusicRecognition
import kotlinx.coroutines.CancellationException

/**
 * Stage 4 of the iOS four-stage matcher (SURF-10): the Apple Music catalog search for songs the
 * library does not have at all. Developer-token catalog search only (no sign-in needed). A hit may
 * map BACK to an indexed song (store id / appleMusicId / normalized title+artist); otherwise it is an
 * AM-only match carried as an ad-hoc [IndexSong] under the colon-free `amrec_<storeId>` id - the same
 * id the recognizer's add flow rips and burns with. The sequencer plays it through the Apple Music
 * SDK when that can run here, else through the rip-on-demand capture kicked on accept (Q113).
 */
class JukeboxAppleMusicMatch(
    private val api: AppleMusicApi,
    /** Library songs for the map-back lookup (the loaded catalog; may be empty). */
    private val songs: () -> Collection<IndexSong>,
    /** The account storefront; defaults to "us" when it cannot be read. */
    private val storefront: suspend () -> String = { "us" },
) : JukeboxExternalMatch {

    override suspend fun match(title: String, artist: String): IndexSong? {
        val term = searchTerm(title, artist) ?: return null
        val result = try {
            api.searchCatalog(term, setOf(AmSearchType.SONGS), limit = 5, storefront = storefront())
        } catch (c: CancellationException) {
            throw c
        } catch (e: Exception) {
            return null
        }
        val top = (result as? AmResult.Ok)?.value?.songs?.items?.firstOrNull() ?: return null
        AppleMusicRecognition.indexSong(top.id, top.title, top.artist, songs())?.let { return it }
        return adHocSong(top.id, top.title, top.artist.ifBlank { artist }, top.durationSec, top.explicit)
    }

    companion object {
        const val AD_HOC_PREFIX = "amrec_"

        /** iOS: title alone when the guest gave no artist, else "title artist". Null for a blank title. */
        fun searchTerm(title: String, artist: String): String? {
            val t = title.trim()
            if (t.isEmpty()) return null
            val a = artist.trim()
            return if (a.isEmpty()) t else "$t $a"
        }

        fun adHocSong(storeId: String, title: String, artist: String, durationSec: Double?, explicit: Boolean): IndexSong =
            IndexSong(
                id = AppleMusicRecognition.burnSongId(null, storeId),
                artist = artist,
                name = title,
                explicit = explicit,
                length = durationSec?.let { (it * 1000).toLong() },
                appleMusicId = storeId,
            )

        /**
         * An Apple-Music-only row (not in the library). Q113: queued at once like iOS's `am:<storeId>` row;
         * the sequencer's ladder streams it through the Apple Music SDK or captures it via rip-on-demand.
         */
        fun isAdHoc(songId: String): Boolean = songId.startsWith(AD_HOC_PREFIX)

        /** The Apple Music store id behind an ad-hoc SONG id (`amrec_<storeId>`); null for anything else. */
        fun storeIdOf(songId: String): String? {
            if (!songId.startsWith(AD_HOC_PREFIX) || songId.startsWith(AD_HOC_ALBUM_PREFIX)) return null
            return songId.removePrefix(AD_HOC_PREFIX).takeIf { it.isNotBlank() }
        }

        private const val AD_HOC_ALBUM_PREFIX = "amrec_album_"
    }
}

/** Seam: ask the rip pipeline to start capturing an AM-only match (false = no rip server configured). */
fun interface JukeboxAdHocRipStarter {
    suspend fun start(song: IndexSong): Boolean
}
