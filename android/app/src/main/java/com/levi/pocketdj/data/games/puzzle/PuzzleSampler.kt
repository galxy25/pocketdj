package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.screens.browse.Genre
import kotlin.math.ln

/**
 * Pure weighted sampler behind the Gem Collector queue — port of iOS `PuzzleSampler`.
 * No stores, no Android types: callers snapshot [RawInputs] on the main thread (cheap —
 * immutable collections by reference) and run [Inputs.fromRaw] + [sample] on
 * `Dispatchers.Default`.
 */
object PuzzleSampler {

    private fun log2(x: Double): Double = ln(x) / ln(2.0)

    /**
     * What the MAIN thread hands over: raw containers only, no derived work. The ~96k-entry
     * genre map, membership sets, decayed recencies and similarity profile are built in
     * [Inputs.fromRaw].
     */
    data class RawInputs(
        val songs: List<IndexSong>,
        val albumsById: Map<String, IndexAlbum>,
        val favoriteIds: Set<String>,
        val playCounts: Map<String, Int>,
        /** Member ids of each `settings.membershipCollectionIds` collection… */
        val membershipCollections: List<List<String>>,
        /** …and of each `settings.targetCollectionIds` collection. */
        val targetCollections: List<List<String>>,
        /** The rip manifest — songs whose mp3 already sits in S3. */
        val ripManifest: Map<String, RipManifestEntry> = emptyMap(),
        /** Songs with a burned file ready ON THIS DEVICE. */
        val burnedIds: Set<String> = emptySet(),
        /** Android has no MusicKit, so this is normally false; kept for iOS shape parity. */
        val canStreamAppleMusic: Boolean = false,
        /** EVERY collection's membership — the "shared with another collection" signal. */
        val allCollections: List<List<String>> = emptyList(),
        val plays: List<PlayEvent> = emptyList(),
        /** songId → 0…1 cloud similarity rank, fetched ONCE per round. */
        val cloudRanks: Map<String, Double> = emptyMap(),
        /** Skip the profile build when the round can't use it (no targets / similarity off). */
        val buildSimilarityProfile: Boolean = true,
        /** songId → last-played epoch ms. Sparse; absent means never played. */
        val lastPlayedMs: Map<String, Double> = emptyMap(),
        /** Does the DEVICE know any last-played dates at all? */
        val hasRecency: Boolean = false,
        /** "Now" for the decay, injected so tests are deterministic. */
        val nowMs: Double = System.currentTimeMillis().toDouble(),
        /** Thumbed-down for one of this round's targets, still tombstoned. */
        val suppressedForTargets: Set<String> = emptySet(),
    )

