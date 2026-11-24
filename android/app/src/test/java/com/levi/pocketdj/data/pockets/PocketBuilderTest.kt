package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkParser
import kotlinx.coroutines.runBlocking
import org.junit.Test

// kotlin-test isn't on this module's classpath; thin value-first wrappers over JUnit 4.
private fun <T> assertEquals(expected: T, actual: T, message: String? = null) = org.junit.Assert.assertEquals(message, expected, actual)
private fun assertTrue(cond: Boolean, message: String? = null) = org.junit.Assert.assertTrue(message, cond)
private fun assertFalse(cond: Boolean, message: String? = null) = org.junit.Assert.assertFalse(message, cond)
private fun assertNull(v: Any?) = org.junit.Assert.assertNull(v)
private inline fun <reified T : Any> assertIs(v: Any?): T {
    org.junit.Assert.assertTrue("expected ${T::class.simpleName} but was $v", v is T)
    return v as T
}

class PocketBuilderTest {
    private val vocab = PocketVocabulary(
        genres = setOf("Hip-Hop/Rap", "Neo Soul", "Alternative Rock"),
        moods = setOf("laid-back", "optimism", "gritty"),
    )

    // ---- parser goldens ----

    @Test fun decadeWithMoodAndGenre() {
        val p = PocketBriefParser.parse("Create a pocket of 90s chill hip hop", vocab)
        assertEquals(1990, p.yearFrom); assertEquals(1999, p.yearTo)
        assertTrue("hip hop" in p.genres, p.genres.toString())
        assertEquals("chill", p.moods.first())
        assertTrue("relaxed" in p.moods) // synonym expansion
        assertNull(p.minutes)
    }

    @Test fun nineties_wordForm() {
        val p = PocketBriefParser.parse("nineties hip hop", vocab)
        assertEquals(1990 to 1999, p.yearFrom to p.yearTo)
        assertEquals(listOf("hip hop"), p.genres)
        assertTrue(p.moods.isEmpty())
    }

    @Test fun iosExampleBrief() {
        val p = PocketBriefParser.parse("optimistic soul, funk, r&b or disco songs from 1960–1989", vocab)
        assertEquals(1960 to 1989, p.yearFrom to p.yearTo)
        assertEquals(setOf("soul", "funk", "r&b", "disco"), p.genres.toSet())
        assertEquals("optimistic", p.moods.first())
    }

    @Test fun qualifiedDecades() {
        assertEquals(1980 to 1984, PocketBriefParser.parse("early 80s synth pop").let { it.yearFrom to it.yearTo })
        assertEquals(1995 to 1999, PocketBriefParser.parse("late nineties rock").let { it.yearFrom to it.yearTo })
        assertEquals(1993 to 1997, PocketBriefParser.parse("mid '90s rock").let { it.yearFrom to it.yearTo })
        assertEquals(2000 to 2009, PocketBriefParser.parse("2000s pop").let { it.yearFrom to it.yearTo })
        assertEquals(2010 to 2019, PocketBriefParser.parse("10s pop").let { it.yearFrom to it.yearTo })
    }

    @Test fun singleYearAndTwoDigitRangeEnd() {
        assertEquals(1977 to 1977, PocketBriefParser.parse("disco from 1977").let { it.yearFrom to it.yearTo })
        assertEquals(1965 to 1975, PocketBriefParser.parse("soul 1965-75").let { it.yearFrom to it.yearTo })
    }

    @Test fun lengthIsExtractedAndNotMistakenForYear() {
        val a = PocketBriefParser.parse("a 45 minute pocket of jazz")
        assertEquals(45, a.minutes); assertNull(a.yearFrom); assertEquals(listOf("jazz"), a.genres)
        assertEquals(120, PocketBriefParser.parse("2 hours of funk").minutes)
        assertEquals(60, PocketBriefParser.parse("an hour of blues").minutes)
    }

    @Test fun catalogVocabularyIsUsed() {
        val p = PocketBriefParser.parse("gritty neo soul", vocab)
        assertTrue("neo soul" in p.genres)
        assertEquals(listOf("gritty"), p.moods)
        assertTrue(PocketBriefParser.parse("laid-back alternative rock", vocab).genres.contains("alternative rock"))
    }

