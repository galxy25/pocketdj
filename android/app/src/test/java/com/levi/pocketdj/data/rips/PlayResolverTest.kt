package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.config.Endpoints
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android P1 play-resolution ladder (specs/playback.md §3), including the
 * no-rip metadata-only case and the studio-id fence.
 */
class PlayResolverTest {

    private val digitalEntry = RipManifestEntry(
        key = "rips/sng_digital00001.mp3",
        source = "digital",
        durationMs = 180_000,
    )

    private val analogEntry = RipManifestEntry(
        key = "rips/alb_aaa111bbb222.mp3",
        source = "analog",
        albumId = "alb_aaa111bbb222",
        startMs = 215_000,
        durationMs = 216_000,
    )

    @Test
    fun digitalEntry_playsPerSongFile_noClipWindow() {
        val action = PlayResolver.resolve("sng_digital00001", digitalEntry, ripServerConfigured = false)
        val stream = action as PlayAction.Stream
        assertEquals("${Endpoints.RIPS_BASE}/rips/sng_digital00001.mp3", stream.url)
        assertNull(stream.clipStartMs)
        assertNull(stream.clipEndMs)
    }

    @Test
    fun analogEntry_clipsToStartPlusDuration_insideSharedAlbumFile() {
        val action = PlayResolver.resolve("sng_000000000002", analogEntry, ripServerConfigured = false)
        val stream = action as PlayAction.Stream
        assertEquals("${Endpoints.RIPS_BASE}/rips/alb_aaa111bbb222.mp3", stream.url)
        assertEquals(215_000L, stream.clipStartMs)
        assertEquals(431_000L, stream.clipEndMs) // startMs + durationMs
    }

    @Test
    fun analogEntry_nullDuration_clipsStartOnly_unboundedWindow() {
        val entry = analogEntry.copy(durationMs = null)
        val stream = PlayResolver.resolve("sng_x", entry, ripServerConfigured = false) as PlayAction.Stream
        assertEquals(215_000L, stream.clipStartMs)
        assertNull(stream.clipEndMs)
        assertTrue(stream.isUnboundedAnalog)
    }

    @Test
    fun noEntry_serverConfigured_requiresRip() {
        val action = PlayResolver.resolve("sng_unripped", null, ripServerConfigured = true)
        assertEquals(PlayAction.RipRequired("sng_unripped"), action)
    }

    @Test
    fun noEntry_noServer_isMetadataOnly() {
        val action = PlayResolver.resolve("sng_unripped", null, ripServerConfigured = false)
        assertEquals(
            PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED),
            action,
        )
    }

    @Test
    fun studioIds_areFenced_evenWithServerAndEntry() {
        for (prefix in PlayResolver.STUDIO_ID_PREFIXES) {
            val action = PlayResolver.resolve("${prefix}local1", digitalEntry, ripServerConfigured = true)
            assertEquals(
                "$prefix must never reach /rip or playback",
                PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.STUDIO_LOCAL_ID),
                action,
            )
        }
        assertEquals(listOf("smp_", "lp_", "ptn_", "tk_"), PlayResolver.STUDIO_ID_PREFIXES)
    }
}
