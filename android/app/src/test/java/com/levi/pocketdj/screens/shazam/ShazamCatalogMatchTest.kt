package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import org.junit.Test
import org.junit.Assert.assertEquals

import org.junit.Assert.assertTrue

@Suppress("UNCHECKED_CAST")
private inline fun <reified T> assertIs(v: Any?): T {
    org.junit.Assert.assertTrue("expected ${T::class.simpleName} but was $v", v is T)
    return v as T
}

class ShazamCatalogMatchTest {
    private fun song(id: String, name: String, artist: String) = IndexSong(id = id, artist = artist, name = name)
    private fun hit(t: String?, a: String?) = ShazamHitInfo(t, a, null, null)

    @Test fun normFoldsDiacriticsAndCase() {
        assertEquals("cafe", ShazamCatalogMatch.norm("Café"))
        assertEquals(ShazamCatalogMatch.norm("Café"), ShazamCatalogMatch.norm("CAFE"))
    }

    @Test fun normDropsParenAndBracketTails() {
        assertEquals("song", ShazamCatalogMatch.norm("Song (feat. Someone)"))
        assertEquals("song", ShazamCatalogMatch.norm("Song [Remastered 2011]"))
        assertEquals("cafe", ShazamCatalogMatch.norm("Café (Remastered 2011)"))
    }

    @Test fun normDropsDashEditionClauseButNotPlainDash() {
        assertEquals("song", ShazamCatalogMatch.norm("Song - Remastered 2009"))
        assertEquals("song", ShazamCatalogMatch.norm("Song - Live at Wembley"))
        assertEquals("song title", ShazamCatalogMatch.norm("Song - Title"))
    }

    @Test fun normStripsPunctuationAndCollapsesSpaces() {
        assertEquals("rock n roll", ShazamCatalogMatch.norm("  Rock  'n'   Roll!! "))
        assertEquals("", ShazamCatalogMatch.norm("(only paren)"))
    }

    @Test fun resolveMatchesAcrossEditionNoise() {
        val songs = listOf(song("s1", "Cafe", "Artist"))
        val m = ShazamCatalogMatch.resolve(hit("Café (Remastered 2011)", "Artist"), songs)
        assertEquals("s1", assertIs<ShazamMatch.InCatalog>(m).song.id)
    }

    @Test fun artistContainmentEitherDirection() {
        val songs = listOf(song("s1", "Track", "Artist feat. Guest"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Artist"), songs))
        val songs2 = listOf(song("s2", "Track", "Artist"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Artist & Friends"), songs2))
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit("Track", "Other"), songs2))
    }

    @Test fun noArtistMatchesOnTitleAlone() {
        val songs = listOf(song("s1", "Track", "Anyone"))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", null), songs))
        assertIs<ShazamMatch.InCatalog>(ShazamCatalogMatch.resolve(hit("Track", "  "), songs))
    }

    @Test fun firstHitWinsAndBlankTitleNeverMatches() {
        val songs = listOf(song("a", "Track", "X"), song("b", "Track", "X"))
        assertEquals("a", (ShazamCatalogMatch.resolve(hit("Track", "X"), songs) as ShazamMatch.InCatalog).song.id)
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit(null, "X"), songs))
        assertIs<ShazamMatch.NotInCatalog>(ShazamCatalogMatch.resolve(hit("(...)", "X"), songs))
    }
}
