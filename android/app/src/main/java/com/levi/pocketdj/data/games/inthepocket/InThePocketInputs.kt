package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import com.levi.pocketdj.screens.browse.Genre

/** What can make sound right now (iOS `CollectorsPuzzleEngine.AudioAvailability`). */
data class InThePocketAudio(
    val ripIds: Set<String> = emptySet(),
    val burnedIds: Set<String> = emptySet(),
    /** Apple Music reachable: AM-only songs ride as cached 30 s previews on Android. */
    val canStreamAppleMusic: Boolean = false,
)

/**
 * Catalog + history -> the scorer's [InThePocketScorer.Input] (port of `InThePocketStore.makeInput`).
 * PURE and meant to run OFF the main thread: only songs that are playable, in the history, or in a
 * collection are converted (the catalog is ~96k rows; a round needs a small slice of it).
 */
object InThePocketInputs {

    fun makeInput(
        context: InThePocketContext,
        contextLabel: String?,
        results: ListeningPocketsResults?,
        songs: Map<String, IndexSong>,
        albums: Map<String, IndexAlbum>,
        audio: InThePocketAudio,
        events: List<PlayEvent>,
        pastRounds: List<InThePocketRound>,
        nowMs: Double,
        seed: ULong,
        collections: List<InThePocketScorer.CollectionInfo> = emptyList(),
    ): InThePocketScorer.Input {
        val playable = HashSet<String>()
        playable.addAll(audio.ripIds)
        playable.addAll(audio.burnedIds)
        if (audio.canStreamAppleMusic) {
            for (s in songs.values) if (s.appleMusicId != null) playable.add(s.id)
        }
        playable.retainAll { it in songs }
        val wanted = HashSet(playable)
        for (e in events) wanted.add(SongVariant.baseId(e.songId))
        val infos = collections.filter { it.songIds.isNotEmpty() }
        for (c in infos) wanted.addAll(c.songIds)

        val genreByAlbum = HashMap<String, String?>()
        val catalog = HashMap<String, InThePocketScorer.Song>(wanted.size * 2)
        for (id in wanted) {
            val s = songs[id] ?: continue
            var genre: String? = null
            val aid = s.albumId
            if (aid != null) {
                genre = if (genreByAlbum.containsKey(aid)) genreByAlbum[aid] else {
                    val cat = Genre.category(albums[aid]?.genre)
                    (if (cat == Genre.OTHER) null else cat.lowercase()).also { genreByAlbum[aid] = it }
                }
            }
            catalog[id] = InThePocketScorer.Song(
                id = s.id, title = s.name, artist = s.artist, lengthMs = s.length?.toInt(),
                genre = genre, bpm = s.bpm, camelot = s.camelot,
                moods = (s.sentimentKeywords ?: emptyList()).map { it.lowercase() },
            )
        }
        val plays = events.map {
            InThePocketScorer.Play(
                songId = SongVariant.baseId(it.songId), atMs = it.playedAt,
                tzOffsetMin = it.tzOffsetMin ?: 0, outcome = it.outcome.name.lowercase(), ctx = null,
            )
        }
        return InThePocketScorer.Input(
            context = context, contextLabel = contextLabel, results = results, catalog = catalog,
            playableIds = playable, plays = plays, pastRounds = pastRounds, nowMs = nowMs, seed = seed,
            collections = infos,
        )
    }
}
