package com.levi.pocketdj.data.config

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** First-launch defaults must point at the live (green) account, pinned to config/endpoints.green.json. */
class EndpointsGreenPinTest {
    private fun doc(name: String): String =
        listOf("../../config/$name", "../config/$name").map(::File).first { it.exists() }.readText()

    private fun ok(text: String) =
        (EndpointConfig.decode(text) as EndpointConfig.Companion.Decoded.Ok).config

    @Test fun compiledInEqualsGreenJsonOnEveryKey() {
        val green = ok(doc("endpoints.green.json"))
        assertEquals("green", EndpointConfig.COMPILED_IN.env)
        // profileSyncBase + capabilities.profileSyncEnroll are doc-delivered ONLY (ANS-SYNC-1): never compiled in.
        assertEquals(green.endpoints - EndpointKey.PROFILE_SYNC_BASE, EndpointConfig.COMPILED_IN.endpoints)
        assertTrue(green.profileSyncBase != null && green.profileSyncEnroll != null)
        assertEquals(null, EndpointConfig.COMPILED_IN.profileSyncBase)
        for (key in EndpointKey.REQUIRED) {
            assertEquals(key.wire, green.url(key), EndpointConfig.COMPILED_IN.url(key))
        }
    }

    @Test fun compiledInIsNotBlue() {
        val blue = ok(doc("endpoints.blue.json"))
        for (key in EndpointKey.REQUIRED) {
            assertTrue(key.wire, blue.url(key) != EndpointConfig.COMPILED_IN.url(key))
        }
    }

    @Test fun freshResolverServesGreen() {
        RemoteEndpoints.resetForTests()
        assertEquals("https://d1j6qufkowz1xq.cloudfront.net/current-index.json", Endpoints.VINYL_INDEX_URL)
    }

    @Test fun legacyBlueSourceRebasesToGreen() {
        RemoteEndpoints.resetForTests()
        assertEquals("https://d1j6qufkowz1xq.cloudfront.net/apple-music-index.json",
            RemoteEndpoints.rebaseCatalogUrl("https://d2p4cubg6se03u.cloudfront.net/apple-music-index.json"))
        assertEquals("https://d1zb3ydtksjw1r.cloudfront.net/x.json",
            RemoteEndpoints.rebaseCatalogUrl("https://djictbz9w796r.cloudfront.net/x.json"))
    }
}
