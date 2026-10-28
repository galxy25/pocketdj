package com.levi.pocketdj.data.recs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseFeedModelsTest {
    private fun fixture(): String =
        checkNotNull(javaClass.getResourceAsStream("/recs/artists-latest-release.json")).bufferedReader().readText()

    @Test fun wireResponseFlattensIntoEntries() {
        val rows = ArtistsCatalogResponse.parse(fixture(), 42.0)!!
        assertEquals(listOf(1234567, 7654321, 555, 999), rows.map { it.artistId })
        val larry = rows[0]
        assertEquals("Larry June", larry.artistName)
        assertEquals("6786105209", larry.releaseId)
        assertEquals("Who Coppin", larry.releaseName)
        assertEquals(ArtistsCatalogResponse.parseReleaseDate("2026-10-02"), larry.releaseAtMs)
        assertEquals("album", larry.releaseKind)
        assertEquals(12, larry.trackCount)
        assertEquals(true, larry.explicit)
        assertEquals("https://is1-ssl.mzstatic.com/image/{w}x{h}bb.jpg", larry.releaseArtworkUrl)
        // A non-numeric similar id is dropped, not fatal.
        assertEquals(listOf(222, 333), larry.similarArtistIds)
        assertEquals(42.0, larry.similarCheckedAtMs!!, 0.0)
        assertEquals(42.0, larry.checkedAtMs, 0.0)
    }

    @Test fun sparseArtistsDecodeInsteadOfThrowingTheBatchAway() {
        val rows = ArtistsCatalogResponse.parse(fixture(), 1.0)!!
        val north = rows[1]
        assertEquals("single", north.releaseKind)
        assertNull(north.explicit)
        assertNull(north.similarArtistIds) // empty similar view = null, not []
        assertNull(north.similarCheckedAtMs)
        val yearOnly = rows[2]
        assertEquals("compilation", yearOnly.releaseKind)
        assertNull("a bare year is not a usable timestamp", yearOnly.releaseAtMs)
        val none = rows[3]
        assertNull(none.releaseId)
        assertNull(none.releaseKind)
        assertEquals("No Views", none.artistName)
    }

    @Test fun errorEnvelopeIsNotAGoodAnswer() {
        assertNull(ArtistsCatalogResponse.parse("""{"errors":[{"status":"400"}]}""", 1.0))
        assertNull(ArtistsCatalogResponse.parse("not json", 1.0))
        assertEquals(emptyList<ArtistReleaseEntry>(), ArtistsCatalogResponse.parse("""{"data":[]}""", 1.0))
    }

    @Test fun feedbackIdPrefersTheReleaseThenTheArtist() {
        val e = ArtistReleaseEntry(artistId = 7, releaseId = "42")
        assertEquals("rel:42", ReleaseFeedItem(e, ReleaseStatus.OUT_NOW).feedbackId)
        assertEquals("relartist:7", ReleaseFeedItem(e.copy(releaseId = null), ReleaseStatus.OUT_NOW).feedbackId)
    }

    @Test fun documentRoundTripsAndDecodesIosShape() {
        val doc = ReleaseFeedDocument(
            entries = listOf(ArtistReleaseEntry(1, "A", 10.0, "r", "N", 20.0, "u", "album", 3, true, listOf(2, 3), 11.0)),
            seededAtMs = 99.0,
        )
        val text = ReleaseFeedDocumentCodec.encode(doc)
        assertEquals(doc, ReleaseFeedDocumentCodec.decode(text))
        // The iOS-written document: nil fields omitted, no seededAtMs (pre-seed install), unknown key ignored.
        val ios = """{"schemaVersion":1,"extra":true,"entries":[
            {"artistId":5,"artistName":"X","checkedAtMs":1.5e12,"releaseId":"9","releaseAtMs":1.7e12},
            {"artistName":"broken row without an id"}
        ]}"""
        val decoded = ReleaseFeedDocumentCodec.decode(ios)!!
        assertEquals(1, decoded.entries.size) // the bad row is dropped, the good one kept
        assertEquals(5, decoded.entries[0].artistId)
        assertNull(decoded.entries[0].releaseName)
        assertNull("a pre-seed document reads as never seeded", decoded.seededAtMs)
        assertNull(ReleaseFeedDocumentCodec.decode("garbage"))
    }

    @Test fun artistIdResolutionWholeCreditThenPieces() {
        val ids = mapOf("larry june" to 1, "curren\$y" to 2, "the alchemist" to 3)
        assertEquals(1, ReleaseFeedWiring.resolveArtistId("Larry  June", ids))
        assertEquals(2, ReleaseFeedWiring.resolveArtistId("Curren\$y & Larry June", ids)) // first piece wins
        assertEquals(3, ReleaseFeedWiring.resolveArtistId("Unknown feat. The Alchemist", ids))
        assertNull(ReleaseFeedWiring.resolveArtistId("Nobody", ids))
        assertNull(ReleaseFeedWiring.resolveArtistId("", ids))
    }

    @Test fun newEventsStartOnlyCountsAppendsAfterTheSeenOne() {
        val ids = listOf("a", "b", "c")
        assertEquals(0, ReleaseFeedWiring.newEventsStart(ids, null))
        assertEquals(1, ReleaseFeedWiring.newEventsStart(ids, "a"))
        assertEquals(3, ReleaseFeedWiring.newEventsStart(ids, "c"))
        assertEquals("a synced rewrite is not a play", 3, ReleaseFeedWiring.newEventsStart(ids, "gone"))
        assertFalse(ReleaseFeedWiring.newEventsStart(ids, "b") == 0)
    }

    @Test fun emptyReasonTileNotes() {
        assertEquals("Checking for new releases…", ReleaseEmptyReason.Checking.tileNote)
        assertEquals("Apple Music isn’t connected", ReleaseEmptyReason.NotAuthorized.tileNote)
        assertEquals("Couldn’t reach Apple Music", ReleaseEmptyReason.Unreachable("x").tileNote)
        assertEquals("Play something to start checking", ReleaseEmptyReason.NotCheckedYet.tileNote)
        assertNull(ReleaseEmptyReason.NothingNew.tileNote)
    }

    @Test fun transportErrorRetryability() {
        assertTrue(ReleaseFeedTransportError.Http(429).isRetryable)
        assertTrue(ReleaseFeedTransportError.Http(500).isRetryable)
        assertTrue(ReleaseFeedTransportError.Http(503).isRetryable)
        assertFalse(ReleaseFeedTransportError.Http(400).isRetryable)
        assertFalse(ReleaseFeedTransportError.Http(401).isRetryable)
        assertFalse(ReleaseFeedTransportError.Http(403).isRetryable)
        assertFalse(ReleaseFeedTransportError.Http(404).isRetryable)
        assertFalse(ReleaseFeedTransportError.Unavailable().isRetryable)
    }
}
