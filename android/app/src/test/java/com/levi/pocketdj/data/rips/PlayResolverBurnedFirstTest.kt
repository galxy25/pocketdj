package com.levi.pocketdj.data.rips

import com.levi.pocketdj.playback.sequencer.LocalFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayResolverBurnedFirstTest {
    private val entry = RipManifestEntry(key = "rips/alb1.mp3", source = "analog", startMs = 5_000, durationMs = 10_000)
    private val local = LocalFile("file:///data/burns/a.mp3", startMs = 5_000, endMs = 15_000)

    @Test fun burnedBeatsManifestAndServer() {
        val a = PlayResolver.resolveBurnedFirst("sng_1", entry, ripServerConfigured = true, local = local)
        a as PlayAction.Stream
        assertEquals("file:///data/burns/a.mp3", a.url)
        assertEquals(5_000L, a.clipStartMs); assertEquals(15_000L, a.clipEndMs)
        assertTrue(PlayResolver.isLocalUrl(a.url))
    }

    @Test fun burnedPlaysWithNoManifestAndNoServer() {
        val a = PlayResolver.resolveBurnedFirst("sng_1", null, ripServerConfigured = false, local = LocalFile("file:///x.mp3"))
        a as PlayAction.Stream
        assertEquals(null, a.clipStartMs); assertEquals(null, a.clipEndMs)
    }

    @Test fun noBurnFallsToOrdinaryLadder() {
        val a = PlayResolver.resolveBurnedFirst("sng_1", entry, true, null)
        a as PlayAction.Stream
        assertEquals(PlayResolver.playableUrl(entry), a.url)
        assertEquals(PlayAction.RipRequired("sng_2"), PlayResolver.resolveBurnedFirst("sng_2", null, true, null))
        assertEquals(
            PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.NO_SERVER_CONFIGURED),
            PlayResolver.resolveBurnedFirst("sng_2", null, false, null),
        )
    }

    @Test fun studioIdsStayMetadataOnlyEvenWithAFile() {
        val a = PlayResolver.resolveBurnedFirst("smp_abc", null, true, local)
        assertEquals(PlayAction.MetadataOnly(PlayAction.MetadataOnly.Reason.STUDIO_LOCAL_ID), a)
    }

    @Test fun remoteUrlIsNotLocal() {
        assertTrue(!PlayResolver.isLocalUrl("https://x/y.mp3"))
    }
}
