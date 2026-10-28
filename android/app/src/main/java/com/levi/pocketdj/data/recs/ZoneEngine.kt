package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.games.puzzle.PlayRecency
import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Port of `ZoneEngine.swift`: the ranking behind the For You tiles. **In Da Zone** (what to play
 * right now, from recent activity) and **collection suggestions** (what to add to a collection).
 *
 * Pure functions over value types: no store, no I/O, callable off the main thread. Behavior is
 * ported faithfully, including the invariants the iOS file documents:
 *  - the two zone pools are exactly complementary on [Tuning.rediscoveryQuietDays];
 *  - the per-artist cap outranks the rediscovery floor and the floor is checked per slot;
 *  - every aux/timbre/skip term is a BOUNDED MULTIPLIER on similarity (similarity gates);
 *  - accepted ids join the taste profile but never the familiar pool; rejected ids build a
 *    subtracted negative profile; only [Feedback.suppressed] removes a row;
 *  - one recording, one row (cross-pool keepMask) at the single choke point;
 *  - the SOUND DOOR is the only way past the artist/genre gate and every demotion the scored
 *    path applies is a veto there too;
 *  - empty timbre ⇒ ranking byte-identical to pre-v2.
 */
object ZoneEngine {

    private const val MS_PER_DAY = 86_400_000.0
    private const val MS_PER_HOUR = 3_600_000.0

    // ── Inputs ──────────────────────────────────────────────────────────────────────────

    /** Catalog projection. Everything past [genre] is optional (coverage 99.2% / 10.4% / 10.4%). */
    data class Track(
        val songId: String,
        /** `IndexArtist.normalize(artist)`. */
        val artistKey: String,
        val artistName: String,
        /** Top-tier genre category, nil when the album carries none ("Other" ⇒ null). */
        val genre: String?,
        val year: Int? = null,
        val bpm: Double? = null,
        val camelot: String? = null,
        /** IDENTITY only, never a ranking signal. */
        val appleMusicId: String? = null,
        /** RAW title; parsed once by [versionKeys]. */
        val title: String? = null,
        val lengthMs: Int? = null,
        /** RAW album genre label — variety (diversity floor / sound quota), not similarity. */
        val genreRaw: String? = null,
    )

    /** song id → comparable version identity, parsed ONCE per refresh (artist half memoized). */
    fun versionKeys(tracks: List<Track>): Map<String, RecVersionIdentity.Key> {
        val out = HashMap<String, RecVersionIdentity.Key>(tracks.size * 2)
        val artistKeys = HashMap<String, String>()
        for (t in tracks) {
            val title = t.title ?: continue
            val ak = artistKeys.getOrPut(t.artistName) { RecVersionIdentity.artistKey(t.artistName) }
            RecVersionIdentity.keyWithArtistKey(title, ak)?.let { out[t.songId] = it }
        }
        return out
    }

    private fun identity(
        id: String,
        songsById: Map<String, IndexSong>,
        artistKeys: MutableMap<String, String>,
    ): RecRecordingIdentity.Identity {
        val s = songsById[id] ?: return RecRecordingIdentity.Identity(baseId = SongVariant.baseId(id))
        val ak = artistKeys.getOrPut(s.artist) { RecVersionIdentity.artistKey(s.artist) }
        return RecRecordingIdentity.identity(
            songId = id,
            appleMusicId = s.appleMusicId,
            version = RecVersionIdentity.keyWithArtistKey(s.name, ak),
            lengthMs = s.length?.toInt(),
        )
    }

    /** One play from the append-only history log. */
    data class Play(val songId: String, val playedAtMs: Double)

    /** Every knob in one place. Defaults are the shipped iOS values. */
    data class Tuning(
        val halfLifeDays: Double = 7.0,
        /** Window that BUILDS the taste profile AND gates pool B ⇒ pools exactly complementary. */
        val rediscoveryQuietDays: Double = 60.0,
        val cooldownHours: Double = 6.0,
        val maxPerArtist: Int = 3,
        val minSongs: Int = 30,
        val maxSongs: Int = 90,
        val rediscoveryFloor: Double = 0.5,
        val familiarityWeight: Double = 0.30,
        val auxGain: Double = 0.6,
        val dormancyWeight: Double = 0.40,
        val auxFamiliarityWeight: Double = 0.30,
        val auxNoveltyWeight: Double = 0.30,
        val balance: SimilarityFamilies.Balance? = SimilarityFamilies.Balance.EVEN,
        val rejectionWeight: Double = 0.5,
        val skipPenaltyWeight: Double = 0.35,
        val acceptedSeedWeight: Double = 1.0,
        val shortlistCap: Int = 6_000,
        val suggestionAuxGain: Double = 0.40,
        val suggestionNoveltyWeight: Double = 0.75,
        val suggestionFamiliarityWeight: Double = 0.25,
        val suggestionIncumbentMaxShare: Double = 0.5,
        val timbreGain: Double = 0.35,
        val soundAdmitMaxShare: Double = 0.12,
        val soundAdmitHardCap: Int = 3,
        val suggestionMinRawGenreShare: Double = 0.25,
        val suggestionDiversityMaxSwapShare: Double = 0.2,
    ) {
        companion object {
            /** Rejections of one artist/genre that make the collection-tile penalty FULL strength. */
            const val REJECTION_SATURATION: Double = 3.0
        }
    }

    // ── The queue ───────────────────────────────────────────────────────────────────────

    enum class Pool { FAMILIAR, REDISCOVERY }

    data class Pick(val songId: String, val pool: Pool)

