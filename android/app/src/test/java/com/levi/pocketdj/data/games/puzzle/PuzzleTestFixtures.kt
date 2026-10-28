package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong

internal fun song(
    id: String,
    artist: String = "A",
    year: Int? = null,
    keywords: List<String>? = null,
    albumId: String? = null,
    appleMusicId: String? = null,
) = IndexSong(
    id = id, albumId = albumId, artist = artist, name = id.uppercase(), year = year,
    sentimentKeywords = keywords, appleMusicId = appleMusicId,
)

internal fun album(id: String, genre: String) = IndexAlbum(id = id, artist = "A", name = id, genre = genre)

internal fun rows(songs: List<IndexSong>) = songs.map { PuzzleCandidate(it, 1.0) }

/** Inputs builder mirroring the iOS test helper (hasRecency follows a non-empty recency map). */
internal fun inputs(
    songs: List<IndexSong>,
    genres: Map<String, String> = emptyMap(),
    favorites: Set<String> = emptySet(),
    playCounts: Map<String, Int> = emptyMap(),
    membershipUnion: Set<String> = emptySet(),
    perTarget: List<Set<String>> = emptyList(),
    recencies: Map<String, Double> = emptyMap(),
    playable: Set<String> = emptySet(),
    canStream: Boolean = false,
    profile: PuzzleSimilarity.TargetProfile = PuzzleSimilarity.TargetProfile(),
) = PuzzleSampler.Inputs(
    songs = songs, genreBySongId = genres, favoriteIds = favorites, playCounts = playCounts,
    membershipUnion = membershipUnion, perTargetMembership = perTarget,
    playableNowIds = playable, canStreamAppleMusic = canStream, similarityProfile = profile,
    recencies = recencies, hasRecency = recencies.isNotEmpty(),
)
