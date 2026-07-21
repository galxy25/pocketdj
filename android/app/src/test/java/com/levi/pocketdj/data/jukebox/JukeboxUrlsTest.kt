package com.levi.pocketdj.data.jukebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The broker URL contract (specs/jukebox.md §2.1): session routes always carry
 * a leading `/jukebox` segment on top of the configured base — direct AND
 * behind a Funnel path mount — because the server strips exactly one leading
 * `/jukebox` before dispatch. Never double-strip, never special-case the base.
 */
class JukeboxUrlsTest {

    private val funneled = "https://levis-imac.tail2e2bdf.ts.net:8443/jukebox"
    private val direct = "http://192.168.1.20:8788"

    @Test
    fun create_appendsJukeboxSegment_onDirectBase() {
        assertEquals(
            "http://192.168.1.20:8788/jukebox",
            JukeboxUrls.create(direct).toString(),
        )
    }

    @Test
    fun create_onFunneledBase_keepsBothJukeboxSegments() {
        // The server strips ONE leading /jukebox, so /jukebox/jukebox is correct.
        assertEquals(
            "https://levis-imac.tail2e2bdf.ts.net:8443/jukebox/jukebox",
            JukeboxUrls.create(funneled).toString(),
        )
    }

    @Test
    fun base_trimsWhitespaceAndOneTrailingSlash() {
        assertEquals(
            "http://192.168.1.20:8788/jukebox",
            JukeboxUrls.create("  $direct/  ").toString(),
        )
    }

    @Test
    fun health_hasNoSessionPrefix() {
        assertEquals("http://192.168.1.20:8788/health", JukeboxUrls.health(direct).toString())
        assertEquals(
            "https://levis-imac.tail2e2bdf.ts.net:8443/jukebox/health",
            JukeboxUrls.health(funneled).toString(),
        )
    }

    @Test
    fun sessionRoutes_buildStateRequestsDecisionEnd() {
        assertEquals(
            "http://192.168.1.20:8788/jukebox/ab2cd3ef/state",
            JukeboxUrls.state(direct, "ab2cd3ef").toString(),
        )
        assertEquals(
            "http://192.168.1.20:8788/jukebox/ab2cd3ef/requests?since=42",
            JukeboxUrls.requests(direct, "ab2cd3ef", 42).toString(),
        )
        assertEquals(
            "http://192.168.1.20:8788/jukebox/ab2cd3ef/requests/rq_1a2b3c/decision",
            JukeboxUrls.decision(direct, "ab2cd3ef", "rq_1a2b3c").toString(),
        )
        assertEquals(
            "http://192.168.1.20:8788/jukebox/ab2cd3ef/end",
            JukeboxUrls.end(direct, "ab2cd3ef").toString(),
        )
    }

    @Test
    fun funneledSessionRoute_carriesBasePathPlusJukeboxSegment() {
        assertEquals(
            "https://levis-imac.tail2e2bdf.ts.net:8443/jukebox/jukebox/ab2cd3ef/requests?since=0",
            JukeboxUrls.requests(funneled, "ab2cd3ef", 0).toString(),
        )
    }

    @Test
    fun pathSegments_arePercentEncoded() {
        assertEquals(
            "http://192.168.1.20:8788/jukebox/weird%20id/state",
            JukeboxUrls.state(direct, "weird id").toString(),
        )
    }

    @Test
    fun invalidOrBlankBase_returnsNull() {
        assertNull(JukeboxUrls.create(""))
        assertNull(JukeboxUrls.create("not a url"))
        assertNull(JukeboxUrls.state("   ", "ab2cd3ef"))
    }
}