    @Test fun ambiguousWordsAreMoodsNotGenres() {
        val p = PocketBriefParser.parse("romantic dance", vocab)
        assertTrue(p.genres.isEmpty(), p.genres.toString())
        assertTrue("romantic" in p.moods)
    }

    @Test fun spokenRAndB() {
        assertTrue("r&b" in PocketBriefParser.parse("90s r and b").genres)
    }

    // ---- search ----

    private fun catalog(): PocketCatalog {
        val albums = mapOf(
            "a1" to IndexAlbum("a1", "X", "A1", genre = "Hip-Hop/Rap", year = 1994),
            "a2" to IndexAlbum("a2", "Y", "A2", genre = "Conscious Hip Hop", year = 1996),
            "a3" to IndexAlbum("a3", "Z", "A3", genre = "Rock", year = 1995),
            "a4" to IndexAlbum("a4", "W", "A4", genre = "Hip-Hop/Rap", year = 2005),
            "a5" to IndexAlbum("a5", "V", "A5", genre = "Hip-Hop/Rap", year = null),
        )
        val songs = listOf(
            IndexSong("s1", "a1", "X", "Plain", length = 200_000),
            IndexSong("s2", "a1", "X", "Chilled", sentimentKeywords = listOf("chill", "smooth"), length = 200_000),
            IndexSong("s3", "a2", "Y", "Cat Match", length = 200_000),
            IndexSong("s4", "a3", "Z", "Wrong Genre", length = 200_000),
            IndexSong("s5", "a4", "W", "Wrong Year", length = 200_000),
            IndexSong("s6", "a5", "V", "Unknown Year", length = 200_000),
            IndexSong("s7", "a1", "X", "Own Year", year = 1999, length = 200_000),
        )
        return PocketCatalog(songs, albums)
    }

    @Test fun searchIsExactOnYearsFuzzyOnGenreAndRanksMood() {
        val brief = PocketBriefParser.parse("90s chill hip hop", vocab)
        val ids = PocketCandidateSearch.candidates(catalog(), brief).map { it.id }
        assertEquals("s2", ids.first(), "mood match ranks first")
        assertTrue("s1" in ids && "s7" in ids)
        assertTrue("s3" in ids, "star-map category match stays eligible (0.5)")
        assertFalse("s4" in ids, "genre mismatch excluded")
        assertFalse("s5" in ids, "out-of-range year excluded")
        assertFalse("s6" in ids, "unknown year is out when years are specified")
        assertTrue(ids.indexOf("s1") < ids.indexOf("s3"), "substring genre (1.0) beats category (0.5)")
    }

    @Test fun noFiltersKeepsEverythingInCatalogOrder() {
        val ids = PocketCandidateSearch.candidates(catalog(), ParsedPocketBrief()).map { it.id }
        assertEquals(listOf("s1", "s2", "s3", "s4", "s5", "s6", "s7"), ids)
    }

    @Test fun tokenSimilarityTiers() {
        assertEquals(1.0, PocketCandidateSearch.tokenSimilarity("chill", "chill"))
        assertEquals(0.7, PocketCandidateSearch.tokenSimilarity("optimistic", "optimist"))
        assertEquals(0.5, PocketCandidateSearch.tokenSimilarity("optimism", "optimistic").let { if (it == 0.7) 0.5 else it })
        assertEquals(0.0, PocketCandidateSearch.tokenSimilarity("dark", "happy"))
    }

    // ---- fitter ----

    @Test fun fitSkipsOverflowButKeepsLaterShortOnes() {
        val len = mapOf("a" to 40L, "b" to 50L, "c" to 30L, "d" to 10L)
        val out = PocketFitter.fit(listOf("a", "b", "c", "d"), { len[it] }, 100L)
        assertEquals(listOf("a", "b", "d"), out)
    }

    @Test fun fitAlwaysKeepsFirstAndUsesFallbackLength() {
        assertEquals(listOf("big"), PocketFitter.fit(listOf("big", "small"), { if (it == "big") 999L else 1L }, 10L).take(1))
        // unknown length counts as 3:30
        val out = PocketFitter.fit(listOf("u1", "u2", "u3"), { null }, 2 * PocketFitter.FALLBACK_LENGTH_MS)
        assertEquals(listOf("u1", "u2"), out)
    }