    /**
     * The listener's 👍/👎 as value types. All four empty ⇒ every ranking is exactly what it
     * was before feedback existed.
     */
    data class Feedback(
        /** songId → decayed 👍 weight. Joins the taste profile; never the familiar pool. */
        val accepted: Map<String, Double> = emptyMap(),
        /** songId → decayed 👎 weight. Builds the subtracted negative profile. NEVER a filter. */
        val rejected: Map<String, Double> = emptyMap(),
        /** Tombstoned in THIS list right now — the only thing that removes a row. */
        val suppressed: Set<String> = emptySet(),
        /** songId → pre-dampened skip pressure 0…1. Bounded demotion, never removal. */
        val skipPenalty: Map<String, Double> = emptyMap(),
    ) {
        val isEmpty: Boolean
            get() = accepted.isEmpty() && rejected.isEmpty() && suppressed.isEmpty() && skipPenalty.isEmpty()

        companion object {
            /**
             * DAMPENED plays-vs-skips ratio: `min(1, skips / (max(plays, skips) + k))`. One skip of
             * one play ⇒ 0.25; zero-skip songs get no entry.
             */
            fun skipPenalties(plays: Map<String, Int>, skips: Map<String, Int>, k: Double = 3.0): Map<String, Double> {
                val out = HashMap<String, Double>(skips.size * 2)
                for ((id, s) in skips) {
                    if (s <= 0) continue
                    val p = max((plays[id] ?: 0).toDouble(), s.toDouble())
                    out[id] = min(1.0, s.toDouble() / (p + k))
                }
                return out
            }
        }
    }

    data class Queue(val picks: List<Pick> = emptyList()) {
        val songIds: List<String> get() = picks.map { it.songId }
        val isEmpty: Boolean get() = picks.isEmpty()
        val count: Int get() = picks.size
        fun count(pool: Pool): Int = picks.count { it.pool == pool }
        val rediscoveryShare: Double
            get() = if (picks.isEmpty()) 0.0 else count(Pool.REDISCOVERY).toDouble() / picks.size
        /** True when the library, not the ranking, was the limit on rediscoveries. */
        val degradesToFamiliar: Boolean get() = picks.isNotEmpty() && rediscoveryShare < 0.5
    }

    private class Cand(val id: String, val capKey: String, val score: Double)

    private val byScore = Comparator<Cand> { a, b ->
        val c = b.score.compareTo(a.score)
        if (c != 0) c else a.id.compareTo(b.id)
    }

    /**
     * The similarity-free half of the rediscovery score: dormancy + buried-favourite familiarity +
     * ARTIST novelty, renormalised over whichever of the three this run can speak (a device with no
     * last-played data does not silently deflate every score). Also the bounded skip multiplier.
     */
    private class ZoneSignals(
        private val tuning: Tuning,
        private val playCount: (String) -> Int,
        private val maxPlays: Int,
        private val feedback: Feedback,
        private val lastPlayedMs: Map<String, Double>,
        private val nowMs: Double,
        private val artistFam: RecNovelty.ArtistFamiliarity,
    ) {
        private val famDenom = log2(1.0 + max(maxPlays, 1))
        private val hasDormancy = lastPlayedMs.isNotEmpty()
        private val hasFamiliarity = maxPlays > 0
        private val hasNovelty = artistFam.isLive

        val auxBaseDen: Double = tuning.dormancyWeight * (if (hasDormancy) 1 else 0) +
            tuning.auxFamiliarityWeight * (if (hasFamiliarity) 1 else 0) +
            tuning.auxNoveltyWeight * (if (hasNovelty) 1 else 0)

        fun familiarity(id: String): Double {
            val n = playCount(id)
            if (n <= 0 || famDenom <= 0 || maxPlays <= 0) return 0.0
            return log2(1.0 + n) / famDenom
        }

        /** 1.0 for a never-skipped song; clamped so a malformed penalty can neither zero nor lift. */
        fun skipFactor(id: String): Double {
            val p = feedback.skipPenalty[id] ?: return 1.0
            return 1 - tuning.skipPenaltyWeight * min(1.0, max(0.0, p))
        }

        fun auxOnly(id: String, capKey: String): Double {
            var num = 0.0
            var den = 0.0
            if (hasDormancy) {
                num += tuning.dormancyWeight * (1 - PlayRecency.score(lastPlayedMs[id], nowMs))
                den += tuning.dormancyWeight
            }
            if (hasFamiliarity) {
                num += tuning.auxFamiliarityWeight * familiarity(id)
                den += tuning.auxFamiliarityWeight
            }
            if (hasNovelty) {
                num += tuning.auxNoveltyWeight * artistFam.novelty(capKey)
                den += tuning.auxNoveltyWeight
            }
            return if (den > 0) num / den else 0.0
        }
    }

    // ── In Da Zone ──────────────────────────────────────────────────────────────────────

