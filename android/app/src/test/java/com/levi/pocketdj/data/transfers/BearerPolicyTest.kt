package com.levi.pocketdj.data.transfers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The 2026-09-01 poisoned-burns regression predicate. */
class BearerPolicyTest {
    private val ripsHost = "rips.pocket-dj.com"

    @Test fun presignedUrlNeverGetsBearer() {
        assertFalse(BearerPolicy.shouldAttachBearer("https://x.example/a.mp3?X-Amz-Signature=abc&X-Amz-Expires=1", "tok", ripsHost))
    }

    @Test fun amazonawsHostNeverGetsBearer() {
        assertFalse(BearerPolicy.shouldAttachBearer("https://bucket.s3.us-west-2.amazonaws.com/rips/a.mp3", "tok", ripsHost))
    }

    @Test fun ripsBaseHostNeverGetsBearerCaseInsensitive() {
        assertFalse(BearerPolicy.shouldAttachBearer("https://RIPS.pocket-dj.com/rips/a.mp3", "tok", ripsHost))
    }

    @Test fun ripServerGetsBearer() {
        assertTrue(BearerPolicy.shouldAttachBearer("http://imac.tailnet.ts.net:8787/audio/a.mp3", "tok", ripsHost))
    }

    @Test fun emptyTokenNeverAttaches() {
        assertFalse(BearerPolicy.shouldAttachBearer("http://imac.tailnet.ts.net:8787/a.mp3", "", ripsHost))
    }

    @Test fun nullRipsHostStillAllowsRipServer() {
        assertTrue(BearerPolicy.shouldAttachBearer("http://10.0.0.5:8787/a.mp3", "tok", null))
    }

    @Test fun hostOfParsesBase() {
        assertEquals("rips.pocket-dj.com", BearerPolicy.hostOf("https://rips.pocket-dj.com/"))
        assertEquals(null, BearerPolicy.hostOf("not a url"))
    }
}
