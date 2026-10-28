package com.levi.pocketdj.mix.download

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource

/** What the resolver reads: the collections + catalog + burn existence check (JVM-fakeable). */
interface MixResolverSources {
    /** A pocket's DAG-resolved, deduped ordered song ids. */
    fun pocketSongIds(pocketId: String): List<String>
    /** A playlist's catalog-resolved ordered song ids (albums/pockets expanded). */
    fun playlistSongIds(playlistId: String): List<String>
    fun setlist(setlistId: String): Setlist?
    fun song(songId: String): IndexSong?
    /** NON-holding existence check for a burned file (iOS `BurnStore.localURL`). */
    fun isOnDisk(songId: String): Boolean
}

/**
 * iOS `MixResolver`: chosen [MixSource] -> ordered LOADABLE [MixLoadable]s. Keeps only ids whose
 * burned file exists OR that the deck can stream ([streamable]); drops notes/text/un-burned;
 * dedupes by songId, first-seen wins; setlist rows use frozen snapshot metadata and fall back to
 * the catalog for albumId/key and any field the snapshot left blank. The Studio / "Pocket DJ"
 * profile branches are N/A on Android (no such sources); the [MixLoadable] shape is unchanged so
 * they can slot in later.
 */
class MixResolver(
    private val sources: MixResolverSources,
    /** STREAMING MODE seam (`MixEngine.canStream`): a ripped-not-burned song is loadable too. */
    var streamable: ((String) -> Boolean)? = null,
) {
    fun loadables(source: MixSource): List<MixLoadable> = when (source) {
        is MixSource.Pocket -> loadables(sources.pocketSongIds(source.value))
        is MixSource.Playlist -> loadables(sources.playlistSongIds(source.value))
        is MixSource.Setlist -> setlistLoadables(source.value)
    }

    /**
     * The crate's downloadable member ids in play order (iOS `CollectionsStore.ripIds` seam):
     * deduped, text/blank rows dropped, regardless of whether they are on disk yet.
     */
    fun memberIds(source: MixSource): List<String> {
        val raw = when (source) {
            is MixSource.Pocket -> sources.pocketSongIds(source.value)
            is MixSource.Playlist -> sources.playlistSongIds(source.value)
            is MixSource.Setlist -> sources.setlist(source.value)?.tracks.orEmpty()
                .filter { it.isText != true }.map { it.songId }
        }
        val seen = HashSet<String>()
        return raw.filter { it.isNotBlank() && seen.add(it) }
    }

    private fun loadables(songIds: List<String>): List<MixLoadable> {
        val seen = HashSet<String>()
        return songIds.mapNotNull { id ->
            if (!seen.add(id)) return@mapNotNull null
            val song = sources.song(id)
            if (song == null || !isLoadable(id)) return@mapNotNull null
            MixLoadable(
                songId = id, title = song.name, artist = song.artist, bpm = song.bpm,
                camelot = song.camelot, key = song.key, albumId = song.albumId,
                lengthMs = song.length?.toInt(),
            )
        }
    }

    private fun setlistLoadables(setlistId: String): List<MixLoadable> {
        val setlist = sources.setlist(setlistId) ?: return emptyList()
        val seen = HashSet<String>()
        return setlist.tracks.mapNotNull { t ->
            if (t.isText == true || t.songId.isEmpty() || !seen.add(t.songId)) return@mapNotNull null
            if (!isLoadable(t.songId)) return@mapNotNull null
            val song = sources.song(t.songId)
            MixLoadable(
                songId = t.songId,
                title = t.name.ifEmpty { song?.name ?: t.songId },
                artist = t.artist.ifEmpty { song?.artist ?: "" },
                bpm = t.bpm ?: song?.bpm,
                camelot = t.camelot ?: song?.camelot,
                key = song?.key,
                albumId = song?.albumId,
                lengthMs = (t.lengthMs ?: song?.length)?.toInt(),
            )
        }
    }

    private fun isLoadable(songId: String): Boolean =
        sources.isOnDisk(songId) || streamable?.invoke(songId) == true
}