    /**
     * What to play right now: a blend of FAMILIAR (played inside the quiet window, recency
     * decayed) and REDISCOVERY (owned but dormant, similarity to a taste profile built from the
     * familiar pool, nudged by dormancy / buried-favourite familiarity / artist novelty / timbre).
     */
    fun inDaZone(
        songs: List<IndexSong>,
        genreBySongId: Map<String, String> = emptyMap(),
        otherCollections: List<List<String>> = emptyList(),
        plays: List<Play>,
        playCount: (String) -> Int,
        lastPlayedMs: Map<String, Double> = emptyMap(),
        feedback: Feedback = Feedback(),
        timbre: Map<String, Map<String, Double>> = emptyMap(),
        nowMs: Double,
        tuning: Tuning = Tuning(),
    ): Queue {
        if (songs.isEmpty()) return Queue()
        val songsById = HashMap<String, IndexSong>(songs.size * 2)
        for (s in songs) songsById.putIfAbsent(s.id, s)

        val windowMs = tuning.rediscoveryQuietDays * MS_PER_DAY
        val cooldownMs = tuning.cooldownHours * MS_PER_HOUR
        val halfLifeMs = tuning.halfLifeDays * MS_PER_DAY

        // 1. Recent activity → seed weights. A future-dated play clamps to "now" (never dropped).
        val seedWeight = HashMap<String, Double>()
        val onCooldown = HashSet<String>()
        for (p in plays) {
            val age = nowMs - p.playedAtMs
            if (age < cooldownMs) onCooldown.add(p.songId)
            if (age > windowMs || songsById[p.songId] == null) continue
            seedWeight.merge(p.songId, 2.0.pow(-max(0.0, age) / halfLifeMs), Double::plus)
        }

        // 2. Taste profile: seed + 👍 (but 👍 NEVER joins seedWeight, which partitions the pools).
        val tasteWeight = HashMap(seedWeight)
        for ((id, w) in feedback.accepted) {
            if (songsById[id] != null) tasteWeight.merge(id, w * tuning.acceptedSeedWeight, Double::plus)
        }
        // plays = [] and hasRecency = false are deliberate (see iOS commentary).
        val taste = Similarity.profile(
            targetMemberIds = listOf(tasteWeight.keys.toList()),
            songsById = songsById,
            genreBySongId = genreBySongId,
            otherCollections = otherCollections,
            plays = emptyList(),
            hasRecency = false,
            memberWeights = tasteWeight,
            balance = tuning.balance,
            nowMs = nowMs,
        ).calibrated(songs)
        // The negative profile: same machinery, no co-membership, calibrated on the SAME pool.
        val distaste: Similarity.TargetProfile? = if (feedback.rejected.isEmpty()) null else
            Similarity.profile(
                targetMemberIds = listOf(feedback.rejected.keys.toList()),
                songsById = songsById,
                genreBySongId = genreBySongId,
                otherCollections = emptyList(),
                plays = emptyList(),
                hasRecency = false,
                memberWeights = feedback.rejected,
                balance = tuning.balance,
                nowMs = nowMs,
            ).calibrated(songs)

        // Timbre: weighted centroid of seeds (+👍), rejected sound subtracted inside the fit.
        val timbreProfile = SimilarityFamilies.timbreProfile(
            tasteWeight.mapNotNull { (id, w) -> timbre[id]?.let { SimilarityFamilies.TimbreMember(it, w) } },
        )
        val negTimbreProfile = if (timbreProfile == null) null else SimilarityFamilies.timbreProfile(
            feedback.rejected.mapNotNull { (id, w) -> timbre[id]?.let { SimilarityFamilies.TimbreMember(it, w) } },
            minVectors = 1,
        )
        val timbreCal = timbreProfile?.let { pos ->
            SimilarityFamilies.timbreCalibrate(
                songs.asSequence().map { timbre[it.id] }.asIterable(),
                positive = pos, negative = negTimbreProfile, rejectionWeight = tuning.rejectionWeight,
            )
        }

        // 3. Familiarity (log-scaled), memoized primary-artist cap keys, per-artist play totals.
        var maxPlays = 0
        val capKeyByArtist = HashMap<String, String>()
        val artistPlays = HashMap<String, Int>()
        for (s in songs) {
            val n = playCount(s.id)
            maxPlays = max(maxPlays, n)
            val ak = PuzzleSimilarity.artistKey(s.artist)
            val cap = capKeyByArtist.getOrPut(ak) { RecNovelty.primaryArtistKey(s.artist) }
            if (n > 0) artistPlays.merge(cap, n, Int::plus)
        }
        val sig = ZoneSignals(
            tuning = tuning, playCount = playCount, maxPlays = maxPlays, feedback = feedback,
            lastPlayedMs = lastPlayedMs, nowMs = nowMs, artistFam = RecNovelty.ArtistFamiliarity.of(artistPlays),
        )

        // 4. Partition + score.
        val familiarPool = ArrayList<Cand>()
        val rediscoveryPool = ArrayList<Cand>()
        val fallbackPool = ArrayList<Cand>()

        class Pre(val idx: Int, val capKey: String, val pre: Double)
        var prescored = ArrayList<Pre>()

        for ((idx, song) in songs.withIndex()) {
            val id = song.id
            if (id in onCooldown) continue
            if (id in feedback.suppressed) continue
            val artist = PuzzleSimilarity.artistKey(song.artist)
            val cap = capKeyByArtist[artist] ?: artist

            val w = seedWeight[id]
            if (w != null) {
                familiarPool.add(Cand(id, cap, (w + sig.familiarity(id) * tuning.familiarityWeight) * sig.skipFactor(id)))
                continue
            }
            // Played recently OUTSIDE this app ⇒ not dormant ⇒ sits this queue out.
            val lp = lastPlayedMs[id]
            if (lp != null && nowMs - lp < windowMs) continue

            val genre = genreBySongId[id]
            val artistHit = taste.artistShare[artist] != null
            val genreHit = genre?.let { taste.genreShare[it] != null } ?: false
            val related = artistHit || genreHit || id in taste.coMemberIds
            if (!taste.isEmpty && !related) {
                fallbackPool.add(Cand(id, cap, sig.auxOnly(id, cap)))
                continue
            }
            prescored.add(Pre(idx, cap, (if (artistHit) 2 else 0) + (if (genreHit) 1 else 0) + sig.auxOnly(id, cap)))
        }

        // PASS 2: bounded expensive scoring over an ARTIST-DIVERSE shortlist.
        prescored.sortWith { a, b ->
            val c = b.pre.compareTo(a.pre)
            if (c != 0) c else songs[a.idx].id.compareTo(songs[b.idx].id)
        }
        val perArtistQuota = max(4, tuning.maxPerArtist * 3)
        val quota = HashMap<String, Int>()
        val shortlist = ArrayList<Pre>()
        for (c in prescored) {
            if (shortlist.size >= tuning.shortlistCap) break
            val n = quota[c.capKey] ?: 0
            if (n >= perArtistQuota) continue
            quota[c.capKey] = n + 1
            shortlist.add(c)
        }
        prescored = shortlist

        val auxBaseDen = sig.auxBaseDen
        for (c in prescored) {
            val song = songs[c.idx]
            val id = song.id
            val sim = if (taste.isEmpty) 1.0
            else Similarity.score(song, taste, genreBySongId[id], cloudRank = 0.0, recency = 0.0)
            val penalty = distaste?.let {
                tuning.rejectionWeight * Similarity.score(song, it, genreBySongId[id], cloudRank = 0.0, recency = 0.0)
            } ?: 0.0
            val net = max(0.0, sim - penalty)
            if (!(net > 0)) continue

            val aux = if (auxBaseDen > 0) sig.auxOnly(id, c.capKey) else 0.0
            var lifted = net * (1 + tuning.auxGain * aux)
            if (timbreProfile != null && timbreCal != null) {
                val fit = SimilarityFamilies.timbreFit(
                    timbre[id], timbreProfile, negTimbreProfile, tuning.rejectionWeight, timbreCal,
                )
                lifted *= 1 + tuning.timbreGain * fit
            }
            lifted *= sig.skipFactor(id)
            rediscoveryPool.add(Cand(id, c.capKey, lifted))
        }

        familiarPool.sortWith(byScore)
        rediscoveryPool.sortWith(byScore)
        fallbackPool.sortWith(byScore)
        // The last-resort pool stays bounded (shortlistCap invariant).
        while (fallbackPool.size > tuning.shortlistCap) fallbackPool.removeAt(fallbackPool.size - 1)

        // 5. Size the queue: maxPerArtist × distinct recent artists, clamped to [minSongs, maxSongs].
        val recentArtists = HashSet<String>()
        for (id in seedWeight.keys) {
            songsById[id]?.let { recentArtists.add(PuzzleSimilarity.artistKey(it.artist)) }
        }
        val target = min(tuning.maxSongs, max(tuning.minSongs, tuning.maxPerArtist * recentArtists.size))

        val artistKeyMemo = HashMap<String, String>()
        return interleave(
            familiar = familiarPool, rediscovery = rediscoveryPool, fallback = fallbackPool,
            target = target, tuning = tuning,
            identity = { identity(it, songsById, artistKeyMemo) },
            playable = { RecRecordingIdentity.resolvesToStreamableAudio(songsById[it]?.appleMusicId) },
        )
    }

