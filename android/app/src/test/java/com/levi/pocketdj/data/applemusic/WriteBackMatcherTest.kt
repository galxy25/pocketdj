package com.levi.pocketdj.data.applemusic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WriteBackMatcherTest {
    private fun cand(id: String, title: String, artist: String, album: String? = null, sec: Double? = null) =
        WriteBackCatalogCandidate(id, title, artist, album, sec)

    private fun song(title: String, artist: String, album: String? = null, ms: Int? = null) =
        WriteBackSong("", title, artist, album, ms)

    // ---- matchKey ----
    @Test fun matchKey_foldsCaseDiacriticsAndPunctuation() {
        assertEquals("beyonce", WriteBackMatcher.matchKey("Beyoncé", keepVersion = true))
        assertEquals("rocknroll", WriteBackMatcher.matchKey("Rock 'n' Roll!", keepVersion = true))
    }

    @Test fun matchKey_looseKeyDropsParentheticalAndBracketed() {
        assertEquals("song", WriteBackMatcher.matchKey("Song (feat. X) [Remastered]", keepVersion = false))
        assertEquals("songfeatxremastered", WriteBackMatcher.matchKey("Song (feat. X) [Remastered]", keepVersion = true))
    }

    @Test fun matchKey_unbalancedOpenDropsTail() {
        assertEquals("song", WriteBackMatcher.matchKey("Song (live at", keepVersion = false))
    }

    // ---- bestMatch ----
    @Test fun exactTitleArtistMatches() {
        assertEquals("1", WriteBackMatcher.bestMatch(song("Halo", "Beyoncé"), listOf(cand("1", "Halo", "Beyoncé"))))
    }

    @Test fun titleOnlyWithDifferentArtistIsRejected() {
        assertNull(WriteBackMatcher.bestMatch(song("Halo", "Beyoncé"), listOf(cand("1", "Halo", "Someone Else"))))
    }

    @Test fun userVersionMarkerNeverFallsBackToBaseMaster() {
        val c = listOf(cand("base", "Fearless", "Taylor Swift"))
        assertNull(WriteBackMatcher.bestMatch(song("Fearless (Taylor's Version)", "Taylor Swift"), c))
        val both = c + cand("tv", "Fearless (Taylor's Version)", "Taylor Swift")
        assertEquals("tv", WriteBackMatcher.bestMatch(song("Fearless (Taylor's Version)", "Taylor Swift"), both))
    }

    @Test fun unwantedVariantNeedsDurationOrAlbumNotJustArtist() {
        val live = cand("live", "Song (Live)", "Band", sec = 300.0)
        // No duration/album on our side: artist match alone cannot admit a live variant.
        assertNull(WriteBackMatcher.bestMatch(song("Song", "Band"), listOf(live)))
        // Duration corroborates (within 4 s) -> admitted.
        assertEquals("live", WriteBackMatcher.bestMatch(song("Song", "Band", ms = 301_000), listOf(live)))
    }

    @Test fun durationMoreThan12SecApartRejectsOutright() {
        assertNull(WriteBackMatcher.bestMatch(song("Song", "Band", ms = 200_000), listOf(cand("1", "Song", "Band", sec = 230.0))))
        assertEquals("1", WriteBackMatcher.bestMatch(song("Song", "Band", ms = 200_000), listOf(cand("1", "Song", "Band", sec = 208.0))))
    }

    @Test fun higherScoreWinsAlbumAndDuration() {
        val a = cand("a", "Song", "Band", album = "Other", sec = 200.0)
        val b = cand("b", "Song", "Band", album = "Right", sec = 200.0)
        assertEquals("b", WriteBackMatcher.bestMatch(song("Song", "Band", album = "Right", ms = 200_000), listOf(a, b)))
    }

    @Test fun ambiguousAcrossDistinctArtistsAtTopScoreRefuses() {
        // Both contain the wanted artist token and tie on score -> refuse to guess.
        val c = listOf(cand("1", "Song", "Band Alpha", sec = 200.0), cand("2", "Song", "Band Beta", sec = 200.0))
        assertNull(WriteBackMatcher.bestMatch(song("Song", "Band", ms = 200_000), c))
    }

    @Test fun sameArtistEditionsPickDeterministicMinId_inEitherOrder() {
        val x = cand("900", "Song", "Band")
        val y = cand("100", "Song", "Band")
        assertEquals("100", WriteBackMatcher.bestMatch(song("Song", "Band"), listOf(x, y)))
        assertEquals("100", WriteBackMatcher.bestMatch(song("Song", "Band"), listOf(y, x)))
    }

    @Test fun blankTitleOrArtistYieldsNothing() {
        assertNull(WriteBackMatcher.bestMatch(song("", "Band"), listOf(cand("1", "Song", "Band"))))
        assertNull(WriteBackMatcher.bestMatch(song("Song", "  "), listOf(cand("1", "Song", "Band"))))
    }
}