    data class Inputs(
        val songs: List<IndexSong>,
        /** songId → `Genre.category` (from the owning album). */
        val genreBySongId: Map<String, String>,
        val favoriteIds: Set<String>,
        val playCounts: Map<String, Int>,
        /** Union of songIds in `settings.membershipCollectionIds`. */
        val membershipUnion: Set<String>,
        /** Existing membership of EACH target — a song in ALL of them never samples. */
        val perTargetMembership: List<Set<String>>,
        /** Songs whose audio can START NOW (ripped S3 mp3 or burned local file). */
        val playableNowIds: Set<String> = emptySet(),
        val canStreamAppleMusic: Boolean = false,
        val similarityProfile: PuzzleSimilarity.TargetProfile = PuzzleSimilarity.TargetProfile(),
        val cloudRanks: Map<String, Double> = emptyMap(),
        /** songId → 0…1 `PlayRecency` score, derived ONCE in [fromRaw]. Absent ≡ 0. */
        val recencies: Map<String, Double> = emptyMap(),
        val hasRecency: Boolean = false,
        val suppressedForTargets: Set<String> = emptySet(),
    ) {
        /** Can THIS song make sound right now? */
        fun isPlayableNow(song: IndexSong): Boolean {
            if (song.id in playableNowIds) return true
            return canStreamAppleMusic && song.appleMusicId != null
        }

        companion object {
            /** Build the derived structures from a [RawInputs] snapshot. CALL OFF THE MAIN THREAD. */
            fun fromRaw(raw: RawInputs): Inputs {
                val genreBySongId = HashMap<String, String>(raw.songs.size * 2)
                // Genre lives on the ALBUM; category once per album, then fan out.
                val categoryByAlbum = HashMap<String, String>()
                val wantsProfile = raw.buildSimilarityProfile && raw.targetCollections.isNotEmpty()
                val songsById = HashMap<String, IndexSong>()
                for (song in raw.songs) {
                    if (wantsProfile) songsById[song.id] = song
                    val albumId = song.albumId ?: continue
                    val cat = categoryByAlbum.getOrPut(albumId) { Genre.category(raw.albumsById[albumId]?.genre) }
                    genreBySongId[song.id] = cat
                }
                val membershipUnion = HashSet<String>()
                for (ids in raw.membershipCollections) membershipUnion.addAll(ids)
                val playable = HashSet<String>(raw.ripManifest.keys)
                playable.addAll(raw.burnedIds)
                // Decay every known date ONCE, here.
                val recencies = HashMap<String, Double>()
                for ((id, ms) in raw.lastPlayedMs) {
                    val r = PlayRecency.score(ms, raw.nowMs)
                    if (r > 0) recencies[id] = r
                }
                val profile = if (wantsProfile) {
                    PuzzleSimilarity.profile(
                        targetMemberIds = raw.targetCollections,
                        songsById = songsById,
                        genreBySongId = genreBySongId,
                        otherCollections = raw.allCollections,
                        plays = raw.plays.map { PuzzleSimilarity.Play(it.songId, it.playedAt) },
                        hasRecency = raw.hasRecency,
                        nowMs = raw.nowMs,
                    )
                } else {
                    PuzzleSimilarity.TargetProfile()
                }
                return Inputs(
                    songs = raw.songs,
                    genreBySongId = genreBySongId,
                    favoriteIds = raw.favoriteIds,
                    playCounts = raw.playCounts,
                    membershipUnion = membershipUnion,
                    perTargetMembership = raw.targetCollections.map { it.toSet() },
                    playableNowIds = playable,
                    canStreamAppleMusic = raw.canStreamAppleMusic,
                    similarityProfile = profile,
                    cloudRanks = raw.cloudRanks,
                    recencies = recencies,
                    hasRecency = raw.hasRecency,
                    suppressedForTargets = raw.suppressedForTargets,
                )
            }
        }
    }

    /**
     * The filtered pool with per-song weights. PLAYABILITY is preferred, not absolute: the
     * pool is built from playable-now songs, and ONLY if that RESULT is empty is it rebuilt
     * over everything (a silent round beats an unstartable one). Similarity runs INSIDE:
     * playability is the outer gate, similarity the inner ranker.
     */
    fun pool(
        settings: PuzzleSettings,
        inputs: Inputs,
        excluding: Set<String> = emptySet(),
        wanted: Int = 60,
    ): List<PuzzleCandidate> {
        val playable = pool(settings, inputs, excluding, playableOnly = true)
        if (playable.isNotEmpty()) return similar(playable, settings, inputs, wanted)
        val all = pool(settings, inputs, excluding, playableOnly = false)
        return similar(all, settings, inputs, wanted)
    }

    private fun similar(
        candidates: List<PuzzleCandidate>,
        settings: PuzzleSettings,
        inputs: Inputs,
        wanted: Int,
    ): List<PuzzleCandidate> = PuzzleSimilarity.shortlist(
        candidates,
        profile = inputs.similarityProfile,
        genreBySongId = inputs.genreBySongId,
        cloudRanks = inputs.cloudRanks,
        recencies = inputs.recencies,
        mode = settings.similarity,
        wanted = wanted,
    )

    /** What the setup screen's readout needs: songs matching the filters + the shortlist size. */
    data class PoolStats(val matched: Int = 0, val similar: Int? = null)

    fun poolStats(settings: PuzzleSettings, inputs: Inputs, wanted: Int = 60): PoolStats {
        var base = pool(settings, inputs, emptySet(), playableOnly = true)
        if (base.isEmpty()) base = pool(settings, inputs, emptySet(), playableOnly = false)
        if (settings.similarity == PuzzleSettings.Similarity.OFF || inputs.similarityProfile.isEmpty) {
            return PoolStats(matched = base.size, similar = null)
        }
        return PoolStats(matched = base.size, similar = similar(base, settings, inputs, wanted).size)
    }