    // ── In Da Zone, ranked ELSEWHERE (the cloud engine) ─────────────────────────────────

    /**
     * Shape a ranking this engine did NOT produce (cloud ids, best first) into a queue that obeys
     * every local rule: RESOLUTION → SUPPRESSION → COOLDOWN → pools + floor + cap. The server's
     * order is preserved within each pool. Empty in ⇒ empty out (caller keeps its local ranking).
     */
    fun shapeCloudRanking(
        songIds: List<String>,
        songs: List<IndexSong>,
        plays: List<Play> = emptyList(),
        lastPlayedMs: Map<String, Double> = emptyMap(),
        feedback: Feedback = Feedback(),
        nowMs: Double,
        tuning: Tuning = Tuning(),
    ): Queue {
        if (songIds.isEmpty() || songs.isEmpty()) return Queue()
        val songsById = HashMap<String, IndexSong>(songs.size * 2)
        for (s in songs) songsById.putIfAbsent(s.id, s)

        val windowMs = tuning.rediscoveryQuietDays * MS_PER_DAY
        val cooldownMs = tuning.cooldownHours * MS_PER_HOUR

        val onCooldown = HashSet<String>()
        val playedInWindow = HashSet<String>()
        for (p in plays) {
            val age = nowMs - p.playedAtMs
            if (age < cooldownMs) onCooldown.add(p.songId)
            if (age >= 0 && age <= windowMs) playedInWindow.add(p.songId)
        }

        val familiar = ArrayList<Cand>()
        val rediscovery = ArrayList<Cand>()
        val seen = HashSet<String>()
        val capKeyByArtist = HashMap<String, String>()

        for ((rank, id) in songIds.withIndex()) {
            val song = songsById[id] ?: continue
            if (!seen.add(id)) continue
            if (id in feedback.suppressed) continue
            val lastPlayed = lastPlayedMs[id]
            if (id in onCooldown) continue
            if (lastPlayed != null && nowMs - lastPlayed < cooldownMs) continue

            val ak = PuzzleSimilarity.artistKey(song.artist)
            val capKey = capKeyByArtist.getOrPut(ak) { RecNovelty.primaryArtistKey(song.artist) }
            val score = (songIds.size - rank).toDouble()
            val recentlyTouched = id in playedInWindow || (lastPlayed?.let { nowMs - it < windowMs } ?: false)
            if (recentlyTouched) familiar.add(Cand(id, capKey, score)) else rediscovery.add(Cand(id, capKey, score))
        }

        if (familiar.isEmpty() && rediscovery.isEmpty()) return Queue()
        val artistKeyMemo = HashMap<String, String>()
        return interleave(
            familiar = familiar, rediscovery = rediscovery, fallback = emptyList(),
            target = tuning.maxSongs, tuning = tuning,
            identity = { identity(it, songsById, artistKeyMemo) },
            playable = { RecRecordingIdentity.resolvesToStreamableAudio(songsById[it]?.appleMusicId) },
        )
    }

    /** Weighted tempo/key shape of a seed set. */
    fun musicalProfile(seedWeight: Map<String, Double>, songsById: Map<String, IndexSong>): SimilarityFamilies.MusicalProfile =
        SimilarityFamilies.musicalProfile(
            seedWeight.mapNotNull { (id, w) ->
                val s = songsById[id] ?: return@mapNotNull null
                if (s.bpm == null && s.camelot == null) null else SimilarityFamilies.MusicalMember(s.bpm, s.camelot, w)
            },
        )

