package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.recs.RecComposition.Diversity
import com.levi.pocketdj.data.recs.RecComposition.Row
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecShapingTest {

    // ── novelty ──

    @Test fun primaryCreditCutsCollabsButNotTylerTheCreator() {
        assertEquals("drake", RecNovelty.primaryCredit("Drake feat. Rihanna"))
        assertEquals("drake", RecNovelty.primaryCredit("Drake & Future"))
        assertEquals("drake", RecNovelty.primaryCredit("Drake, Future"))
        assertEquals("a", RecNovelty.primaryCredit("A/B"))
        assertEquals("tyler, the creator", RecNovelty.primaryCredit("Tyler, The Creator"))
        assertEquals("tyler, the creator", RecNovelty.primaryCredit("Tyler, The Creator & Kali Uchis"))
        assertEquals("fetty wap", RecNovelty.primaryCredit("Fetty Wap"))
        assertEquals("xavier", RecNovelty.primaryCredit("Xavier"))
        assertEquals("kali uchis", RecNovelty.primaryCredit("Kali Uchis x Tyler"))
        assertEquals("beatles", RecNovelty.primaryArtistKey("The Beatles with Billy Preston"))
    }

    @Test fun familiarityIsLogScaledAndInertWhenEmpty() {
        val none = RecNovelty.artistFamiliarity(emptyList())
        assertFalse(none.isLive)
        assertEquals(0.0, none.novelty("x"), 0.0)
        assertNull(none.reason("x"))

        val f = RecNovelty.artistFamiliarity(listOf("a" to 7, "a" to 0, "b" to 1, "c" to 0))
        assertTrue(f.isLive)
        assertEquals(1.0, f.familiarity("a"), 1e-12)
        assertEquals(1.0 / 3.0, f.familiarity("b"), 1e-12)   // log2(2)/log2(8)
        assertEquals(1.0, f.novelty("zzz"), 1e-12)
        assertEquals("An artist you've never played", f.reason("zzz"))
        assertNull(f.reason("b"))
        val rare = RecNovelty.ArtistFamiliarity.of(mapOf("a" to 1000, "b" to 1))
        assertEquals("An artist you rarely play", rare.reason("b"))
    }

    @Test fun auxMix() {
        assertEquals(0.0, RecNovelty.aux(1.0, 0.0, 1.0, 1.0, false), 0.0)
        assertEquals(0.0, RecNovelty.aux(1.0, 0.0, 0.0, 0.0, true), 0.0)
        assertEquals(0.75, RecNovelty.aux(1.0, 0.0, 3.0, 1.0, true), 1e-12)
    }

    // ── composition ──

    private fun r(id: String, artist: String, inc: Boolean = false, genre: String? = null, newGenre: Boolean = false) =
        Row(id, artist, inc, genre, newGenre)

    @Test fun composeRespectsLimitAndPerArtistCap() {
        val rows = listOf(r("1", "a"), r("2", "a"), r("3", "a"), r("4", "b"), r("5", "c"), r("6", "d"))
        assertEquals(listOf("1", "2", "4", "5"), RecComposition.compose(rows, 4, 2, 1.0))
        // non-positive cap = uncapped
        assertEquals(listOf("1", "2", "3"), RecComposition.compose(rows, 3, 0, 1.0))
        assertEquals(listOf("1", "2", "3"), RecComposition.compose(rows, 3, null, 1.0))
    }

    @Test fun incumbentBudgetDefersThenFailsOpen() {
        val rows = listOf(r("i1", "a", true), r("i2", "b", true), r("n1", "c"), r("n2", "d"))
        // n=3, cap floor(3*0.34)=1 incumbent
        assertEquals(listOf("i1", "n1", "n2"), RecComposition.compose(rows, 3, 1, 0.34))
        // newcomer pool dry => spilled incumbents refill
        val onlyInc = listOf(r("i1", "a", true), r("i2", "b", true), r("n1", "c"))
        assertEquals(listOf("i1", "n1", "i2"), RecComposition.compose(onlyInc, 3, 1, 0.34))
    }

    @Test fun diversityFloorSwapsLowestRankedRedundantRow() {
        val rows = listOf(
            r("1", "a", genre = "rock"), r("2", "b", genre = "rock"), r("3", "c", genre = "rock"),
            r("4", "d", genre = "rock"), r("5", "e", genre = "jazz"), r("6", "f", genre = "soul"),
        )
        assertEquals(listOf("1", "2", "3", "4"), RecComposition.compose(rows, 4, 1, 1.0))
        val out = RecComposition.compose(rows, 4, 1, 1.0, diversity = Diversity(3, 5))
        assertEquals(listOf("1", "2", "5", "6"), out.sorted())
        assertEquals(4, out.size)
        assertEquals("1", out.first())                         // head never disturbed
        assertEquals(setOf("rock", "jazz", "soul"), out.mapNotNull { id -> rows.first { it.id == id }.rawGenre }.toSet())
    }

    @Test fun diversityFloorFailsOpenAndHonoursArtistCap() {
        val rows = listOf(
            r("1", "a", genre = "rock"), r("2", "b", genre = "rock"),
            r("3", "a", genre = "jazz"),   // artist a is at its cap, so only seatable by displacing its own row 1
        )
        // the victim scan walks up past b (budget-blocked for "a" only via b's seat) to a's own row
        assertEquals(listOf("3", "2"), RecComposition.compose(rows, 2, 1, 1.0, diversity = Diversity(2, 5)))
        // no row carries a missing genre => nothing changes (fails open)
        val flat = listOf(r("1", "a", genre = "rock"), r("2", "b", genre = "rock"), r("3", "c", genre = "rock"))
        assertEquals(listOf("1", "2"), RecComposition.compose(flat, 2, 1, 1.0, diversity = Diversity(2, 5)))
        // maxSwaps = 0 disables the floor
        assertEquals(listOf("1", "2"), RecComposition.compose(rows, 2, 1, 1.0, diversity = Diversity(2, 0)))
    }

    @Test fun soundAdmitSeatedAtFixedPositionsWithoutLengthening() {
        val rows = (1..8).map { r("r$it", "a$it") }
        val sound = RecComposition.SoundAdmit(listOf(r("s1", "x1"), r("s2", "x2")), maxShare = 0.5, hardCap = 2, stride = 2)
        val out = RecComposition.compose(rows, 8, 1, 1.0, soundAdmit = sound)
        assertEquals(8, out.size)
        assertEquals("s1", out[4])
        assertEquals("s2", out[6])
        assertTrue("r1" in out && out.indexOf("r1") == 0)       // top match never displaced
        // quota = min(hardCap, rows, floor(n*share))
        val small = RecComposition.compose(rows, 2, 1, 1.0, soundAdmit = sound.copy(maxShare = 0.4))
        assertFalse("s1" in small)    // floor(2*0.4)=0
    }

    // ── sound admit ──

    private fun c(id: String, artist: String, decade: Int?, genre: String?, d: Double) =
        RecSoundAdmit.Candidate(id, artist, decade, genre, d)

    @Test fun soundAdmitCapsSkewPerDecadeGenreArtist() {
        val pool = listOf(
            c("a", "x", 1990, "rock", 0.1),
            c("b", "y", 1990, "jazz", 0.2),    // decade dup
            c("c", "x", 2000, "soul", 0.3),    // artist dup
            c("d", "z", 2000, "rock", 0.4),    // genre dup
            c("e", "w", 2010, "folk", 0.5),
            c("f", "v", null, null, 0.6),
            c("g", "u", null, null, 0.7),      // undated + ungenred dup
        )
        assertEquals(listOf("a", "e", "f"), RecSoundAdmit.select(pool, 10).map { it.id })
        assertEquals(listOf("a", "e"), RecSoundAdmit.select(pool, 2).map { it.id })
        assertTrue(RecSoundAdmit.select(pool, 0).isEmpty())
    }

    @Test fun soundAdmitDistanceTieBreaksOnIdAndEmptyCapKeyUsesId() {
        val pool = listOf(c("b", "", 1980, "g1", 0.5), c("a", "", 1990, "g2", 0.5))
        assertEquals(listOf("a", "b"), RecSoundAdmit.select(pool, 5).map { it.id })
        assertEquals("hip hop", RecSoundAdmit.genreBucket("  Hip   Hop "))
        assertNull(RecSoundAdmit.genreBucket("   "))
        assertNull(RecSoundAdmit.genreBucket(null))
    }

    @Test fun trimKeepsNearest() {
        val pool = (0 until RecSoundAdmit.TRIM_AT).map { c("id$it", "a$it", 1990, "g", (RecSoundAdmit.TRIM_AT - it).toDouble()) }.toMutableList()
        RecSoundAdmit.trimIfNeeded(pool)
        assertEquals(RecSoundAdmit.TRIM_TO, pool.size)
        assertEquals("id${RecSoundAdmit.TRIM_AT - 1}", pool.first().id)
        val small = pool.toMutableList()
        RecSoundAdmit.trimIfNeeded(small)
        assertEquals(RecSoundAdmit.TRIM_TO, small.size)
    }

    // ── audio shortlist ──

    private fun cand(id: String, artist: String, genre: String? = null, bpm: Double? = null, key: String? = null) =
        RecAudioShortlist.Candidate(id, artist, genre, bpm, key)

    @Test fun camelotAdjacency() {
        assertTrue(RecAudioShortlist.camelotAdjacent("8A", "8B"))
        assertTrue(RecAudioShortlist.camelotAdjacent("12A", "1A"))
        assertTrue(RecAudioShortlist.camelotAdjacent("5B", "6B"))
        assertFalse(RecAudioShortlist.camelotAdjacent("5B", "7B"))
        assertFalse(RecAudioShortlist.camelotAdjacent("5A", "6B"))
        assertFalse(RecAudioShortlist.camelotAdjacent("13A", "1A"))
        assertFalse(RecAudioShortlist.camelotAdjacent("junk", "1A"))
    }

    @Test fun similarityBlendsGenreBpmKey() {
        val p = RecAudioShortlist.RecentProfile(mapOf("rock" to 0.6, "jazz" to 0.3), 120.0, setOf("8A"))
        assertEquals(1.0, RecAudioShortlist.similarity(cand("1", "a", "rock", 120.0, "8A"), p), 1e-12)
        // jazz: 0.5*0.5, bpm off by 12 => 0.3*0.5, adjacent key => 0.2*0.6
        val expected = (0.5 * 0.5 + 0.3 * 0.5 + 0.2 * 0.6) / 1.0
        assertEquals(expected, RecAudioShortlist.similarity(cand("2", "a", "jazz", 132.0, "9a"), p), 1e-12)
        assertEquals(0.0, RecAudioShortlist.similarity(cand("3", "a"), p), 1e-12)
        assertEquals(0.0, RecAudioShortlist.similarity(cand("4", "a", "rock"), RecAudioShortlist.RecentProfile()), 0.0)
        assertFalse(RecAudioShortlist.RecentProfile().isLive)
    }

    @Test fun recentProfileFromRecent() {
        val prof = RecAudioShortlist.RecentProfile.from(listOf(
            cand("1", "a", "rock", 100.0, "8a"), cand("2", "b", "rock", 140.0, "9A"), cand("3", "c", "jazz", null, null),
        ))
        assertEquals(2.0 / 3.0, prof.genreShare.getValue("rock"), 1e-12)
        assertEquals(120.0, prof.meanBpm!!, 1e-12)
        assertEquals(setOf("8A", "9A"), prof.camelotCodes)
        assertTrue(prof.isLive)
    }

    @Test fun shortlistExcludesAnalysedAndPendingAndAlternatesAxes() {
        val fam = RecNovelty.ArtistFamiliarity.of(mapOf("fav" to 100, "new1" to 0, "meh" to 4))
        val cands = listOf(
            cand("done", "new1"), cand("pending", "new1"),
            cand("f1", "fav", "rock"), cand("f2", "fav", "rock"),
            cand("m1", "meh", "jazz"), cand("n1", "never", "folk"),
        )
        val inputs = RecAudioShortlist.Inputs(
            candidates = cands,
            analysedIds = setOf("done"),
            pendingIds = setOf("pending"),
            recent = RecAudioShortlist.RecentProfile(mapOf("rock" to 1.0)),
            familiarity = fam,
            perNight = 4,
        )
        val picked = RecAudioShortlist.select(inputs)
        assertFalse("done" in picked || "pending" in picked)
        // novelty first (never-played artist), then best genre match, then next novelty, then next similar
        assertEquals(listOf("n1", "f1", "m1", "f2"), picked)
    }

    @Test fun shortlistPerArtistCapAndShortWhenExhausted() {
        val cands = (1..6).map { cand("s$it", "same") } + cand("o", "other")
        val picked = RecAudioShortlist.select(RecAudioShortlist.Inputs(candidates = cands, perNight = 40, perArtistCap = 3))
        assertEquals(4, picked.size)
        assertEquals(3, picked.count { it.startsWith("s") })
        assertTrue(RecAudioShortlist.select(RecAudioShortlist.Inputs(candidates = cands, perNight = 0)).isEmpty())
    }
}