    private fun pool(
        settings: PuzzleSettings,
        inputs: Inputs,
        excluding: Set<String>,
        playableOnly: Boolean,
    ): List<PuzzleCandidate> {
        val out = ArrayList<PuzzleCandidate>(inputs.songs.size / 2)
        val hasYearBound = settings.yearMin != null || settings.yearMax != null
        for (song in inputs.songs) {
            if (song.id in excluding) continue
            // Thumbed down for one of this round's targets, inside its seven days.
            if (song.id in inputs.suppressedForTargets) continue
            // Rip-ON-DEMAND deliberately does NOT count as playable (real-time capture).
            if (playableOnly && !inputs.isPlayableNow(song)) continue
            if (hasYearBound) {
                val year = song.year ?: continue
                val lo = settings.yearMin
                val hi = settings.yearMax
                if (lo != null && year < lo) continue
                if (hi != null && year > hi) continue
            }
            if (settings.genreCategories.isNotEmpty()) {
                val cat = inputs.genreBySongId[song.id] ?: Genre.OTHER
                if (cat !in settings.genreCategories) continue
            }
            when (settings.membershipMode) {
                PuzzleSettings.MembershipMode.IN_ANY -> if (song.id !in inputs.membershipUnion) continue
                PuzzleSettings.MembershipMode.NOT_IN_ANY -> if (song.id in inputs.membershipUnion) continue
                PuzzleSettings.MembershipMode.OFF -> Unit
            }
            // Already in EVERY target ⇒ nothing left to assign.
            if (inputs.perTargetMembership.isNotEmpty() &&
                inputs.perTargetMembership.all { song.id in it }
            ) continue

            var weight = 1.0
            when (settings.favoriteBias) {
                PuzzleSettings.Bias.FAVOR -> weight *= if (song.id in inputs.favoriteIds) 4.0 else 1.0
                PuzzleSettings.Bias.AVOID -> weight *= if (song.id in inputs.favoriteIds) 0.25 else 1.0
                PuzzleSettings.Bias.OFF -> Unit
            }
            when (settings.playCountBias) {
                PuzzleSettings.Bias.FAVOR -> {
                    val count = inputs.playCounts[song.id] ?: 0
                    weight *= 1 + log2(1 + count.toDouble())
                }
                PuzzleSettings.Bias.AVOID -> {
                    val count = inputs.playCounts[song.id] ?: 0
                    weight *= if (count == 0) 4.0 else 1 / (1 + log2(1 + count.toDouble()))
                }
                PuzzleSettings.Bias.OFF -> Unit
            }
            // RECENCY — a SEPARATE axis, its own multiplier, so the two compose.
            when (settings.recencyBias) {
                PuzzleSettings.Bias.FAVOR -> {
                    val r = inputs.recencies[song.id] ?: 0.0
                    weight *= 1 + PlayRecency.GAIN * r
                }
                PuzzleSettings.Bias.AVOID -> {
                    val r = inputs.recencies[song.id] ?: 0.0
                    weight *= if (r <= 0) 4.0 else 1 / (1 + PlayRecency.GAIN * r)
                }
                PuzzleSettings.Bias.OFF -> Unit
            }
            out += PuzzleCandidate(song, weight)
        }
        return out
    }

    /** How many songs match the settings. */
    fun poolCount(settings: PuzzleSettings, inputs: Inputs): Int = pool(settings, inputs).size

    /**
     * Weighted sample WITHOUT replacement: n draws, swap-remove. [rng] is injected
     * (`Prng.seededRng` in tests).
     */
    fun sample(
        n: Int,
        settings: PuzzleSettings,
        inputs: Inputs,
        rng: () -> Double,
        excluding: Set<String> = emptySet(),
    ): List<IndexSong> {
        val candidates = ArrayList(pool(settings, inputs, excluding, wanted = n))
        if (candidates.isEmpty()) return emptyList()
        val picked = ArrayList<IndexSong>(minOf(n, candidates.size))
        var total = candidates.sumOf { it.weight }
        while (picked.size < n && candidates.isNotEmpty() && total > 0) {
            val target = rng() * total
            var acc = 0.0
            var hit = candidates.size - 1
            for ((i, c) in candidates.withIndex()) {
                acc += c.weight
                if (target < acc) { hit = i; break }
            }
            val chosen = candidates[hit]
            picked += chosen.song
            total -= chosen.weight
            candidates[hit] = candidates[candidates.size - 1]
            candidates.removeAt(candidates.size - 1)
        }
        return picked
    }
}