    /**
     * Alternate the pools under ONE per-artist budget; the rediscovery floor is checked at every
     * slot (so it holds on every prefix); a thin pool degrades to the other, never a short queue.
     * Cross-pool "one recording, one row" collapse runs ahead of the walk (tiers: familiar 2,
     * rediscovery 1, fallback 0).
     */
    private fun interleave(
        familiar: List<Cand>,
        rediscovery: List<Cand>,
        fallback: List<Cand>,
        target: Int,
        tuning: Tuning,
        identity: (String) -> RecRecordingIdentity.Identity,
        playable: (String) -> Boolean,
    ): Queue {
        val pools = listOf(familiar to 2, rediscovery to 1, fallback to 0)
        val keep = RecRecordingIdentity.keepMask(
            pools.flatMap { (rows, tier) ->
                rows.map {
                    RecRecordingIdentity.Candidate(
                        id = it.id, identity = identity(it.id), tier = tier, score = it.score, playable = playable(it.id),
                    )
                }
            },
        )
        var cut = 0
        fun surviving(rows: List<Cand>): List<Cand> {
            val base = cut
            cut += rows.size
            return rows.filterIndexed { i, _ -> keep[base + i] }
        }
        val fam = surviving(familiar)
        val red = surviving(rediscovery)
        val fb = surviving(fallback)

        val perArtist = HashMap<String, Int>()
        var fi = 0
        var ri = 0
        var bi = 0
        val picks = ArrayList<Pick>()
        var rediscoveryCount = 0

        // Next candidate under the artist budget; consuming a rejected one is safe (budget only grows).
        fun take(pool: List<Cand>, cursor: Int): Pair<String?, Int> {
            var c = cursor
            while (c < pool.size) {
                val cand = pool[c]
                c += 1
                if ((perArtist[cand.capKey] ?: 0) < tuning.maxPerArtist) {
                    perArtist.merge(cand.capKey, 1, Int::plus)
                    return cand.id to c
                }
            }
            return null to c
        }

        while (picks.size < target) {
            val wantRediscovery = rediscoveryCount.toDouble() < tuning.rediscoveryFloor * (picks.size + 1)
            val first = if (wantRediscovery) Pool.REDISCOVERY else Pool.FAMILIAR
            val second = if (first == Pool.REDISCOVERY) Pool.FAMILIAR else Pool.REDISCOVERY
            var got = false
            for (pool in listOf(first, second)) {
                val (id, next) = if (pool == Pool.REDISCOVERY) take(red, ri).also { ri = it.second }
                else take(fam, fi).also { fi = it.second }
                if (id == null) continue
                picks.add(Pick(id, pool))
                if (pool == Pool.REDISCOVERY) rediscoveryCount += 1
                got = true
                break
            }
            if (!got) break
        }

        // Last resort: reach minSongs from dormant non-neighbours.
        while (picks.size < tuning.minSongs) {
            val (id, next) = take(fb, bi)
            bi = next
            if (id == null) break
            picks.add(Pick(id, Pool.REDISCOVERY))
            rediscoveryCount += 1
        }
        return Queue(picks)
    }

    // ── Collection suggestions ──────────────────────────────────────────────────────────

    /** Songs worth ADDING to a collection, best first. */
    fun suggestions(
        memberSongIds: List<String>,
        tracks: List<Track>,
        playCount: (String) -> Int,
        feedback: Feedback = Feedback(),
        limit: Int = 25,
        tuning: Tuning = Tuning(),
        versions: Map<String, RecVersionIdentity.Key>? = null,
        timbre: Map<String, Map<String, Double>> = emptyMap(),
        packed: Map<String, SimilarityFamilies.PackedVector>? = null,
    ): List<String> = rank(memberSongIds, tracks, playCount, feedback, limit, tuning, versions, timbre, packed).ids

    /** One ranking plus the facts the captions need; both faces read this one answer. */
    data class Ranking(
        val ids: List<String> = emptyList(),
        /** Which of [ids] came through the SOUND DOOR rather than the artist/genre gate. */
        val soundAdmitted: Set<String> = emptySet(),
        /** The crate's sound in words (`timbreAdjectives`), null without a live timbre profile. */
        val soundWords: String? = null,
    )

    private class Scored(
        val id: String,
        val capKey: String,
        val score: Double,
        val isIncumbent: Boolean,
        val rawGenre: String?,
        val isNewGenre: Boolean,
    )

