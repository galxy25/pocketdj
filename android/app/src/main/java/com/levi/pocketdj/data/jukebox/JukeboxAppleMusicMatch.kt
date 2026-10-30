package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.applemusic.AmSearchType
import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.shazam.AppleMusicRecognition
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Stage 4 of the iOS four-stage matcher (SURF-10): the Apple Music catalog search for songs the
 * library does not have at all. Developer-token catalog search only (no sign-in needed). A hit may
 * map BACK to an indexed song (store id / appleMusicId / normalized title+artist); otherwise it is an
 * AM-only match carried as an ad-hoc [IndexSong] under the colon-free `amrec_<storeId>` id - the same
 * id the recognizer's add flow rips and burns with (Android has no MusicKit stream, so a rip is
 * how an AM-only row becomes audible).
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

        /** An Apple-Music-only row (not in the library): playable only after a rip. */
        fun isAdHoc(songId: String): Boolean = songId.startsWith(AD_HOC_PREFIX)
    }
}

/** Seam: ask the rip pipeline to prepare an AM-only match (false = no rip server configured). */
fun interface JukeboxAdHocRipStarter {
    suspend fun start(song: IndexSong): Boolean
}

/**
 * Placement sink for AM-only rows: they have no audio until the rip lands, so wait (bounded) for it,
 * then return false so the repository's normal queue placement runs. Rows that already have a rip,
 * and every library row, pass straight through. A timeout throws, which the repository treats as
 * "not handled" and surfaces as a transient "isn't playable" hint.
 */
class JukeboxAmPlacementSink(
    private val isPlayable: (String) -> Boolean,
    private val waitMs: Long = 15 * 60 * 1000L,
    private val pollMs: Long = 2_000L,
) : JukeboxPlacementSink {
    override suspend fun place(song: IndexSong, action: JukeboxDecisionAction): Boolean {
        if (!JukeboxAppleMusicMatch.isAdHoc(song.id) || isPlayable(song.id)) return false
        withTimeoutOrNull(waitMs) {
            while (!isPlayable(song.id)) delay(pollMs)
        } ?: throw IllegalStateException("“${song.name}” didn't finish ripping in time")
        return false
    }
}
