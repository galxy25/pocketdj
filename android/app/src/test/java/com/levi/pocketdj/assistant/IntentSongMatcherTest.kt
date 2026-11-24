package com.levi.pocketdj.assistant

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IntentSongMatcherTest {
    private fun row(id: String, name: String, artist: String) = IntentSongMatcher.Row(id, name, artist)

    private val rows = listOf(
        row("mmp", "Make Me Proud", "Drake"),
        row("mmp-r", "Make Me Proud (Remastered)", "Drake"),
        row("mmp-2", "Make Me Proud", "Someone Else"),
        row("sbm", "Stand by Me", "Ben E. King"),
        row("ss", "Stand", "R.E.M."),
        row("hello", "Hello", "Adele"),
        row("hello2", "Hello", "Lionel Richie"),
        row("rem", "Rolling in the Deep - 2011 Remaster", "Adele"),
        row("lib", "Liberty Bell March", "Sousa"),
    )

    private fun ids(q: String, prefer: (String) -> Boolean = { false }) =
        IntentSongMatcher.rank(q, rows, prefer).map { it.id }

    @Test
    fun readings_wholePhraseAndLastBy() {
        val r = IntentSongMatcher.readings("Stand by Me by Ben E. King")
        assertEquals(listOf("Stand by Me by Ben E. King" to null, "Stand by Me" to "Ben E. King"), r.map { it.title to it.artist })
        assertEquals(1, IntentSongMatcher.readings("make me proud").size)
        assertEquals("make me proud", IntentSongMatcher.readings("the song make me proud").single().title)
        assertEquals("make me proud", IntentSongMatcher.readings("\u201Cmake me proud\u201D").single().title)
        assertTrue(IntentSongMatcher.readings("   ").isEmpty())
        assertEquals(1, IntentSongMatcher.readings("by drake").size) // empty title: no split reading
    }

    @Test
    fun stripVersion_dropsParentheticalsAndDashTails() {
        assertEquals("Song", IntentSongMatcher.stripVersion("Song (feat. X) [Remastered] - 2011 Remaster"))
        assertEquals("Song", IntentSongMatcher.stripVersion("Song (unclosed"))
        assertEquals("Plain", IntentSongMatcher.stripVersion("Plain"))
    }

    @Test
    fun compact_foldsCaseDiacriticsAmpersand() {
        assertEquals("makemeproud", IntentSongMatcher.compact("Make Me Proud!"))
        assertEquals("cafedelmar", IntentSongMatcher.compact("Café del Mar"))
        assertEquals("rockandroll", IntentSongMatcher.compact("Rock & Roll"))
        assertEquals("a b c", IntentSongMatcher.wordKey("A, b... c"))
    }

    @Test
    fun exactTitleWithArtist_picksThatRecording() {
        // The Drake remaster (base tier) is within the band, but the other artist's copy is dropped.
        assertEquals(listOf("mmp", "mmp-r"), ids("Make Me Proud by Drake"))
    }

    @Test
    fun artistDisagreement_dropsThatReading() {
        // "Stand by Me" whole phrase must keep working even though " by " splits it.
        assertEquals(listOf("sbm"), ids("Stand by Me"))
    }

    @Test
    fun exactBeatsBaseBeatsPrefix() {
        val r = IntentSongMatcher.rank("make me proud", rows)
        assertEquals("mmp", r.first().id)
        assertEquals(100.0, r.first().score, 0.0)
        // The remaster scores 95 (base) and stays within the 12-point band, behind both exact rows.
        assertEquals(listOf("mmp", "mmp-2", "mmp-r"), ids("make me proud"))
        assertEquals(95.0, IntentSongMatcher.rank("rolling in the deep", rows).single().score, 0.0)
    }

    @Test
    fun prefixAndWholeWord() {
        assertEquals("lib", IntentSongMatcher.rank("liberty", rows).first().id)
        // whole word only for >= 4 chars; "bell" is in the middle of "Liberty Bell March".
        assertEquals(listOf("lib"), ids("bell"))
        assertTrue(ids("ell").isEmpty())
    }

    @Test
    fun typo_onlyWhenNothingLiteral() {
        val t = ids("make me prowd by drake")
        assertTrue("mmp" in t)
        assertTrue("mmp-2" !in t)
        assertEquals(listOf("sbm"), ids("stand by mee"))
        // literal exists ("hello") so typo-near "hallo" rows would never be considered.
        assertTrue(ids("hello").all { it.startsWith("hello") })
    }

    @Test
    fun noMatch_isEmpty() {
        assertTrue(ids("zzzz qqqq").isEmpty())
    }

    @Test
    fun agreeingArtist_addsScore_andDisagreeingDropsSong() {
        assertEquals(listOf("hello"), ids("hello by adele"))
        assertEquals(listOf("hello2"), ids("hello by lionel richie"))
        assertEquals(listOf("hello"), ids("hello by adel")) // typo'd artist still agrees
        assertTrue(ids("hello by nobody at all").isEmpty())
    }

    @Test
    fun dedupeByRecording_keepsOneCopy() {
        val dup = listOf(row("a", "Hello", "Adele"), row("b", "hello", "ADELE"), row("c", "Hello", "Lionel Richie"))
        val r = IntentSongMatcher.rank("hello", dup).map { it.id }
        assertEquals(listOf("a", "c"), r)
        // preferred copy wins within a recording
        val r2 = IntentSongMatcher.rank("hello", dup, prefer = { it == "b" }).map { it.id }
        assertEquals("b", r2.first())
        assertEquals(2, r2.size)
    }

    @Test
    fun preferredSong_winsTies() {
        assertEquals("hello2", IntentSongMatcher.rank("hello", rows, prefer = { it == "hello2" }).first().id)
        assertEquals("hello", IntentSongMatcher.rank("hello", rows).first().id)
    }

    @Test
    fun limit_capsList() {
        val many = (1..20).map { row("s$it", "Same Title", "Artist $it") }
        assertEquals(8, IntentSongMatcher.rank("same title", many).size)
        assertEquals(3, IntentSongMatcher.rank("same title", many, limit = 3).size)
    }

    // ---- through the resolver ----

    private fun resolve(q: String, focus: MediaFocus = MediaFocus.Any, title: String? = null, artist: String? = null) =
        MediaSearchResolver.resolve(MediaSearchRequest(q, focus, title = title, artist = artist), { rows }) { emptyList() }

    @Test
    fun resolver_any_uniqueTopTierSongPlays() {
        val r = resolve("Make Me Proud by Drake") as MediaSearchResult.Play
        assertEquals("mmp", r.candidate.id)
        assertEquals(MediaCandidate.Kind.Song, r.candidate.kind)
        assertEquals("Drake", r.candidate.artist)
        assertEquals("rem", (resolve("play Rolling in the Deep on PocketDJ") as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun resolver_any_ambiguousSongGoesToBrowse() {
        assertEquals(MediaSearchResult.Browse("hello"), resolve("hello"))
    }

    @Test
    fun resolver_any_collectionBeatsSong() {
        val pocket = MediaCandidate(MediaCandidate.Kind.Pocket, "p", "Hello")
        val r = MediaSearchResolver.resolve(MediaSearchRequest("hello"), { rows }) { k -> listOf(pocket).filter { it.kind in k } }
        assertEquals("p", (r as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun resolver_any_shuffleKeywordKept() {
        val r = resolve("shuffle make me proud by drake") as MediaSearchResult.Play
        assertTrue(r.shuffle)
        assertEquals("mmp", r.candidate.id)
    }

    @Test
    fun resolver_songFocus_structuredTitleAndArtist() {
        val r = resolve("whatever", MediaFocus.Song, title = "Hello", artist = "Lionel Richie") as MediaSearchResult.Play
        assertEquals("hello2", r.candidate.id)
    }

    @Test
    fun resolver_rapDoesNotMatchRainyAfternoonPop_andFallsToBrowse() {
        val pl = MediaCandidate(MediaCandidate.Kind.Playlist, "x", "Rainy Afternoon Pop")
        val r = MediaSearchResolver.resolve(MediaSearchRequest("rap"), { emptyList() }) { k -> listOf(pl).filter { it.kind in k } }
        assertEquals(MediaSearchResult.Browse("rap"), r)
    }

    @Test
    fun resolver_lastPlayedBreaksExactTies() {
        val a = MediaCandidate(MediaCandidate.Kind.Playlist, "old", "Warmup", 1.0)
        val b = MediaCandidate(MediaCandidate.Kind.Pocket, "new", "Warmup", 9.0)
        val r = MediaSearchResolver.resolve(MediaSearchRequest("play warmup on PocketDJ")) { k -> listOf(a, b).filter { it.kind in k } }
        assertEquals("new", (r as MediaSearchResult.Play).candidate.id)
    }

    @Test
    fun cleanSpoken_stripsFiller() {
        assertEquals("warmup", MediaSearchResolver.cleanSpoken("Play warmup on PocketDJ"))
        assertEquals("my warmup pocket", MediaSearchResolver.cleanSpoken("please shuffle my warmup pocket please"))
    }
}
