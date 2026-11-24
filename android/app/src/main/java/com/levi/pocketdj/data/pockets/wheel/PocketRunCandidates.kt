package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionFlattener
import com.levi.pocketdj.data.games.inthepocket.InThePocketAudio
import com.levi.pocketdj.data.pockets.ListeningPocketsCollections
import com.levi.pocketdj.data.recs.RecVersionIdentity
import com.levi.pocketdj.screens.browse.Genre

/**
 * Builds the run planner's candidate universe OFF the main thread (iOS `PocketRunCandidates`): every PLAYABLE song
 * (rip manifest / burned / Apple Music with a store id) with its features and its hard collection memberships
 * (add-time recency). PURE.
 */
object PocketRunCandidates {

    fun build(
        songs: Map<String, IndexSong>,
        albums: Map<String, IndexAlbum>,
        availability: InThePocketAudio,
        collections: ListeningPocketsCollections.Input,
        favorites: Set<String>,
        timbre: Map<String, Map<String, Double>>,
        nowMs: Double,
    ): Map<String, PocketRunPlanner.Candidate> {
        val playable = HashSet<String>(availability.ripIds)
        playable.addAll(availability.burnedIds)
        if (availability.canStreamAppleMusic) {
            for (s in songs.values) if (s.appleMusicId != null) playable.add(s.id)
        }
        playable.retainAll { it in songs }
        // Hard memberships (the same flattening the wheel and the upload use).
        val flat = CollectionFlattener.flatten(collections.source)
        val adds = CollectionFlattener.addTimes(
            collections = flat, activity = collections.activity,
            pockets = collections.source.pockets, albumTracks = collections.source.albumTracks,
        )
        val memberships = HashMap<String, MutableMap<String, Double>>()
        for (c in flat) {
            for (s in c.songIds) {
                if (s !in playable) continue
                memberships.getOrPut(s) { HashMap() }[c.id] = PocketMomentEngine.membershipScale(adds[c.id]?.get(s), nowMs)
            }
        }
        for (s in favorites) {
            if (s !in playable) continue
            memberships.getOrPut(s) { HashMap() }[PocketWheelIds.FAVORITES] = PocketMomentEngine.UNKNOWN_ADD_SCALE
        }
        val genreByAlbum = HashMap<String, String?>()
        val out = HashMap<String, PocketRunPlanner.Candidate>(playable.size * 2)
        for (id in playable) {
            val s = songs[id] ?: continue
            var genre: String? = null
            val aid = s.albumId
            if (aid != null) {
                genre = if (genreByAlbum.containsKey(aid)) genreByAlbum[aid] else {
                    val cat = Genre.category(albums[aid]?.genre)
                    (if (cat == Genre.OTHER) null else cat.lowercase()).also { genreByAlbum[aid] = it }
                }
            }
            val keys = RecVersionIdentity.creditArtistKeys(s.artist)
            out[id] = PocketRunPlanner.Candidate(
                id = id, title = s.name, artist = s.artist, lengthMs = s.length?.toInt(),
                features = PocketTuning.Features(
                    artistKeys = keys.ifEmpty { listOf(s.artist.lowercase()) }, album = s.albumId,
                    genre = genre, year = s.year, bpm = s.bpm, timbre = timbre[id],
                ),
                camelot = s.camelot, memberships = memberships[id] ?: emptyMap(),
                startsInstantly = id in availability.burnedIds,
            )
        }
        return out
    }
}
