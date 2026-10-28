package com.levi.pocketdj.data.stems

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.*
import org.junit.Test

class StemClientTest {
    private fun decode(phase: String) = PdjJson.lenient.decodeFromString<StemJob>("""{"phase":"$phase","jobId":"j1","extra":{"a":1}}""")

    @Test fun decodesAllSixPhasesAndIgnoresUnknownFields() {
        val expected = mapOf(
            "queued" to StemPhase.QUEUED, "ripping" to StemPhase.RIPPING, "stemming" to StemPhase.STEMMING,
            "ready" to StemPhase.READY, "error" to StemPhase.ERROR, "ineligible" to StemPhase.INELIGIBLE,
        )
        for ((s, p) in expected) assertEquals(p, decode(s).phase)
        assertEquals("j1", decode("queued").jobId)
    }

    @Test fun customJobCarriesStemKeys() {
        val j = PdjJson.lenient.decodeFromString<StemJob>("""{"phase":"ready","stems":{"vocals":"k/v.mp3"},"stemFormat":"mp3"}""")
        assertEquals("k/v.mp3", j.stems?.get("vocals")); assertEquals("mp3", j.stemFormat)
    }

    @Test fun shouldRequestHonoursThreeLayersFenceAndServer() {
        fun go(id: String = "alb_1", stemmed: Boolean = false, phase: StemPhase? = null, requesting: Boolean = false, server: Boolean = true) =
            StemClient.shouldRequest(id, stemmed, phase, requesting, server)
        assertTrue(go())
        assertFalse(go(stemmed = true))
        for (p in listOf(StemPhase.QUEUED, StemPhase.RIPPING, StemPhase.STEMMING)) assertFalse(go(phase = p))
        // a finished/failed job may be re-requested
        assertTrue(go(phase = StemPhase.ERROR)); assertTrue(go(phase = StemPhase.READY))
        assertFalse(go(requesting = true))
        assertFalse(go(server = false))
        assertFalse(go(id = "lp_abc")); assertFalse(go(id = "pdj_x"))
    }

    @Test fun summaryMatchesIos() {
        assertEquals("Nothing to stemify.", StemClient.summary(BatchStemResult()))
        val r = BatchStemResult(ready = 2, queued = 3, ripping = 1, ineligible = 1, unknown = 1)
        assertEquals(
            "2 already stemmed · 1 ripping first · 3 stemming — completes over time · 1 can’t be stemmed · 1 unknown",
            StemClient.summary(r),
        )
        assertEquals("stemming — 1 of 3 done", StemClient.progressLabel(1, 3))
        assertNull(StemClient.progressLabel(3, 3)); assertEquals("Stemmed 3 of 3", StemClient.progressSummary(3, 3))
    }

    @Test fun labelsAndBatchStatus() {
        assertEquals("Queued…", StemClient.phaseLabel(StemPhase.QUEUED))
        assertEquals("Stemming…", StemClient.phaseLabel(StemPhase.STEMMING))
        assertNull(StemClient.phaseLabel(StemPhase.READY)); assertNull(StemClient.phaseLabel(null))
        assertEquals("ripping", StemClient.batchStatus(StemPhase.RIPPING))
        assertEquals("unknown", StemClient.batchStatus(null))
        assertTrue(StemClient.isTerminal(StemPhase.INELIGIBLE)); assertFalse(StemClient.isTerminal(StemPhase.STEMMING))
    }
}
