package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.recs.ZoneEngine.Feedback
import com.levi.pocketdj.data.recs.ZoneEngine.Play
import com.levi.pocketdj.data.recs.ZoneEngine.Pool
import com.levi.pocketdj.data.recs.ZoneEngine.Track
import com.levi.pocketdj.data.recs.ZoneEngine.Tuning
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ZoneEngineTest {

    private val now = 1_800_000_000_000.0
    private val day = 86_400_000.0
    private val hour = 3_600_000.0

    // 12 artists x 6 songs; artist i has genre g(i % 3). ids "a03s2" are readable and unique.
    private fun id(a: Int, s: Int) = "a${a.toString().padStart(2, '0')}s$s"
    private val songs: List<IndexSong> = (0 until 12).flatMap { a ->
        (0 until 6).map { s -> IndexSong(id = id(a, s), artist = "Artist $a", name = "Title $a-$s", year = 1990 + a) }
    }
    private val genreOf = (0 until 12).flatMap { a -> (0 until 6).map { s -> id(a, s) to "g${a % 3}" } }.toMap()
    private val noPlays: (String) -> Int = { 0 }

    private fun zone(
        plays: List<Play>,
        feedback: Feedback = Feedback(),
        lastPlayed: Map<String, Double> = emptyMap(),
        catalog: List<IndexSong> = songs,
        tuning: Tuning = Tuning(),
        playCount: (String) -> Int = noPlays,
    ) = ZoneEngine.inDaZone(
        songs = catalog, genreBySongId = genreOf, plays = plays, playCount = playCount,
        lastPlayedMs = lastPlayed, feedback = feedback, nowMs = now, tuning = tuning,
    )

    private fun play(id: String, daysAgo: Double) = Play(id, now - daysAgo * day)

    private val recentPlays = listOf(
        play(id(0, 0), 1.0), play(id(0, 1), 10.0), play(id(1, 0), 59.0), play(id(2, 0), 61.0),
    )

    // ── pools ───────────────────────────────────────────────────────────────────────────

    @Test fun poolsAreExactlyComplementaryOnTheQuietWindow() {
        val q = zone(recentPlays)
        val familiar = q.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }.toSet()
        val rediscovery = q.picks.filter { it.pool == Pool.REDISCOVERY }.map { it.songId }.toSet()
        // played inside 60 days => familiar; the 61-day play is OUTSIDE the window => never familiar
        assertTrue(familiar.isNotEmpty())
        assertTrue(familiar.all { it in setOf(id(0, 0), id(0, 1), id(1, 0)) })
        assertFalse(id(2, 0) in familiar)
        assertTrue(familiar.intersect(rediscovery).isEmpty())
        assertEquals(q.count, q.songIds.toSet().size)
        // and a song played inside the window is never offered as a rediscovery
        assertFalse(rediscovery.any { it in setOf(id(0, 0), id(0, 1), id(1, 0)) })
    }

    @Test fun quietDaysTuningMovesTheBoundaryForBothPoolsTogether() {
        val q10 = zone(recentPlays, tuning = Tuning(rediscoveryQuietDays = 5.0))
        val fam = q10.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }.toSet()
        assertEquals(setOf(id(0, 0)), fam)
        // the 10-day-old play is now dormant ⇒ eligible as a rediscovery instead
        assertTrue(q10.picks.any { it.songId == id(0, 1) && it.pool == Pool.REDISCOVERY })
    }

    @Test fun rediscoveryShareHoldsTheFloorOnEveryPrefix() {
        val q = zone(recentPlays)
        assertTrue(q.rediscoveryShare >= 0.5)
        var red = 0
        q.picks.forEachIndexed { i, p ->
            if (p.pool == Pool.REDISCOVERY) red++
            assertTrue("prefix ${i + 1}: $red rediscoveries", red * 2 >= i)
        }
        assertFalse(q.degradesToFamiliar)
    }

    @Test fun floorYieldsOnlyWhenTheLibraryCannotSupplyRediscoveries() {
        val two = songs.filter { it.artist == "Artist 0" || it.artist == "Artist 1" }
        val plays = two.mapIndexed { i, s -> play(s.id, 1.0 + i) }
        val q = zone(plays, catalog = two)
        assertEquals(6, q.count) // cap 3/artist x 2 artists
        assertEquals(0, q.count(Pool.REDISCOVERY))
        assertTrue(q.degradesToFamiliar)
    }

    @Test fun neverMoreThanThreePerArtistAcrossBothPools() {
        val q = zone(recentPlays)
        val perArtist = q.songIds.groupBy { songs.first { s -> s.id == it }.artist }.mapValues { it.value.size }
        assertTrue(perArtist.values.all { it <= 3 })
        assertEquals(30, q.count) // minSongs reachable with 12 artists x 3
    }

    @Test fun cooldownExcludesJustPlayed() {
        val q = zone(listOf(play(id(0, 0), 0.0), Play(id(0, 1), now - 5 * hour), play(id(0, 2), 2.0)))
        assertFalse(id(0, 0) in q.songIds)
        assertFalse(id(0, 1) in q.songIds)
        assertTrue(id(0, 2) in q.songIds)
        // 7 hours ago is past the 6 h cooldown
        val q2 = zone(listOf(Play(id(0, 1), now - 7 * hour)))
        assertTrue(id(0, 1) in q2.songIds)
    }

    @Test fun futureDatedPlaysClampToNowAndAreOnCooldown() {
        val future = Play(id(3, 0), now + 5 * hour)
        val q = zone(listOf(future, play(id(5, 0), 1.0)))
        assertFalse(id(3, 0) in q.songIds) // cooldown (negative age < cooldown)
        // ...but the activity is NOT dropped: artist 3's other songs rank as neighbours of the taste
        val firstRed = q.picks.first { it.pool == Pool.REDISCOVERY }.songId
        assertTrue(firstRed.startsWith("a03") || firstRed.startsWith("a05") ||
            genreOf[firstRed] == genreOf[id(3, 0)] || genreOf[firstRed] == genreOf[id(5, 0)])
    }

    @Test fun coldStartStillReturnsAQueueFromAuxSignals() {
        val q = zone(emptyList(), playCount = { if (it == id(4, 0)) 50 else 1 }, lastPlayed = emptyMap())
        assertTrue(q.count >= 30)
        assertEquals(0, q.count(Pool.FAMILIAR))
    }

    @Test fun fallbackPoolFillsANarrowProfileToMinSongs() {
        // one artist on repeat in a genre nothing else shares ⇒ the gate admits ~nothing
        val odd = songs
        val genres = odd.associate { it.id to (if (it.artist == "Artist 0") "solo" else "other") }
        val q = ZoneEngine.inDaZone(
            songs = odd, genreBySongId = genres,
            plays = listOf(play(id(0, 0), 1.0)), playCount = noPlays, nowMs = now,
        )
        assertTrue(q.count >= 30)
    }

    // ── feedback ────────────────────────────────────────────────────────────────────────

    @Test fun acceptedJoinsTasteProfileButNeverTheFamiliarPool() {
        val fb = Feedback(accepted = mapOf(id(7, 0) to 1.0))
        val q = zone(emptyList(), feedback = fb)
        assertEquals(0, q.count(Pool.FAMILIAR))
        // the profile is non-empty: artist 7's siblings lead the rediscovery pool
        assertTrue(q.picks.first().songId.startsWith("a07"))
        // the unheard 👍'd song itself belongs to REDISCOVERY
        val pick = q.picks.firstOrNull { it.songId == id(7, 0) }
        assertTrue(pick == null || pick.pool == Pool.REDISCOVERY)
    }

    @Test fun acceptedDoesNotChangeSeedPartitioning() {
        val base = zone(recentPlays)
        val withAccept = zone(recentPlays, Feedback(accepted = mapOf(id(9, 0) to 1.0)))
        val f0 = base.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }.toSet()
        val f1 = withAccept.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }.toSet()
        assertEquals(f0, f1)
    }

    @Test fun suppressedIsTheOnlyThingThatRemovesARow() {
        val base = zone(recentPlays)
        val victim = base.picks.first { it.pool == Pool.REDISCOVERY }.songId
        val q = zone(recentPlays, Feedback(suppressed = setOf(victim)))
        assertFalse(victim in q.songIds)
        // a GLOBAL rejection of the same id only reshapes the ranking — it is not a filter
        val q2 = zone(recentPlays, Feedback(rejected = mapOf(victim to 1.0)))
        assertTrue(q2.count >= 30)
    }

    @Test fun rejectedShapeIsSubtractedFromRelatedCandidates() {
        val plays = listOf(play(id(0, 0), 1.0), play(id(1, 0), 1.0), play(id(2, 0), 1.0))
        val base = zone(plays).songIds
        val rej = zone(plays, Feedback(rejected = mapOf(id(0, 3) to 3.0))).songIds
        fun rankOf(list: List<String>, prefix: String) =
            list.indexOfFirst { it.startsWith(prefix) && !it.endsWith("s0") }.let { if (it < 0) Int.MAX_VALUE else it }
        // artist 0's remaining songs are demoted relative to the unrejected ranking
        assertTrue(rankOf(rej, "a00") >= rankOf(base, "a00"))
        assertNotEquals(base, rej)
    }

    @Test fun skipPenaltiesApplyGloballyAndOnlyDemote() {
        val plays = listOf(play(id(0, 0), 1.0), play(id(1, 0), 1.0), play(id(2, 0), 1.0))
        val base = zone(plays)
        val skipped = zone(plays, Feedback(skipPenalty = mapOf(id(0, 0) to 1.0)))
        val fBase = base.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }
        val fSkip = skipped.picks.filter { it.pool == Pool.FAMILIAR }.map { it.songId }
        assertEquals(fBase.toSet(), fSkip.toSet()) // never removed
        assertEquals(listOf(id(0, 0), id(1, 0), id(2, 0)), fBase) // equal heat: ties break on id
        assertEquals(listOf(id(1, 0), id(2, 0), id(0, 0)), fSkip) // demoted below its equally-hot siblings
    }

    @Test fun skipPenaltiesFormulaIsTheDampenedRatio() {
        val p = Feedback.skipPenalties(plays = mapOf("a" to 1, "b" to 20, "c" to 10), skips = mapOf("a" to 1, "b" to 1, "c" to 10, "z" to 0))
        assertEquals(0.25, p["a"]!!, 1e-12)
        assertEquals(1.0 / 23, p["b"]!!, 1e-12)
        assertEquals(10.0 / 13, p["c"]!!, 1e-12)
        assertFalse("z" in p) // zero skips: no entry
        // a plays map that lags the skip count never inflates past s/(s+k)
        assertEquals(2.0 / 5, Feedback.skipPenalties(emptyMap(), mapOf("q" to 2))["q"]!!, 1e-12)
    }

    @Test fun emptyFeedbackIsByteIdentical() {
        assertTrue(Feedback().isEmpty)
        assertEquals(zone(recentPlays), zone(recentPlays, Feedback()))
    }

    // ── cloud shaping ───────────────────────────────────────────────────────────────────

    @Test fun cloudShapingDropsUnresolvableCappedCooledAndSuppressedIds() {
        val ids = listOf("ghost1") + (0 until 6).map { id(0, it) } + listOf(id(1, 0), id(1, 0), id(2, 0), id(3, 0), "ghost2")
        val q = ZoneEngine.shapeCloudRanking(
            songIds = ids, songs = songs,
            plays = listOf(Play(id(2, 0), now - hour)), // cooldown
            feedback = Feedback(suppressed = setOf(id(3, 0))),
            nowMs = now,
        )
        val out = q.songIds
        assertFalse("ghost1" in out || "ghost2" in out)
        assertFalse(id(2, 0) in out)
        assertFalse(id(3, 0) in out)
        assertEquals(1, out.count { it == id(1, 0) }) // duplicates collapse
        assertEquals(3, out.count { it.startsWith("a00") }) // ≤ 3 per artist, server order kept
        assertEquals(listOf(id(0, 0), id(0, 1), id(0, 2)), out.filter { it.startsWith("a00") })
    }

    @Test fun cloudShapingLabelsPoolsByTheQuietWindowAndKeepsServerOrder() {
        val ids = listOf(id(0, 0), id(1, 0), id(2, 0), id(3, 0))
        val q = ZoneEngine.shapeCloudRanking(
            songIds = ids, songs = songs,
            plays = listOf(play(id(0, 0), 3.0)),
            lastPlayedMs = mapOf(id(1, 0) to now - 20 * day, id(2, 0) to now - 400 * day),
            nowMs = now,
        )
        val pool = q.picks.associate { it.songId to it.pool }
        assertEquals(Pool.FAMILIAR, pool[id(0, 0)]) // play event in window
        assertEquals(Pool.FAMILIAR, pool[id(1, 0)]) // Apple last-played in window
        assertEquals(Pool.REDISCOVERY, pool[id(2, 0)])
        assertEquals(Pool.REDISCOVERY, pool[id(3, 0)])
        assertEquals(listOf(id(2, 0), id(3, 0)), q.picks.filter { it.pool == Pool.REDISCOVERY }.map { it.songId })
        assertTrue(q.picks.first().pool == Pool.REDISCOVERY) // floor: rediscovery leads
    }

    @Test fun cloudShapingEmptyInEmptyOut() {
        assertTrue(ZoneEngine.shapeCloudRanking(emptyList(), songs, nowMs = now).isEmpty)
        assertTrue(ZoneEngine.shapeCloudRanking(listOf("ghost"), songs, nowMs = now).isEmpty)
    }

    @Test fun cloudShapingCollapsesOneRecordingAcrossIds() {
        // _clean / _explicit variants of one base id are one recording
        val v = listOf(
            IndexSong(id = "sng_0000000000a1", artist = "X", name = "Same"),
            IndexSong(id = "sng_0000000000a1_clean", artist = "X", name = "Same"),
            IndexSong(id = "sng_0000000000b2", artist = "Y", name = "Other"),
        )
        val q = ZoneEngine.shapeCloudRanking(v.map { it.id }, v, nowMs = now)
        assertEquals(2, q.count)
    }

    // ── tuning defaults are the shipped ones ────────────────────────────────────────────

    @Test fun tuningDefaultsAreTheShippedValues() {
        val t = Tuning()
        assertEquals(7.0, t.halfLifeDays, 0.0); assertEquals(60.0, t.rediscoveryQuietDays, 0.0)
        assertEquals(6.0, t.cooldownHours, 0.0); assertEquals(3, t.maxPerArtist)
        assertEquals(30, t.minSongs); assertEquals(90, t.maxSongs); assertEquals(0.5, t.rediscoveryFloor, 0.0)
        assertEquals(0.40, t.suggestionAuxGain, 0.0); assertEquals(0.35, t.timbreGain, 0.0)
        assertEquals(0.12, t.soundAdmitMaxShare, 0.0); assertEquals(3, t.soundAdmitHardCap)
        assertEquals(3.0, Tuning.REJECTION_SATURATION, 0.0)
        assertEquals(SimilarityFamilies.Balance.EVEN, t.balance)
    }

    // ── suggestions ─────────────────────────────────────────────────────────────────────

    private fun trk(
        id: String, artist: String, genre: String? = "soul", year: Int? = 1990, title: String? = null,
        am: String? = null, len: Int? = null, raw: String? = genre,
    ) = Track(
        songId = id, artistKey = artist.lowercase(), artistName = artist, genre = genre, year = year,
        appleMusicId = am, title = title ?: "T $id", lengthMs = len, genreRaw = raw,
    )

    private fun ids(r: List<String>) = r

    @Test fun suggestionsExcludeEverythingAlreadyInTheCollectionUnderAnyIdentity() {
        val tracks = listOf(
            trk("sng_0000000000a1", "Mem", title = "Alpha"),
            trk("sng_0000000000a1_explicit", "Mem", title = "Alpha"), // edition id of a member
            trk("sng_0000000000c3", "Mem", title = "Gamma", am = "1234567"), // resolves to the amrec member
            trk("sng_0000000000d4", "Mem", title = "Delta"), // genuinely new
        )
        val s = ZoneEngine.suggestions(listOf("sng_0000000000a1", "amrec_1234567"), tracks, noPlays)
        assertEquals(listOf("sng_0000000000d4"), s)
    }

    @Test fun suggestionsExcludeOtherVersionsAndSecondIdsOfAMemberButNotLiveCuts() {
        val tracks = listOf(
            trk("m1", "Zed", title = "Echo"),
            trk("v1", "Zed", title = "Echo (Deluxe Edition)"),
            trk("v2", "Zed", title = "Echo"), // same recording, second catalog row
            trk("v3", "Zed", title = "Echo (Remix)"),
            trk("live", "Zed", title = "Echo (Live)", len = 400_000),
            trk("fresh", "Zed", title = "Brand New"),
        )
        val s = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays).toSet()
        assertEquals(setOf("live", "fresh"), s)
    }

    @Test fun admissionGateIsArtistOrGenre() {
        val tracks = listOf(
            trk("m1", "Mem", genre = "soul"), trk("m2", "Mem", genre = "soul"),
            trk("sameGenre", "Other1", genre = "soul"),
            trk("sameArtist", "Mem", genre = "rock"),
            trk("neither", "Other2", genre = "jazz"),
            trk("noGenre", "Other3", genre = null),
        )
        val s = ZoneEngine.suggestions(listOf("m1", "m2"), tracks, noPlays).toSet()
        assertEquals(setOf("sameGenre", "sameArtist"), s)
    }

    @Test fun suggestionsCapPerPrimaryArtistAndKeepTheIncumbentShareAtHalf() {
        val tracks = mutableListOf(trk("m1", "Mem"), trk("m2", "Mem"))
        tracks += (0 until 10).map { trk("inc$it", "Mem") } // incumbent artist, 10 candidates
        tracks += (0 until 4).map { trk("new$it", "New$it") }
        val s = ZoneEngine.suggestions(listOf("m1", "m2"), tracks, noPlays, limit = 6)
        assertEquals(6, s.size)
        assertTrue(s.count { it.startsWith("inc") } <= 3) // ≤3 per artist AND ≤ 50% of 6
        assertEquals(3, s.count { it.startsWith("new") })
    }

    @Test fun collabCreditsCountAsTheIncumbentArtist() {
        val tracks = listOf(
            trk("m1", "Terrace Martin, Robert Glasper & Kamasi Washington"),
            trk("c1", "Robert Glasper"), trk("c2", "Somebody Else"),
        )
        val ex = ZoneEngine.suggestionsExplained(listOf("m1"), tracks, noPlays).associate { it.songId to it.why }
        assertEquals("An artist already in here", ex["c1"])
        assertTrue(ex["c2"]!!.isNotEmpty() && ex["c2"] != "An artist already in here")
    }

    @Test fun rejectionTeachesTheTileByShapeNotJustByRow() {
        val tracks = listOf(trk("m1", "Mem"), trk("m2", "Mem")) +
            (0 until 3).map { trk("b$it", "Bee") } + (0 until 3).map { trk("c$it", "Cee") } +
            listOf(trk("rejectedBee", "Bee"))
        fun firstPos(list: List<String>, p: String) = list.indexOfFirst { it.startsWith(p) }
        val base = ZoneEngine.suggestions(listOf("m1", "m2"), tracks, noPlays)
        val rej = ZoneEngine.suggestions(
            listOf("m1", "m2"), tracks, noPlays, Feedback(rejected = mapOf("rejectedBee" to 3.0)),
        )
        assertTrue(firstPos(base, "b") < firstPos(base, "c")) // id tiebreak: Bee first
        assertTrue(firstPos(rej, "c") < firstPos(rej, "b")) // Bee demoted by the rejected shape
        assertTrue(rej.any { it.startsWith("b") }) // reorders, never censors
    }

    @Test fun acceptedIdsJoinTheCollectionProfile() {
        val tracks = listOf(trk("m1", "Mem", genre = "soul"), trk("liked", "Liked", genre = "rock", year = 1991),
            trk("candA", "Liked", genre = "rock"), trk("candB", "Else", genre = "jazz"))
        val without = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays)
        val with = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays, Feedback(accepted = mapOf("liked" to 1.0)))
        assertFalse("candA" in without)
        assertTrue("candA" in with)
    }

    @Test fun suppressedRowsLeaveTheTile() {
        val tracks = listOf(trk("m1", "Mem"), trk("x", "A"), trk("y", "B"))
        val s = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays, Feedback(suppressed = setOf("x")))
        assertEquals(listOf("y"), s)
    }

    @Test fun skipPenaltyDemotesButNeverRemoves() {
        val tracks = listOf(trk("m1", "Mem"), trk("a", "A"), trk("b", "B"))
        val base = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays)
        val sk = ZoneEngine.suggestions(listOf("m1"), tracks, noPlays, Feedback(skipPenalty = mapOf("a" to 1.0)))
        assertEquals(listOf("a", "b"), base)
        assertEquals(listOf("b", "a"), sk)
    }

    @Test fun emptyMembersOrCatalogGivesEmptyRanking() {
        assertEquals(ZoneEngine.Ranking(), ZoneEngine.rank(emptyList(), listOf(trk("a", "A")), noPlays))
        assertEquals(ZoneEngine.Ranking(), ZoneEngine.rank(listOf("m"), emptyList(), noPlays))
        assertEquals(ZoneEngine.Ranking(), ZoneEngine.rank(listOf("unknown"), listOf(trk("a", "A")), noPlays))
    }

    // ── explained captions ──────────────────────────────────────────────────────────────

    private fun vec(v: Double) = SimilarityFamilies.TIMBRE_AXES.associateWith { v }

    @Test fun explainedRowsAlwaysCarryANonEmptyWhyAndAgreeWithTheIdList() {
        val tracks = listOf(trk("m1", "Mem", year = 1990), trk("m2", "Mem", year = 1992)) +
            (0 until 6).map { trk("n$it", "Artist$it", year = 1991) } +
            listOf(trk("era", "EraGuy", genre = "rock", year = 1991), trk("x", "Mem", genre = "rock", year = 2020))
        val ids = ZoneEngine.suggestions(listOf("m1", "m2"), tracks, noPlays)
        val ex = ZoneEngine.suggestionsExplained(listOf("m1", "m2"), tracks, noPlays)
        assertEquals(ids, ex.map { it.songId })
        assertTrue(ex.all { it.why.isNotBlank() })
        val by = ex.associate { it.songId to it.why }
        assertEquals("Mostly soul, like this collection", by["n0"])
        assertEquals("An artist already in here", by["x"])
    }

    @Test fun noveltyCaptionLeadsWhenThePlayDataIsLive() {
        val tracks = listOf(trk("m1", "Mem"), trk("n1", "Fresh"), trk("n2", "Worn"))
        val plays = mapOf("m1" to 40, "n2" to 30, "n1" to 0)
        val ex = ZoneEngine.suggestionsExplained(listOf("m1"), tracks, { plays[it] ?: 0 }).associate { it.songId to it.why }
        assertEquals("An artist you've never played", ex["n1"])
    }

    @Test fun timbreCaptionOutranksGenreAndNewArtist() {
        val members = (0 until 4).map { trk("m$it", "Mem") }
        val cands = (0 until 3).map { trk("c$it", "Cand$it") }
        val timbre = (members + cands).associate { it.songId to vec(0.9) }
        val ex = ZoneEngine.suggestionsExplained(members.map { it.songId }, members + cands, noPlays, timbre = timbre)
        assertTrue(ex.isNotEmpty())
        for (row in ex) assertTrue(row.why, row.why.startsWith("Sounds like this crate: "))
        // no vectors on the candidates ⇒ the caption falls back to the genre claim
        val ex2 = ZoneEngine.suggestionsExplained(
            members.map { it.songId }, members + cands, noPlays, timbre = members.associate { it.songId to vec(0.9) },
        )
        for (row in ex2) assertEquals("Mostly soul, like this collection", row.why)
    }

    // ── the SOUND DOOR ──────────────────────────────────────────────────────────────────

    private fun soundCrate(): Pair<List<Track>, Map<String, Map<String, Double>>> {
        val members = (0 until 8).map { trk("m$it", "Mem", genre = "soul", year = 1980, raw = "Soul") }
        // door candidates: share NEITHER artist NOR genre; distinct artist/decade/raw genre
        val door = listOf(
            trk("d0", "Dart0", genre = "jazz", year = 1971, raw = "Bebop"),
            trk("d1", "Dart1", genre = "rock", year = 1984, raw = "Punk"),
            trk("d2", "Dart2", genre = "classical", year = 1995, raw = "Baroque"),
            trk("d3", "Dart3", genre = "country", year = 2003, raw = "Outlaw"),
            trk("d4", "Dart4", genre = "reggae", year = 2011, raw = "Dub"),
        )
        // metadata-scored candidates (same genre, other artists)
        val scored = (0 until 30).map { trk("s$it", "Scored$it", genre = "soul", year = 1981, raw = "Soul") }
        val all = members + door + scored
        return all to all.associate { it.songId to vec(0.9) }
    }

    @Test fun soundDoorSeatsAtMostTheQuotaAndOnlyWithTimbre() {
        val (tracks, timbre) = soundCrate()
        val members = (0 until 8).map { "m$it" }
        val withSound = ZoneEngine.rank(members, tracks, noPlays, timbre = timbre)
        assertEquals(3, withSound.soundAdmitted.size) // 0.12 x 25 = 3, hard cap 3
        assertTrue(withSound.soundAdmitted.all { it.startsWith("d") })
        assertTrue(withSound.ids.containsAll(withSound.soundAdmitted))
        assertFalse(withSound.ids.first() in withSound.soundAdmitted) // never row 0
        assertFalse(withSound.soundWords.isNullOrEmpty())

        val without = ZoneEngine.rank(members, tracks, noPlays)
        assertTrue(without.soundAdmitted.isEmpty())
        assertTrue(without.ids.none { it.startsWith("d") }) // the gate rejects them outright
        assertEquals(null, without.soundWords)
    }

    @Test fun soundAdmittedAgreesBetweenSuggestionsAndExplained() {
        val (tracks, timbre) = soundCrate()
        val members = (0 until 8).map { "m$it" }
        val rank = ZoneEngine.rank(members, tracks, noPlays, timbre = timbre)
        val ex = ZoneEngine.explainedSuggestions(members, tracks, noPlays, timbre = timbre)
        assertEquals(rank.ids, ex.rows.map { it.songId })
        assertEquals(rank.soundAdmitted, ex.soundAdmitted)
        for (r in ex.rows) {
            // an admitted row is ALWAYS captioned as sound; a scored row may also earn it on a real fit
            if (r.songId in rank.soundAdmitted) assertTrue(r.why.startsWith("Sounds like this crate"))
            else assertTrue(r.why.isNotBlank())
        }
        assertEquals(3, ex.soundAdmitted.size)
    }

    @Test fun soundDoorVetoesSkippedAndRejectedRows() {
        val (tracks, timbre) = soundCrate()
        val members = (0 until 8).map { "m$it" }
        val base = ZoneEngine.rank(members, tracks, noPlays, timbre = timbre).soundAdmitted
        val victim = base.first()
        val skipped = ZoneEngine.rank(
            members, tracks, noPlays, Feedback(skipPenalty = mapOf(victim to 1.0)), timbre = timbre,
        )
        assertFalse(victim in skipped.soundAdmitted) // 0.65 < MIN_NET_FIT 0.9
        val rejectedArtistRow = tracks.first { it.songId == victim }.copy(songId = "rejectedD", title = "Other title")
        val rej = ZoneEngine.rank(
            members, tracks + rejectedArtistRow, noPlays,
            Feedback(rejected = mapOf("rejectedD" to 3.0)), timbre = timbre + ("rejectedD" to vec(0.9)),
        )
        // a fully-saturated rejection of the victim's artist shape: 1 - 0.5 = 0.5 < 0.9
        assertFalse(victim in rej.soundAdmitted)
    }

    @Test fun soundDoorSkipsIncumbentArtists() {
        val (tracks, timbre) = soundCrate()
        // d-row whose artist is a credit-collab including the crate's artist: incumbent, may not enter
        val collab = trk("dInc", "Mem & Guest", genre = "jazz", year = 1960, raw = "Swing")
        val r = ZoneEngine.rank((0 until 8).map { "m$it" }, tracks + collab, noPlays, timbre = timbre + ("dInc" to vec(0.9)))
        assertFalse("dInc" in r.soundAdmitted)
    }

    // ── empty timbre ⇒ pre-v2 ───────────────────────────────────────────────────────────

    @Test fun emptyTimbreRankingIsByteIdenticalToPreV2() {
        val (tracks, timbre) = soundCrate()
        val members = (0 until 8).map { "m$it" }
        val plays = mapOf("m0" to 9, "s1" to 4, "s2" to 1)
        val pc: (String) -> Int = { plays[it] ?: 0 }
        val plain = ZoneEngine.rank(members, tracks, pc)
        // 1. fewer than timbreMinVectors analysed members ⇒ no profile ⇒ multiplier drops entirely
        val sparse = ZoneEngine.rank(members, tracks, pc, timbre = mapOf("m0" to vec(0.9), "m1" to vec(0.8), "s0" to vec(0.2)))
        assertEquals(plain, sparse)
        // 2. a live timbre profile with timbreGain = 0 and the door shut is the same ordering as v1
        val noTimbreTuning = Tuning(timbreGain = 0.0, soundAdmitMaxShare = 0.0)
        val off = ZoneEngine.rank(members, tracks, pc, tuning = noTimbreTuning, timbre = timbre)
        assertEquals(plain.ids, off.ids)
        assertTrue(off.soundAdmitted.isEmpty())
    }

    @Test fun emptyTimbreZoneIsByteIdenticalToZoneWithTooFewVectors() {
        val sparse = mapOf(id(0, 0) to vec(0.9), id(0, 1) to vec(0.1)) // < 3 analysed seeds
        assertEquals(zone(recentPlays), ZoneEngine.inDaZone(
            songs = songs, genreBySongId = genreOf, plays = recentPlays, playCount = noPlays,
            timbre = sparse, nowMs = now,
        ))
    }

    @Test fun timbreOnlyReordersInsideTheZoneRediscoveryPool() {
        val plays = listOf(play(id(0, 0), 1.0), play(id(0, 1), 2.0), play(id(0, 2), 3.0))
        // seeds all bright; give one rediscovery candidate a matching vector, its twin a far one
        val vecs = hashMapOf<String, Map<String, Double>>(
            id(0, 0) to vec(0.9), id(0, 1) to vec(0.9), id(0, 2) to vec(0.9),
            id(3, 0) to vec(0.9), id(6, 0) to vec(0.1),
        )
        val base = zone(plays)
        val withT = ZoneEngine.inDaZone(songs, genreOf, plays = plays, playCount = noPlays, timbre = vecs, nowMs = now)
        // same members in the familiar pool, same size: timbre never adds/removes songs
        assertEquals(base.picks.filter { it.pool == Pool.FAMILIAR }, withT.picks.filter { it.pool == Pool.FAMILIAR })
        assertEquals(base.count, withT.count)
    }

    @Test fun versionKeysParseOnceAndSkipUntitledRows() {
        val tracks = listOf(trk("a", "A", title = "Song"), trk("b", "A", title = "Song (Deluxe Edition)"),
            trk("c", "A").copy(title = null))
        val v = ZoneEngine.versionKeys(tracks)
        assertTrue("a" in v && "b" in v)
        assertFalse("c" in v)
        assertEquals(RecRecordingIdentity.recordingKey(v["a"]), RecRecordingIdentity.recordingKey(v["b"]))
    }

    @Test fun precomputedVersionsGiveTheSameAnswerAsDerivingThemHere() {
        val tracks = listOf(trk("m1", "Zed", title = "Echo"), trk("v1", "Zed", title = "Echo (Deluxe)"), trk("n", "Zed", title = "New"))
        assertEquals(
            ZoneEngine.suggestions(listOf("m1"), tracks, noPlays),
            ZoneEngine.suggestions(listOf("m1"), tracks, noPlays, versions = ZoneEngine.versionKeys(tracks)),
        )
    }

    @Test fun eraCaptionIsEmittedForAnEraOnlyCandidate() {
        fun t(id: String, artist: String, genre: String?, year: Int) =
            Track(songId = id, artistKey = artist.lowercase(), artistName = artist, genre = genre, year = year)
        val members = (0 until 4).map { t("m$it", "Member", "rock", 2000 + it) }
        // the era caption is only reachable for a candidate admitted through a 👍'd genre that the
        // crate's own members do not carry (memberGenres is members-only; the profile includes accepted)
        val liked = t("liked", "Liked Artist", "jazz", 2001)
        val cands = (0 until 6).map { t("c$it", "Other $it", "jazz", 2001) }
        val tracks = members + liked + cands
        val ex = ZoneEngine.suggestionsExplained(
            members.map { it.songId }, tracks, noPlays, feedback = Feedback(accepted = mapOf("liked" to 1.0)),
        )
        val era = ex.firstOrNull { it.why.startsWith("From this collection's") }
        assertTrue("expected an era caption, got ${ex.map { it.why }}", era != null)
        val w = SimilarityFamilies.eraWindow((members + liked).map { it.year!!.toDouble() })!!
        assertEquals("From this collection's ${w.lo.toInt()}–${w.hi.toInt()} era", era!!.why)
    }
}