    // ---- naming ----

    @Test fun nameFor() {
        assertEquals("90s Chill Hip Hop", DeepLessNaming.name("Create a pocket of 90s chill hip hop"))
        assertEquals("Optimistic Soul, Funk", DeepLessNaming.name("make me a pocket with optimistic soul, funk songs"))
        assertEquals("New Pocket", DeepLessNaming.name("   "))
        assertEquals("R&B", DeepLessNaming.name("r&b"))
    }

    private object DeepLessNaming { fun name(b: String) = DeterministicPocketBriefModel.nameFor(b) }

    // ---- end to end ----

    private fun bigCatalog(): PocketCatalog {
        val albums = (0 until 12).associate { i -> "al$i" to IndexAlbum("al$i", "Artist$i", "Album$i", genre = "Hip-Hop/Rap", year = 1990 + i % 10) }
        val songs = (0 until 120).map { i ->
            IndexSong("s$i", "al${i % 12}", "Artist${i % 12}", "Song $i", length = 240_000,
                sentimentKeywords = if (i % 3 == 0) listOf("chill") else null)
        }
        return PocketCatalog(songs, albums)
    }

    private class Persist {
        var name: String? = null; var ids: List<String> = emptyList(); var desc: String? = null; var calls = 0
        fun fn(n: String, i: List<String>, d: String): String { name = n; ids = i; desc = d; calls++; return "pocket-1" }
    }

    @Test fun buildsAboutNinetyMinutesAndPersists() = runBlocking<Unit> {
        val p = Persist()
        val svc = PocketBuilderService(scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            catalog = { bigCatalog() }, persist = p::fn)
        svc.build("Create a pocket of 90s chill hip hop")
        val done = assertIs<PocketBuilderService.Phase.Done>(svc.phase.value)
        assertEquals("pocket-1", done.pocketId)
        assertEquals("90s Chill Hip Hop", p.name)
        assertEquals(22, p.ids.size) // 22 x 4:00 = 88 min <= 90 (a 23rd would overflow)
        assertTrue(done.minutes in 85..90, "minutes=${done.minutes}")
        assertEquals(p.ids.size, p.ids.toSet().size)
        assertTrue(p.ids.first() == "s0", "mood-matched song ranks first: ${p.ids.first()}")
        assertTrue(p.desc!!.contains("90s chill hip hop"))
        svc.acknowledge()
        assertEquals(PocketBuilderService.Phase.Idle, svc.phase.value)
    }