    fun rank(
        memberSongIds: List<String>,
        tracks: List<Track>,
        playCount: (String) -> Int,
        feedback: Feedback = Feedback(),
        limit: Int = 25,
        tuning: Tuning = Tuning(),
        versions: Map<String, RecVersionIdentity.Key>? = null,
        timbre: Map<String, Map<String, Double>> = emptyMap(),
        packed: Map<String, SimilarityFamilies.PackedVector>? = null,
    ): Ranking {
        val members = memberSongIds.toSet()
        if (members.isEmpty() || tracks.isEmpty()) return Ranking()
        val trackById = HashMap<String, Track>(tracks.size * 2)
        for (t in tracks) trackById.putIfAbsent(t.songId, t)
        val membership = RecMembership(memberSongIds, appleMusicId = { trackById[it]?.appleMusicId })
        val versionKeys = versions ?: versionKeys(tracks)
        val ownedVersions = RecVersionIndex(memberSongIds.mapNotNull { versionKeys[it] })
        val ownedRecordings = memberSongIds.mapNotNull { RecRecordingIdentity.recordingKey(versionKeys[it]) }.toSet()

        // Incumbent set in CREDIT space, memoized per artist key.
        val creditKeysByArtist = HashMap<String, List<String>>()
        fun creditKeys(artistKey: String, artistName: String): List<String> =
            creditKeysByArtist.getOrPut(artistKey) { RecVersionIdentity.creditArtistKeys(artistName) }
        val memberCreditKeys = HashSet<String>()
        for (id in members) {
            val t = trackById[id] ?: continue
            memberCreditKeys.addAll(creditKeys(t.artistKey, t.artistName))
        }
        val incumbentByArtist = HashMap<String, Boolean>()
        fun isIncumbent(t: Track): Boolean = incumbentByArtist.getOrPut(t.artistKey) {
            memberCreditKeys.isNotEmpty() && creditKeys(t.artistKey, t.artistName).any { it in memberCreditKeys }
        }

        // Profile: members + 👍.
        val profileIds = HashSet(members)
        profileIds.addAll(feedback.accepted.keys.filter { trackById[it] != null })

        val artists = HashMap<String, Double>()
        val genres = HashMap<String, Double>()
        val years = ArrayList<Double>()
        val musicalMembers = ArrayList<SimilarityFamilies.MusicalMember>()
        val memberRawGenres = HashSet<String>()
        for (id in profileIds) {
            val t = trackById[id] ?: continue
            artists.merge(t.artistKey, 1.0, Double::plus)
            RecSoundAdmit.genreBucket(t.genreRaw)?.let { memberRawGenres.add(it) }
            if (!t.genre.isNullOrEmpty()) genres.merge(t.genre, 1.0, Double::plus)
            t.year?.let { years.add(it.toDouble()) }
            if (t.bpm != null || t.camelot != null) {
                musicalMembers.add(SimilarityFamilies.MusicalMember(t.bpm, t.camelot, 1.0))
            }
        }
        if (artists.isEmpty() && genres.isEmpty()) return Ranking()
        artists.values.maxOrNull()?.takeIf { it > 0 }?.let { m -> for (k in artists.keys.toList()) artists[k] = artists.getValue(k) / m }
        genres.values.maxOrNull()?.takeIf { it > 0 }?.let { m -> for (k in genres.keys.toList()) genres[k] = genres.getValue(k) / m }

        val era = SimilarityFamilies.eraWindow(years)
        val musical = SimilarityFamilies.musicalProfile(musicalMembers)

        val timbreProfile = SimilarityFamilies.timbreProfile(
            profileIds.mapNotNull { id -> timbre[id]?.let { SimilarityFamilies.TimbreMember(it, 1.0) } },
        )
        val negTimbreProfile = if (timbreProfile == null) null else SimilarityFamilies.timbreProfile(
            feedback.rejected.mapNotNull { (id, w) -> timbre[id]?.let { SimilarityFamilies.TimbreMember(it, w) } },
            minVectors = 1,
        )

        val terms = SimilarityFamilies.termWeights(
            tuning.balance ?: SimilarityFamilies.Balance.EVEN,
            hasGenre = genres.isNotEmpty(), hasYear = era != null, hasMusical = !musical.isEmpty,
            scaledTo = 1.0,
        )
        val musicalCal = SimilarityFamilies.calibrate(
            tracks.asSequence().map { SimilarityFamilies.BpmCamelot(it.bpm, it.camelot) }.asIterable(), musical,
        )
        val eraCal = era?.let { w ->
            SimilarityFamilies.eraCalibrate(tracks.asSequence().map { t -> t.year?.toDouble() }.asIterable(), w)
        }
        val timbreCal = timbreProfile?.let { pos ->
            SimilarityFamilies.timbreCalibrate(
                tracks.asSequence().map { timbre[it.songId] }.asIterable(),
                positive = pos, negative = negTimbreProfile, rejectionWeight = tuning.rejectionWeight,
            )
        }

        // The SOUND DOOR's preconditions, settled once per crate.
        val admitQuota = min(
            max(0, tuning.soundAdmitHardCap),
            max(0, floor(limit * tuning.soundAdmitMaxShare).toInt()),
        )
        val admitEligible = admitQuota > 0 &&
            SimilarityFamilies.timbreProfileAdmits(timbreProfile, profileIds.size)
        val packedCorpus: Map<String, SimilarityFamilies.PackedVector>? =
            if (admitEligible) (packed ?: SimilarityFamilies.pack(timbre)) else null
        val packedCentroid = if (admitEligible) timbreProfile?.let { SimilarityFamilies.pack(it.centroid) } else null
        val packedNegCentroid = if (admitEligible) negTimbreProfile?.let { SimilarityFamilies.pack(it.centroid) } else null
        val admitRadius = timbreProfile?.let { SimilarityFamilies.soundAdmitRadius(it.spread) } ?: 0.0
        val admitPool = ArrayList<RecSoundAdmit.Candidate>()

        // One pass: play ceiling, primary-artist cap key, per-artist play totals.
        var maxPlays = 0
        val capKeyByArtist = HashMap<String, String>()
        val artistPlays = HashMap<String, Int>()
        for (t in tracks) {
            val n = playCount(t.songId)
            maxPlays = max(maxPlays, n)
            val cap = capKeyByArtist.getOrPut(t.artistKey) { RecNovelty.primaryArtistKey(t.artistName) }
            if (n > 0) artistPlays.merge(cap, n, Int::plus)
        }
        val famDenom = log2(1.0 + max(maxPlays, 1))
        val artistFam = RecNovelty.ArtistFamiliarity.of(artistPlays)

        // The rejected shape, SATURATING (not max-normalised).
        val negArtists = HashMap<String, Double>()
        val negGenres = HashMap<String, Double>()
        for ((id, w) in feedback.rejected) {
            val t = trackById[id] ?: continue
            negArtists.merge(t.artistKey, w, Double::plus)
            if (!t.genre.isNullOrEmpty()) negGenres.merge(t.genre, w, Double::plus)
        }
        for (k in negArtists.keys.toList()) negArtists[k] = min(1.0, negArtists.getValue(k) / Tuning.REJECTION_SATURATION)
        for (k in negGenres.keys.toList()) negGenres[k] = min(1.0, negGenres.getValue(k) / Tuning.REJECTION_SATURATION)

        var scored = ArrayList<Scored>()
        for (t in tracks) {
            if (membership.contains(t.songId, appleMusicId = t.appleMusicId)) continue
            if (ownedRecordings.isNotEmpty()) {
                val rk = RecRecordingIdentity.recordingKey(versionKeys[t.songId])
                if (rk != null && rk in ownedRecordings) continue
            }
            if (!ownedVersions.isEmpty) {
                val v = versionKeys[t.songId]
                if (v != null && ownedVersions.supersedes(v)) continue
            }
            if (t.songId in feedback.suppressed) continue
            val a = artists[t.artistKey] ?: 0.0
            val g = t.genre?.let { genres[it] } ?: 0.0

            if (a <= 0 && g <= 0) {
                // THE SOUND DOOR.
                if (!admitEligible || isIncumbent(t)) continue
                val v = packedCorpus?.get(t.songId) ?: continue
                val centroid = packedCentroid ?: continue
                val d = SimilarityFamilies.timbreDistance(v, centroid) ?: continue
                if (!(d <= admitRadius)) continue
                // Every negative signal the scored path applies, applied here as a VETO.
                var negFit = 0.0
                if (negTimbreProfile != null && packedNegCentroid != null) {
                    val dn = SimilarityFamilies.timbreDistance(v, packedNegCentroid)
                    if (dn != null) {
                        negFit = if (dn <= negTimbreProfile.spread) 1.0
                        else exp(-(dn - negTimbreProfile.spread) / SimilarityFamilies.TIMBRE_DECAY)
                    }
                }
                negFit = max(negFit, max(negArtists[t.artistKey] ?: 0.0, t.genre?.let { negGenres[it] } ?: 0.0))
                var netFit = 1 - tuning.rejectionWeight * negFit
                feedback.skipPenalty[t.songId]?.let { netFit *= 1 - tuning.skipPenaltyWeight * min(1.0, max(0.0, it)) }
                if (netFit < RecSoundAdmit.MIN_NET_FIT) continue
                admitPool.add(
                    RecSoundAdmit.Candidate(
                        id = t.songId,
                        capKey = capKeyByArtist[t.artistKey] ?: t.artistKey,
                        decade = t.year?.let { (it / 10) * 10 },
                        rawGenre = RecSoundAdmit.genreBucket(t.genreRaw),
                        distance = d,
                    ),
                )
                RecSoundAdmit.trimIfNeeded(admitPool)
                continue
            }
            var score = terms.artist * a + terms.genre * g
            if (era != null && eraCal != null) {
                score += terms.year * SimilarityFamilies.eraFit(t.year?.toDouble(), era, eraCal)
            }
            if (terms.musical > 0) {
                score += terms.musical * SimilarityFamilies.musicalFit(t.bpm, t.camelot, musical, musicalCal)
            }
            val penalty = tuning.rejectionWeight *
                (terms.artist * (negArtists[t.artistKey] ?: 0.0) + terms.genre * (t.genre?.let { negGenres[it] } ?: 0.0))
            val sim = max(0.0, score - penalty)
            if (!(sim > 0)) continue
            val capKey = capKeyByArtist[t.artistKey] ?: t.artistKey
            val n = playCount(t.songId)
            val fam = if (n > 0 && famDenom > 0) log2(1.0 + n) / famDenom else 0.0
            val aux = RecNovelty.aux(
                novelty = artistFam.novelty(capKey), familiarity = fam,
                noveltyWeight = tuning.suggestionNoveltyWeight,
                familiarityWeight = tuning.suggestionFamiliarityWeight,
                isLive = artistFam.isLive,
            )
            var net = sim * (1 + tuning.suggestionAuxGain * aux)
            if (timbreProfile != null && timbreCal != null) {
                val fit = SimilarityFamilies.timbreFit(
                    timbre[t.songId], timbreProfile, negTimbreProfile, tuning.rejectionWeight, timbreCal,
                )
                net *= 1 + tuning.timbreGain * fit
            }
            feedback.skipPenalty[t.songId]?.let { net *= 1 - tuning.skipPenaltyWeight * min(1.0, max(0.0, it)) }
            if (!(net > 0)) continue
            val rawGenre = RecSoundAdmit.genreBucket(t.genreRaw)
            scored.add(
                Scored(t.songId, capKey, net, isIncumbent(t), rawGenre, rawGenre?.let { it !in memberRawGenres } ?: false),
            )
        }
        scored.sortWith { x, y ->
            val c = y.score.compareTo(x.score)
            if (c != 0) c else x.id.compareTo(y.id)
        }

        // ONE RECORDING, ONE ROW: one mask over BOTH pools (scored tier 1, admitted tier 0).
        val scoredCount = scored.size
        fun identityCandidate(id: String, tier: Int, score: Double): RecRecordingIdentity.Candidate {
            val am = trackById[id]?.appleMusicId
            return RecRecordingIdentity.Candidate(
                id = id,
                identity = RecRecordingIdentity.identity(id, am, versionKeys[id], trackById[id]?.lengthMs),
                tier = tier,
                score = score,
                playable = RecRecordingIdentity.resolvesToStreamableAudio(am),
            )
        }
        val keep = RecRecordingIdentity.keepMask(
            scored.map { identityCandidate(it.id, 1, it.score) } +
                admitPool.map { identityCandidate(it.id, 0, -it.distance) },
        )
        scored = ArrayList(scored.filterIndexed { i, _ -> keep[i] })
        val keptAdmit = admitPool.filterIndexed { i, _ -> keep[scoredCount + i] }

        val admittedRows = RecSoundAdmit.select(keptAdmit, admitQuota).map { c ->
            RecComposition.Row(id = c.id, capKey = c.capKey, isIncumbent = false, rawGenre = c.rawGenre, isNewGenre = true)
        }
        val minRawGenres = max(0, ceil(limit * tuning.suggestionMinRawGenreShare).toInt())
        val maxSwaps = max(0, floor(limit * tuning.suggestionDiversityMaxSwapShare).toInt())
        val ids = RecComposition.compose(
            scored.map { RecComposition.Row(it.id, it.capKey, it.isIncumbent, it.rawGenre, it.isNewGenre) },
            limit = limit,
            maxPerArtist = tuning.maxPerArtist,
            incumbentMaxShare = tuning.suggestionIncumbentMaxShare,
            soundAdmit = if (admittedRows.isEmpty()) null else RecComposition.SoundAdmit(
                rows = admittedRows, maxShare = tuning.soundAdmitMaxShare, hardCap = tuning.soundAdmitHardCap,
            ),
            diversity = if (minRawGenres > 0 && maxSwaps > 0) RecComposition.Diversity(
                minDistinctRawGenres = minRawGenres, maxSwaps = maxSwaps, searchDepth = max(limit * 8, 50),
            ) else null,
        )
        val emitted = ids.toSet()
        return Ranking(
            ids = ids,
            soundAdmitted = admittedRows.map { it.id }.toSet().intersect(emitted),
            soundWords = timbreProfile?.let { SimilarityFamilies.timbreAdjectives(it.centroid).joinToString(", ") },
        )
    }

