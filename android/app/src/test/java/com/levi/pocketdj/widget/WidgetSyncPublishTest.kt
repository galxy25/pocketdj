package com.levi.pocketdj.widget

import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class WidgetSyncPublishTest {
    private val dir = File.createTempFile("wsync", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
    private val store = NowPlayingSnapshotStore(dir)
    private var refreshes = 0
    private val fetched = mutableListOf<CoverKey>()
    private var fetcher = CoverFetcher { fetched += it; byteArrayOf(1, 2, 3) }

    private fun sync(scope: kotlinx.coroutines.CoroutineScope) =
        WidgetSync(scope, kotlinx.coroutines.flow.emptyFlow(), store, { fetcher.fetch(it) }, { refreshes++ })

    private fun song(id: String = "s1", album: String? = "alb1", playing: Boolean = true, pos: Long = 0) =
        WidgetInputs(songId = id, title = "T$id", artist = "A", albumId = album, isPlaying = playing, positionMs = pos,
            favoriteAvailable = true)

    @Test fun publishesOnSongFavoriteAndRepeatChange() = runTest {
        val s = sync(this)
        s.onInputs(song())
        assertEquals("s1", store.read().songId)
        s.onInputs(song().copy(isFavorite = true))
        assertTrue(store.read().isFavorite)
        s.onInputs(song().copy(isFavorite = true, repeatMode = "all"))
        assertEquals("all", store.read().repeatMode)
        s.onInputs(song("s2", "alb2"))
        assertEquals("s2", store.read().songId)
    }

    @Test fun positionTickDoesNotPublish() = runTest {
        val s = sync(this)
        s.onInputs(song(pos = 0))
        val before = refreshes
        val text = File(dir, "nowplaying.json").readText()
        for (p in 1..50L) s.onInputs(song(pos = p * 1000))
        assertEquals(before, refreshes)
        assertEquals(text, File(dir, "nowplaying.json").readText())
    }

    @Test fun coverVersionOnlyBumpsOnCoverIdentityChange() = runTest {
        val s = sync(this)
        s.onInputs(song("s1", "alb1"))
        val v1 = store.read().coverVersion
        assertEquals(1, v1)
        s.onInputs(song("s2", "alb1")) // same album => same cover
        assertEquals(v1, store.read().coverVersion)
        assertEquals(1, fetched.size)
        s.onInputs(song("s3", "alb2"))
        assertEquals(2, store.read().coverVersion)
        assertTrue(store.hasCover())
    }

    @Test fun supersededFetchIsDropped() = runTest {
        val gate = CompletableDeferred<ByteArray?>()
        var calls = 0
        fetcher = CoverFetcher { if (calls++ == 0) gate.await() else byteArrayOf(9) }
        val s = sync(this)
        val first = launch { s.onInputs(song("s1", "alb1")) }
        testScheduler.runCurrent()
        s.onInputs(song("s2", "alb2")) // newer song lands first
        assertEquals(1, store.read().coverVersion)
        gate.complete(byteArrayOf(7, 7, 7))
        first.join()
        assertEquals(listOf<Byte>(9), store.coverFile.readBytes().toList()) // the stale 7s never landed
        assertEquals("s2", store.read().songId)
    }

    @Test fun idleClearsCoverAndShowsEmptyContent() = runTest {
        val s = sync(this)
        s.onInputs(song())
        s.onInputs(WidgetInputs())
        val snap = store.read()
        assertFalse(snap.hasContent); assertFalse(snap.isPlaying)
        assertFalse(store.hasCover())
    }

    @Test fun heartHiddenWithoutSeamAndUpNextCapped() = runTest {
        val s = sync(this)
        val tracks = (1..9).map { NowPlayingSnapshot.Track("u$it", "x$it", "t", "a") }
        s.onInputs(song().copy(favoriteAvailable = false, isFavorite = true, upNext = tracks))
        val snap = store.read()
        assertFalse(snap.favoriteAvailable); assertFalse(snap.isFavorite)
        assertEquals(4, snap.upNext.size)
        assertEquals("", snap.recScope)
    }
}