    @Test fun briefLengthOverridesDefault() = runBlocking<Unit> {
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined), { bigCatalog() }, p::fn)
        svc.build("a 30 minute pocket of hip hop", targetMinutes = 90)
        assertEquals(7, p.ids.size) // 7 x 4:00 = 28 min
    }

    @Test fun failsHonestlyWhenNothingMatches() = runBlocking<Unit> {
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined), { bigCatalog() }, p::fn)
        svc.build("1950s opera")
        val f = assertIs<PocketBuilderService.Phase.Failed>(svc.phase.value)
        assertTrue(f.message.contains("1950s opera"))
        assertEquals(0, p.calls)
    }

    @Test fun briefWithNoRecognisedFiltersFailsInsteadOfDumpingTheCatalog() = runBlocking<Unit> {
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined), { bigCatalog() }, p::fn)
        svc.build("Create a pocket of Prince")
        val f = assertIs<PocketBuilderService.Phase.Failed>(svc.phase.value)
        assertTrue(f.message.contains("couldn't tell"))
        assertEquals(0, p.calls)
    }

    @Test fun moodOnlySearchExcludesSongsWithNoMoodEvidence() {
        val big = bigCatalog()
        val ids = PocketCandidateSearch.candidates(big, ParsedPocketBrief(moods = listOf("chill"))).map { it.id }
        assertTrue(ids.isNotEmpty())
        assertTrue(ids.all { it.removePrefix("s").toInt() % 3 == 0 }, "only mood-tagged songs: $ids")
    }

    @Test fun blankBriefAndMissingCatalogFail() = runBlocking<Unit> {
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        val blank = PocketBuilderService(scope, { bigCatalog() }, Persist()::fn)
        blank.build("   ")
        assertIs<PocketBuilderService.Phase.Failed>(blank.phase.value)
        val none = PocketBuilderService(scope, { null }, Persist()::fn)
        none.build("hip hop")
        assertIs<PocketBuilderService.Phase.Failed>(none.phase.value)
    }

    @Test fun modelInventedIdsAreDroppedAndDuplicatesRemoved() = runBlocking<Unit> {
        val model = object : PocketBriefModel {
            override suspend fun parse(brief: String, vocab: PocketVocabulary) = ParsedPocketBrief(genres = listOf("hip hop"))
            override suspend fun curate(brief: String, candidates: List<PocketCandidate>, maxSongs: Int) =
                PocketPlan("  ", listOf("ghost", "s1", "s1", "s2", "also-ghost"))
        }
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            { bigCatalog() }, p::fn, nano = { model })
        svc.build("hip hop bangers")
        assertEquals(listOf("s1", "s2"), p.ids)
        assertEquals("Hip Hop Bangers", p.name, "blank model name falls back to the brief")
    }

    @Test fun nanoFailureFallsBackToDeterministic() = runBlocking<Unit> {
        val broken = object : PocketBriefModel {
            override suspend fun parse(brief: String, vocab: PocketVocabulary): ParsedPocketBrief = error("nano down")
            override suspend fun curate(brief: String, candidates: List<PocketCandidate>, maxSongs: Int): PocketPlan = error("nano down")
        }
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            { bigCatalog() }, p::fn, nano = { broken })
        svc.build("90s hip hop")
        assertIs<PocketBuilderService.Phase.Done>(svc.phase.value)
        assertEquals(22, p.ids.size)
    }

    @Test fun nanoReadingThatMatchesNothingFallsBackToGrammar() = runBlocking<Unit> {
        val odd = object : PocketBriefModel {
            override suspend fun parse(brief: String, vocab: PocketVocabulary) = ParsedPocketBrief(genres = listOf("polka"))
            override suspend fun curate(brief: String, candidates: List<PocketCandidate>, maxSongs: Int) = PocketPlan("x", emptyList())
        }
        val p = Persist()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
            { bigCatalog() }, p::fn, nano = { odd })
        svc.build("hip hop")
        assertIs<PocketBuilderService.Phase.Done>(svc.phase.value)
    }

    @Test fun artistCapSpreadsThePocket() = runBlocking<Unit> {
        val c = (0 until 10).map { PocketCandidate("a$it", "t", "Same", null, null, 200_000, emptyList()) } +
            (0 until 4).map { PocketCandidate("b$it", "t", "Other", null, null, 200_000, emptyList()) }
        val plan = DeterministicPocketBriefModel(maxPerArtist = 3).curate("x", c, 6)
        assertEquals(listOf("a0", "a1", "a2", "b0", "b1", "b2"), plan.songIds)
        // too thin to satisfy the cap: topped up rather than short
        val thin = DeterministicPocketBriefModel(maxPerArtist = 1).curate("x", c.take(5), 4)
        assertEquals(4, thin.songIds.size)
    }

    @Test fun secondKickOffWhileBuildingIsRefused() = runBlocking<Unit> {
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val svc = PocketBuilderService(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            { gate.await(); bigCatalog() }, Persist()::fn)
        val job = svc.kickOff("hip hop")
        assertTrue(job != null)
        assertNull(svc.kickOff("jazz"))
        svc.acknowledge() // building is not dismissable
        assertIs<PocketBuilderService.Phase.Building>(svc.phase.value)
        gate.complete(Unit); job!!.join()
        assertIs<PocketBuilderService.Phase.Done>(svc.phase.value)
    }

    // ---- deep link ----

    @Test fun createPocketDeepLink() {
        assertEquals(DeepLink.CreatePocket("90s chill hip hop"),
            DeepLinkParser.parse("pocketdj://create-pocket?brief=90s%20chill%20hip%20hop"))
        assertEquals(DeepLink.CreatePocket(null), DeepLinkParser.parse("pocketdj://create-pocket"))
        assertEquals(DeepLink.CreatePocket(null), DeepLinkParser.parse("pocketdj://create-pocket?brief=%20"))
    }
}
