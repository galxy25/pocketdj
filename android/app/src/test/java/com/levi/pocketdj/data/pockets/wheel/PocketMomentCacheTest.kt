package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningPocketsCollections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class PocketMomentCacheTest {
    @get:Rule val tmp = TemporaryFolder()

    private val tue830 = 1_793_115_000_000.0
    private var n = 0

    private fun play(song: String = "s1", at: Double = tue830, origin: String? = "fav_songs") = PlayEvent(
        id = "e${n++}", songId = song, playedAt = at, source = PlaySource.PLAYLIST, contextId = "set_now_playing",
        tzOffsetMin = -420, carPlay = true, originCollectionId = origin,
    )

    private fun palette() = PocketPaletteStore(File(tmp.root, PocketPaletteStore.FILE_NAME))
    private fun cacheFile() = File(tmp.root, PocketMomentCache.FILE_NAME)

    private fun TestScope.cache(
        file: File = cacheFile(),
        pal: PocketPaletteStore = palette(),
        engine: (PocketMomentEngine.Input) -> PocketWheelSnapshot = PocketMomentEngine::build,
    ): PocketMomentCache {
        val d = StandardTestDispatcher(testScheduler)
        return PocketMomentCache(file, pal, backgroundScope, buildDispatcher = d, ioDispatcher = d, engine = engine).also { c ->
            c.nowMs = { tue830 }
            c.historyEvents = { listOf(play()) }
            c.favoriteIds = { setOf("s1") }
        }
    }

    @Test fun debounceCoalescesBurstsIntoOneBuildAfterFiveSeconds() = runTest {
        val builds = AtomicInteger(0)
        var lastRev = -1
        val c = cache(engine = { builds.incrementAndGet(); lastRev = it.historyRevision; PocketMomentEngine.build(it) })
        var rev = 0
        c.historyRevision = { rev }
        val flow = MutableSharedFlow<Int>()
        c.attach(flow)
        runCurrent()
        rev = 1; flow.emit(1)
        advanceTimeBy(2_000); rev = 2; flow.emit(2)
        advanceTimeBy(2_000); rev = 3; flow.emit(3)
        advanceTimeBy(4_999)
        runCurrent()
        assertEquals("no build before the quiet period elapsed", 0, builds.get())
        advanceTimeBy(2)
        runCurrent()
        assertEquals(1, builds.get())
        assertEquals("the build reads the revision at build time", 3, lastRev)
        assertFalse(c.snapshot.value.isEmpty)
        assertEquals(3, c.snapshot.value.historyRevision)
    }

    @Test fun anUnchangedRevisionDoesNotRebuildAfterAdopt() = runTest {
        val builds = AtomicInteger(0)
        val c = cache(engine = { builds.incrementAndGet(); PocketMomentEngine.build(it) })
        c.historyRevision = { 7 }
        val flow = MutableSharedFlow<Int>()
        c.attach(flow); runCurrent()
        flow.emit(7); advanceTimeBy(5_001); runCurrent()
        assertEquals(1, builds.get())
        flow.emit(7); advanceTimeBy(5_001); runCurrent()
        assertEquals("already built from revision 7", 1, builds.get())
    }

    @Test fun buildRunsOnTheBuildDispatcherNotTheCaller() {
        val exec = Executors.newSingleThreadExecutor { r -> Thread(r, "wheel-build-test") }
        try {
            var engineThread: String? = null
            val c = PocketMomentCache(
                cacheFile(), palette(), kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Job()),
                buildDispatcher = exec.asCoroutineDispatcher(), ioDispatcher = kotlinx.coroutines.Dispatchers.Unconfined,
                engine = { engineThread = Thread.currentThread().name; PocketMomentEngine.build(it) },
            )
            c.nowMs = { tue830 }
            c.historyEvents = { listOf(play()) }
            c.favoriteIds = { setOf("s1") }
            runBlocking { c.rebuildNow() }
            assertTrue(engineThread, engineThread!!.startsWith("wheel-build-test"))
            assertNotEquals(Thread.currentThread().name, engineThread)
            assertFalse(c.snapshot.value.isEmpty)
        } finally { exec.shutdownNow() }
    }

    @Test fun diskCachePaintsTheNextInstanceBeforeAnyRebuild() = runTest {
        val first = cache()
        first.rebuildNow(); advanceUntilIdle()
        assertTrue("cache file written", cacheFile().exists())
        val painted = first.snapshot.value
        assertFalse(painted.isEmpty)

        val second = cache(pal = PocketPaletteStore(File(tmp.root, "other-palette.json")))
        assertEquals("instant paint from disk", painted, second.snapshot.value)
        assertEquals(0, second.revision)
    }

    @Test fun iosShapedCacheJsonWithoutNewerFieldsStillDecodes() = runTest {
        cacheFile().writeText("""{"schemaVersion":1,"builtAtMs":5,"historyRevision":3,"moments":[],"unknownFutureKey":1}""")
        val c = cache()
        assertEquals(5.0, c.snapshot.value.builtAtMs, 0.0)
        assertEquals(3, c.snapshot.value.historyRevision)
    }

    @Test fun corruptCacheFileFallsBackToAnEmptyWheel() = runTest {
        cacheFile().writeText("{not json")
        assertTrue(cache().snapshot.value.isEmpty)
    }

    @Test fun clearLocalDropsSnapshotAndFile() = runTest {
        val c = cache()
        c.rebuildNow(); advanceUntilIdle()
        assertTrue(cacheFile().exists())
        val before = c.revision
        c.clearLocal()
        assertTrue(c.snapshot.value.isEmpty)
        assertFalse(cacheFile().exists())
        assertTrue(c.revision > before)
    }

    @Test fun aBuildInFlightWhenClearedNeverResurrectsTheWheel() = runTest {
        val gate = CompletableDeferred<Unit>()
        val c = cache()
        c.timbreVectors = { gate.await(); emptyMap() }
        val j = launch { c.rebuildNow() }
        runCurrent()
        assertTrue(c.isBuilding.value)
        c.clearLocal()
        gate.complete(Unit)
        advanceUntilIdle()
        assertTrue(c.snapshot.value.isEmpty)
        assertFalse("cache file resurrected", cacheFile().exists())
        assertFalse("still building job=$j", c.isBuilding.value)
    }

    @Test fun anEmptyBuildLeavesNoCacheFile() = runTest {
        val c = cache()
        c.rebuildNow(); advanceUntilIdle()
        assertTrue(cacheFile().exists())
        c.historyEvents = { emptyList() }
        c.rebuildNow(); advanceUntilIdle()
        assertFalse("history deleted: nothing to paint next launch", cacheFile().exists())
    }

    @Test fun deletedCollectionsFreeTheirPaletteSlotsButFavoritesStay() = runTest {
        val pal = palette()
        pal.assign(listOf("gone", PocketPaletteStore.FAV_SONGS_ID, "kept"), nowMs = tue830)
        assertNotNull(pal.slot("gone"))
        val c = cache(pal = pal)
        c.liveCollectionIds = { setOf("kept") }
        c.rebuildNow(); advanceUntilIdle()
        assertNull("deleted collection's slot freed at once", pal.slot("gone"))
        assertNotNull(pal.slot(PocketPaletteStore.FAV_SONGS_ID))
        assertNotNull(pal.slot("kept"))
    }

    @Test fun unknownLiveCollectionsFreeNothing() = runTest {
        val pal = palette()
        pal.assign(listOf("c1"), nowMs = tue830)
        val c = cache(pal = pal)
        c.liveCollectionIds = { null } // catalog not loaded yet
        c.rebuildNow(); advanceUntilIdle()
        assertNotNull(pal.slot("c1"))
    }

    @Test fun rebuildFoldsDominantCollectionsIntoThePalette() = runTest {
        val pal = palette()
        val c = cache(pal = pal)
        c.rebuildNow(); advanceUntilIdle()
        assertEquals(listOf(PocketPaletteStore.FAV_SONGS_ID), c.snapshot.value.dominanceOrder)
        assertNotNull(pal.slot(PocketPaletteStore.FAV_SONGS_ID))
    }

    @Test fun demoSeedPinsTheWheelAgainstAutoRebuilds() = runTest {
        val builds = AtomicInteger(0)
        val c = cache(engine = { builds.incrementAndGet(); PocketMomentEngine.build(it) })
        c.seedDemo(PocketWheelSnapshot(builtAtMs = 1.0, historyRevision = 9, dominanceOrder = emptyList()))
        val flow = MutableSharedFlow<Int>()
        c.attach(flow); runCurrent()
        flow.emit(1); advanceTimeBy(6_000); runCurrent()
        assertEquals(0, builds.get())
        assertEquals(9, c.snapshot.value.historyRevision)
    }

    // makeInput (pure)

    @Test fun makeInputAddsFavoritesPseudoCollectionAndOnlyPlayedSongs() {
        val songs = mapOf(
            "s1" to IndexSong(id = "s1", albumId = "a1", artist = "Artist", name = "One", bpm = 120.0, year = 1999),
            "s2" to IndexSong(id = "s2", albumId = "a1", artist = "Other", name = "Two"),
        )
        val albums = mapOf("a1" to IndexAlbum(id = "a1", artist = "Artist", name = "Alb", genre = "Hip Hop"))
        val input = PocketMomentCache.makeInput(
            events = listOf(play("s1")), songs = songs, albums = albums,
            collections = ListeningPocketsCollections.Input(), favorites = setOf("s1", "s2"),
            setlistToPlaylist = mapOf("set1" to "pl1"), timbre = mapOf("s1" to mapOf("x" to 1.0)),
            cloudPatterns = emptyList(), nowMs = tue830, revision = 4,
        )
        assertEquals(setOf("s1"), input.songs.keys)
        val s = input.songs.getValue("s1")
        assertEquals("hip-hop", s.genre)
        assertEquals(120.0, s.bpm!!, 0.0)
        assertEquals(1999, s.year)
        assertEquals(mapOf("x" to 1.0), s.timbre)
        val fav = input.collections.single { it.id == PocketWheelIds.FAVORITES }
        assertEquals(setOf("s1", "s2"), fav.songIds)
        assertEquals(PocketWheelIds.FAVORITES_NAME, input.extraNames[PocketWheelIds.FAVORITES])
        assertEquals(2, input.librarySize)
        assertEquals(4, input.historyRevision)
        assertEquals(mapOf("set1" to "pl1"), input.setlistToPlaylist)
    }

    @Test fun makeInputOmitsFavoritesWhenNoneAndMapsUnknownGenreToNull() {
        val songs = mapOf("s1" to IndexSong(id = "s1", albumId = "a1", artist = "A", name = "N"))
        val albums = mapOf("a1" to IndexAlbum(id = "a1", artist = "A", name = "Alb", genre = "zzz-unmappable"))
        val input = PocketMomentCache.makeInput(
            listOf(play("s1")), songs, albums, ListeningPocketsCollections.Input(), emptySet(),
            emptyMap(), emptyMap(), emptyList(), tue830, 0,
        )
        assertTrue(input.collections.none { it.id == PocketWheelIds.FAVORITES })
        assertNull(input.songs.getValue("s1").genre)
    }
}
