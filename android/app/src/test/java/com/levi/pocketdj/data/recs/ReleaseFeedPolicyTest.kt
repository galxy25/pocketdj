package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.history.PlayEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseFeedPolicyTest {
    private val day = 86_400_000.0
    private val now = 1_800_000_000_000.0

    @Test fun popularityIsLogarithmicAndSaturates() {
        assertEquals(0.0, ReleaseFeedPolicy.popularity(0), 0.0)
        assertEquals(0.0, ReleaseFeedPolicy.popularity(-5), 0.0)
        assertEquals(1.0, ReleaseFeedPolicy.popularity(2860), 1e-9)
        assertEquals(1.0, ReleaseFeedPolicy.popularity(1_000_000), 0.0)
        // 1 play is far above zero but a tiny fraction: heavy tail, not linear.
        val one = ReleaseFeedPolicy.popularity(1)
        assertTrue(one > 0.08 && one < 0.10)
        assertTrue(ReleaseFeedPolicy.popularity(100) > ReleaseFeedPolicy.popularity(10))
    }

    @Test fun releaseTtlCurveIsTwoToFourteenDays() {
        assertEquals(14.0, ReleaseFeedPolicy.releaseTtlDays(0), 1e-9)
        // top of the library: 14 * e^-ln7 = 2 exactly
        assertEquals(2.0, ReleaseFeedPolicy.releaseTtlDays(2860), 1e-9)
        assertEquals(2.0, ReleaseFeedPolicy.releaseTtlDays(50_000), 1e-9)
        var prev = Double.MAX_VALUE
        for (plays in listOf(0, 1, 5, 20, 100, 500, 2000, 2860)) {
            val ttl = ReleaseFeedPolicy.releaseTtlDays(plays)
            assertTrue("ttl must not grow with plays ($plays)", ttl <= prev)
            assertTrue(ttl in 2.0..14.0)
            prev = ttl
        }
    }

    @Test fun maxReleaseTtlStaysStrictlyBelowTheWindow() {
        // Raising TTL_max to the window silently reintroduces the never-surfaces hole.
        assertTrue(ReleaseFeedPolicy.MAX_RELEASE_TTL_DAYS < ReleaseFeedPolicy.WINDOW_DAYS)
    }

    @Test fun similarTtlIsFourTimesReleaseTtlClamped() {
        assertEquals(56.0, ReleaseFeedPolicy.similarTtlDays(0), 1e-9)
        // 4 * 2 = 8 -> clamped up to 30
        assertEquals(30.0, ReleaseFeedPolicy.similarTtlDays(2860), 1e-9)
        for (p in listOf(0, 3, 90, 2860)) assertTrue(ReleaseFeedPolicy.similarTtlDays(p) in 30.0..180.0)
    }

    @Test fun isDueAtTheTtlBoundary() {
        assertTrue(ReleaseFeedPolicy.isDue(null, 100, now))
        val ttl = ReleaseFeedPolicy.releaseTtlDays(0) // 14 d
        assertFalse(ReleaseFeedPolicy.isDue(now - 13.9 * day, 0, now))
        assertTrue(ReleaseFeedPolicy.isDue(now - ttl * day, 0, now))
        assertTrue(ReleaseFeedPolicy.isDue(now - 30 * day, 0, now))
        // A heavy artist is due much sooner than a cold one at the same age.
        assertTrue(ReleaseFeedPolicy.isDue(now - 3 * day, 2860, now))
        assertFalse(ReleaseFeedPolicy.isDue(now - 3 * day, 0, now))
    }

    @Test fun classifyOutNowComingSoonAndOutsideWindow() {
        assertEquals(ReleaseStatus.OUT_NOW, ReleaseFeedPolicy.classify(now, now))
        assertEquals(ReleaseStatus.OUT_NOW, ReleaseFeedPolicy.classify(now - 30 * day, now))
        assertNull(ReleaseFeedPolicy.classify(now - 30 * day - 1, now))
        assertEquals(ReleaseStatus.COMING_SOON, ReleaseFeedPolicy.classify(now + 1, now))
        // Coming soon has NO upper bound.
        assertEquals(ReleaseStatus.COMING_SOON, ReleaseFeedPolicy.classify(now + 400 * day, now))
        assertTrue(ReleaseFeedPolicy.isWithinWindow(now + 90 * day, now))
        assertFalse(ReleaseFeedPolicy.isWithinWindow(now - 60 * day, now))
    }

    @Test fun statusAgesAtReadTimeNotStoreTime() {
        val release = now + 3 * day
        assertEquals(ReleaseStatus.COMING_SOON, ReleaseFeedPolicy.classify(release, now))
        assertEquals(ReleaseStatus.OUT_NOW, ReleaseFeedPolicy.classify(release, now + 4 * day))
    }

    @Test fun requestBatchingConstants() {
        assertEquals(50, ReleaseFeedPolicy.IDS_PER_REQUEST)
        assertEquals(2, ReleaseFeedPolicy.MAX_CONCURRENT_REQUESTS)
    }

    private fun ev(id: String, artist: String?, at: Double) = PlayEvent(id = id, songId = "s$id", playedAt = at, artist = artist)

    @Test fun seedIsRecentArtistsMostRecentFirstFoldedAndWindowed() {
        val events = listOf(
            ev("1", "Daft Punk", now - 5 * day),
            ev("2", "Björk", now - 2 * day),
            ev("3", "daft punk", now - 1 * day), // same artist, later: moves to the front, keeps latest display
            ev("4", "Old Timer", now - 31 * day), // outside the window
            ev("5", "  ", now - 1 * day),
            ev("6", null, now - 1 * day),
            ev("7", "BJORK", now - 3 * day), // earlier than #2: ignored, display stays #2's
        )
        assertEquals(listOf("daft punk", "Björk"), ReleaseFeedSeed.recentArtistNames(events, now))
        assertEquals(listOf("daft punk"), ReleaseFeedSeed.recentArtistNames(events, now, limit = 1))
        assertTrue(ReleaseFeedSeed.recentArtistNames(emptyList(), now).isEmpty())
    }

    @Test fun releaseDateParsingIsUtcAndRejectsBareYear() {
        assertEquals(1_759_363_200_000.0, ArtistsCatalogResponse.parseReleaseDate("2025-10-02")!!, 0.0)
        assertNull(ArtistsCatalogResponse.parseReleaseDate("2026"))
        assertNull(ArtistsCatalogResponse.parseReleaseDate(null))
        assertNull(ArtistsCatalogResponse.parseReleaseDate("2026-13-45"))
        assertNull(ArtistsCatalogResponse.parseReleaseDate("abcd-ef-gh"))
        assertNotNull(ArtistsCatalogResponse.parseReleaseDate("2026-02-01T00:00:00Z"))
    }
}