    // ── Explained suggestions ───────────────────────────────────────────────────────────

    data class ExplainedRow(val songId: String, val why: String)

    data class ExplainedRanking(
        val rows: List<ExplainedRow> = emptyList(),
        val soundAdmitted: Set<String> = emptySet(),
    )

    fun suggestionsExplained(
        memberSongIds: List<String>,
        tracks: List<Track>,
        playCount: (String) -> Int,
        feedback: Feedback = Feedback(),
        limit: Int = 25,
        tuning: Tuning = Tuning(),
        versions: Map<String, RecVersionIdentity.Key>? = null,
        timbre: Map<String, Map<String, Double>> = emptyMap(),
        packed: Map<String, SimilarityFamilies.PackedVector>? = null,
    ): List<ExplainedRow> =
        explainedSuggestions(memberSongIds, tracks, playCount, feedback, limit, tuning, versions, timbre, packed).rows

    /**
     * The explained ranking PLUS which rows came through the sound door. Two faces of ONE ranking
     * (the badge set comes from [rank], which also produced the ids).
     */
    fun explainedSuggestions(
        memberSongIds: List<String>,
        tracks: List<Track>,
        playCount: (String) -> Int,
        feedback: Feedback = Feedback(),
        limit: Int = 25,
        tuning: Tuning = Tuning(),
        versions: Map<String, RecVersionIdentity.Key>? = null,
        timbre: Map<String, Map<String, Double>> = emptyMap(),
        packed: Map<String, SimilarityFamilies.PackedVector>? = null,
    ): ExplainedRanking {
        val ranking = rank(memberSongIds, tracks, playCount, feedback, limit, tuning, versions, timbre, packed)
        val ids = ranking.ids
        if (ids.isEmpty()) return ExplainedRanking()
        val trackById = HashMap<String, Track>(tracks.size * 2)
        for (t in tracks) trackById.putIfAbsent(t.songId, t)
        val capKeyByArtist = HashMap<String, String>()
        val artistPlays = HashMap<String, Int>()
        for (t in tracks) {
            val n = playCount(t.songId)
            val cap = capKeyByArtist.getOrPut(t.artistKey) { RecNovelty.primaryArtistKey(t.artistName) }
            if (n > 0) artistPlays.merge(cap, n, Int::plus)
        }
        val artistFam = RecNovelty.ArtistFamiliarity.of(artistPlays)
        val members = memberSongIds.toSet()
        val memberGenres = memberSongIds.mapNotNull { trackById[it]?.genre }.toSet()
        val creditCache = HashMap<String, List<String>>()
        fun creditKeys(t: Track): List<String> =
            creditCache.getOrPut(t.artistKey) { RecVersionIdentity.creditArtistKeys(t.artistName) }
        val memberCreditKeys = HashSet<String>()
        for (id in members) {
            val t = trackById[id] ?: continue
            memberCreditKeys.addAll(creditKeys(t))
        }
        fun isIncumbent(t: Track) = memberCreditKeys.isNotEmpty() && creditKeys(t).any { it in memberCreditKeys }

        val era = SimilarityFamilies.eraWindow(memberSongIds.mapNotNull { trackById[it]?.year?.toDouble() })
        val timbreProfile = SimilarityFamilies.timbreProfile(
            memberSongIds.mapNotNull { id -> timbre[id]?.let { SimilarityFamilies.TimbreMember(it, 1.0) } },
        )
        val timbreWords = timbreProfile?.let { SimilarityFamilies.timbreAdjectives(it.centroid).joinToString(", ") }

        val rows = ids.map { id ->
            // The sound door speaks first, and only for rows it admitted.
            if (id in ranking.soundAdmitted) {
                val words = ranking.soundWords
                return@map ExplainedRow(
                    id, if (!words.isNullOrEmpty()) "Sounds like this crate: $words" else "Sounds like this crate",
                )
            }
            val t = trackById[id] ?: return@map ExplainedRow(id, "Fits this collection")
            val cap = capKeyByArtist[t.artistKey] ?: t.artistKey
            val incumbent = isIncumbent(t)
            val novelWhy = artistFam.reason(cap)
            if (novelWhy != null && !incumbent) return@map ExplainedRow(id, novelWhy)
            if (incumbent) return@map ExplainedRow(id, "An artist already in here")
            // Timbre ABOVE genre in precedence, only on observed vectors with a real fit.
            if (timbreProfile != null && !timbreWords.isNullOrEmpty()) {
                val v = timbre[id]
                val fit = v?.let { SimilarityFamilies.timbreFit(it, timbreProfile) }
                if (fit != null && fit >= 0.8) return@map ExplainedRow(id, "Sounds like this crate: $timbreWords")
            }
            if (t.genre != null && t.genre in memberGenres) return@map ExplainedRow(id, "Mostly ${t.genre}, like this collection")
            if (era != null && t.year != null && era.contains(t.year.toDouble())) {
                return@map ExplainedRow(id, "From this collection's ${era.lo.toInt()}–${era.hi.toInt()} era")
            }
            if (memberCreditKeys.isNotEmpty() && !incumbent) return@map ExplainedRow(id, "New artist for this crate")
            ExplainedRow(id, "Fits this collection")
        }
        return ExplainedRanking(rows, ranking.soundAdmitted)
    }

    private fun log2(x: Double) = ln(x) / ln(2.0)
}
