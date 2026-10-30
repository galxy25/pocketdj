package com.levi.pocketdj.playback

import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PresignCache
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackUrlResolverTest {
    private val direct = PlayAction.Stream("https://bucket/a.mp3")

    @Test
    fun configured_usesPresignedUrl() = runTest {
        val cache = PresignCache(backgroundScope, { true }, { id, _ -> "https://signed/$id" })
        assertEquals("https://signed/a", PlaybackUrlResolver(cache).resolve("a", direct, true).url)
    }

    @Test
    fun unconfigured_usesDirectUrl_andNeverPresigns() = runTest {
        var calls = 0
        val cache = PresignCache(backgroundScope, { true }, { id, _ -> calls++; "https://signed/$id" })
        assertEquals(direct.url, PlaybackUrlResolver(cache).resolve("a", direct, false).url)
        assertEquals(0, calls)
        assertEquals(direct.url, PlaybackUrlResolver(null).resolve("a", direct, true).url)
    }

    @Test
    fun presignFailure_fallsBackToDirect() = runTest {
        val cache = PresignCache(backgroundScope, { true }, { _, _ -> error("down") })
        assertEquals(direct.url, PlaybackUrlResolver(cache).resolve("a", direct, true).url)
    }

    @Test
    fun prefetch_doesNotBlock_andOnlyRunsWhenConfigured() = runTest {
        val gate = CompletableDeferred<Unit>()
        val minted = mutableListOf<String>()
        val cache = PresignCache(backgroundScope, { true }, { id, _ -> minted += id; gate.await(); "u-$id" })
        val resolver = PlaybackUrlResolver(cache)
        resolver.prefetch(listOf("b", "c"), serverConfigured = false)
        runCurrent()
        assertTrue(minted.isEmpty())
        resolver.prefetch(listOf("b", "c"), serverConfigured = true) // returns while mints hang
        runCurrent()
        assertEquals(listOf("b", "c"), minted)
        gate.complete(Unit)
    }

    @Test
    fun aheadIndices_isBoundedByQueueEnd() {
        assertEquals(1..3, PlaybackUrlResolver.aheadIndices(0, 20))
        assertEquals(18..19, PlaybackUrlResolver.aheadIndices(17, 20))
        assertTrue(PlaybackUrlResolver.aheadIndices(19, 20).isEmpty())
    }

    @Test
    fun localItems_areNeverRefreshedToNetworkUrls() {
        assertTrue(PlaybackUrlResolver.isLocalItemUrl("file:///burn/a.mp3", null))
        assertTrue(PlaybackUrlResolver.isLocalItemUrl(null, "file:///burn/a.mp3"))
        assertTrue(!PlaybackUrlResolver.isLocalItemUrl("https://bucket/a.mp3", "https://bucket/a.mp3"))
        assertTrue(!PlaybackUrlResolver.isLocalItemUrl(null, null))
    }

    @Test
    fun nearEndPrefetch_presignsOnlyANetworkManifestHit() = runTest {
        val minted = mutableListOf<String>()
        val cache = PresignCache(backgroundScope, { true }, { id, _ -> minted += id; "u-$id" })
        val r = PlaybackUrlResolver(cache)
        val net = com.levi.pocketdj.playback.sequencer.StreamSource(direct)
        assertTrue(r.prefetchNextRow("nxt", net, true))
        runCurrent()
        assertEquals(listOf("nxt"), minted)
        assertEquals(false, r.prefetchNextRow("x", net, false))
        assertEquals(false, r.prefetchNextRow("x", com.levi.pocketdj.playback.sequencer.RipOnDemandSource("x"), true))
        assertEquals(false, r.prefetchNextRow("x", null, true))
        runCurrent()
        assertEquals(listOf("nxt"), minted)
    }
}
