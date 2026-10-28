package com.levi.pocketdj.data.burns

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnFileNamesTest {
    @Test fun sanitizeStripsIllegalAndSeparatorAndCollapses() {
        assertEquals("AC DC Back In Black", BurnFileNames.sanitizeToken("AC/DC: Back-In  \"Black\"?"))
        assertNull(BurnFileNames.sanitizeToken(null))
        assertNull(BurnFileNames.sanitizeToken(""))
        assertNull(BurnFileNames.sanitizeToken("-/\\:*?"))
        assertEquals("a b", BurnFileNames.sanitizeToken("a\n\tb"))
    }

    @Test fun sanitizeTreatsFormatCharsLikeSwiftControlCharacters() {
        assertEquals("a b", BurnFileNames.sanitizeToken("a\u200Eb"))
        assertEquals("co op", BurnFileNames.sanitizeToken("co\u00ADop"))
        assertEquals("x y", BurnFileNames.sanitizeToken("x\uFEFFy"))
    }

    @Test fun sanitizeCapsTokenAt40() {
        val t = BurnFileNames.sanitizeToken("x".repeat(100))!!
        assertEquals(40, t.length)
    }

    @Test fun sanitizeCountsGraphemesNotUtf16() {
        val t = BurnFileNames.sanitizeToken("🎵".repeat(50))!!
        assertEquals(40, t.codePointCount(0, t.length))
    }

    @Test fun digitalPrefixOrderAndDroppedFields() {
        val s = song("sng_1", artist = "Daft Punk", name = "One More Time", bpm = 99.0)
        val a = album("alb_1", name = "Discovery", genre = "House")
        val e = digital("sng_1", bpm = 122.6, camelot = "11B", key = "F# major")
        assertEquals(
            "Daft Punk-One More Time-Discovery-1999-House-11B-F# major-123",
            BurnFileNames.digitalSongPrefix(s, a, e),
        )
        // missing fields are dropped, never empty tokens
        assertEquals("Daft Punk-One More Time-1999", BurnFileNames.digitalSongPrefix(s.copy(bpm = null), null, null))
    }

    @Test fun analogPrefixIsAlbumLevel() {
        val a = album("alb_1", artist = "Miles Davis", name = "Kind of Blue", genre = "Jazz")
        assertEquals("Miles Davis-Kind of Blue-1999-Jazz", BurnFileNames.analogAlbumPrefix(song("s1", artist = "Other"), a))
    }

    @Test fun analogSongsShareOneAudioNameButHaveOwnSidecars() {
        val a = album("alb_9", artist = "Band", name = "Live")
        val e1 = analog("alb_9", 0)
        val e2 = analog("alb_9", 60_000)
        val n1 = BurnFileNames.fileNames("sng_a", e1, song("sng_a", "Band", "One"), a)
        val n2 = BurnFileNames.fileNames("sng_b", e2, song("sng_b", "Band", "Two"), a)
        assertEquals("Band-Live-1999-Rock-alb_9.mp3", n1.audio)
        assertEquals(n1.audio, n2.audio)
        assertTrue(n1.sidecar.endsWith("-sng_a.txt"))
        assertTrue(n2.sidecar.endsWith("-sng_b.txt"))
    }

    @Test fun idSuffixAndExtensionNeverTruncatedWith300CharMetadata() {
        val long = "z".repeat(300)
        val s = song("sng_abc", artist = long, name = long)
        val a = album("alb_1", name = long, genre = long)
        val n = BurnFileNames.fileNames("sng_abc", digital("sng_abc"), s, a)
        assertTrue(n.audio.endsWith("-sng_abc.mp3"))
        assertTrue(n.sidecar.endsWith("-sng_abc.txt"))
        assertTrue(n.audio.length <= BurnFileNames.PREFIX_CAP + "-sng_abc.mp3".length)
    }

    @Test fun descriptiveNameBlankPrefixAndTrimming() {
        assertEquals("sng_1.mp3", BurnFileNames.descriptiveName("", "sng_1", "mp3"))
        assertEquals("audio.txt", BurnFileNames.descriptiveName(" - ", "", "txt"))
        assertEquals("A-b-id.mp3", BurnFileNames.descriptiveName("A-b-", "id", "mp3"))
    }

    @Test fun idTokenFromKeyBasename() {
        assertEquals("alb_1", BurnFileNames.idToken("rips/alb_1.mp3", "sng_x"))
        assertEquals("sng_9", BurnFileNames.idToken("rips/sub/sng_9.flac", "sng_x"))
        assertEquals("sng_x", BurnFileNames.idToken("", "sng_x"))
    }

    @Test fun stableIdSuffixAndAuxParsing() {
        assertEquals("sng_1", BurnFileNames.stableIdSuffix("A-B-C-sng_1"))
        assertEquals("sng_1", BurnFileNames.stableIdSuffix("sng_1"))
        assertEquals("sng_1", BurnFileNames.auxFileSongId("stem-sng_1-vocals.mp3"))
        assertEquals("sng_1", BurnFileNames.auxFileSongId("analysis-sng_1.json"))
        assertNull(BurnFileNames.auxFileSongId("stem-loop.mp3"))
        assertNull(BurnFileNames.auxFileSongId("stem--drums.mp3"))
        assertTrue(BurnFileNames.isStemFile("stem-sng_1-bass.mp3"))
        assertEquals(false, BurnFileNames.isStemFile("analysis-sng_1.json"))
    }

    @Test fun cutPickExcludesOwnAudioAndMatchesSuffix() {
        val names = listOf("Band-Live-1999-Rock-alb_9.mp3", "Band-One-1999-sng_a.mp3", "sng_a.txt")
        assertEquals("Band-One-1999-sng_a.mp3", BurnFileNames.cutFileNameAmongst(names, "sng_a", "Band-Live-1999-Rock-alb_9.mp3"))
        // a digital per-song file ends -<songId>.mp3 but IS the audio: never a cut
        assertNull(BurnFileNames.cutFileNameAmongst(listOf("X-sng_d.mp3"), "sng_d", "X-sng_d.mp3"))
        assertEquals("sng_a.mp3", BurnFileNames.cutFileNameAmongst(listOf("sng_a.mp3"), "sng_a", "alb.mp3"))
    }
}
