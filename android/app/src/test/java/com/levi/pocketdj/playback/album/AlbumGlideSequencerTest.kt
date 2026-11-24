package com.levi.pocketdj.playback.album

import com.levi.pocketdj.data.rips.AlbumFileTimeline
import com.levi.pocketdj.data.rips.AlbumFileTimeline.Segment
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.playback.sequencer.AlbumFileState
import com.levi.pocketdj.playback.sequencer.FakePlayerPort
import com.levi.pocketdj.playback.sequencer.PlayRequest
import com.levi.pocketdj.playback.sequencer.PlayerPort
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.RowSource
import com.levi.pocketdj.playback.sequencer.RowSourceResolver
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StreamSource
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlayStarted
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of iOS SetlistPlayerTests 939-1160 (the album glide / run / skip / lead-in tests) onto the Android engine seam:
 * the engine holds ONE run item, the boundary is armed, and the sequencer moves the deck's identity in place.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AlbumGlideSequencerTest {
    /** A port that behaves like the Media3 engine for a run item: remembers what was loaded, armed, sought, retitled. */
    private class RunPort(val base: FakePlayerPort = FakePlayerPort()) : PlayerPort by base {
        val loads = mutableListOf<PlayRequest>()
        val calls = mutableListOf<String>()
        val retargets = mutableListOf<Pair<String, Boolean>>()
        val seeks = mutableListOf<Long>()
        var armed: Triple<String, Long?, Long>? = null
        var mediaId: String? = null
        var clipStart = 0L
        var fileMs = 0L
        var playing = true
        var isRun = false
        var retargetOk = true

        override suspend fun load(request: PlayRequest) {
            loads += request
            calls += "load ${request.item.id}"
            mediaId = request.item.id
            val plan = request.albumRun
            isRun = plan != null
            clipStart = plan?.clipStartMs ?: ((request.source as? StreamSource)?.action?.clipStartMs ?: 0L)
            fileMs = clipStart
            armBoundary(request.item.id, plan?.boundaryFileMs, clipStart)
        }

        override suspend fun replay(songId: String): Boolean = false
        override fun armBoundary(songId: String, fileMs: Long?, clipStartMs: Long) {
            calls += "arm $songId $fileMs"
            armed = Triple(songId, fileMs, clipStartMs)
        }
        override fun albumFileState(): AlbumFileState? =
            if (isRun && mediaId != null) AlbumFileState(mediaId!!, clipStart, fileMs, playing) else null
        override fun seekInFile(fileMs: Long): Boolean {
            if (!isRun || fileMs < clipStart) return false
            calls += "seek $fileMs"
            seeks += fileMs
            this.fileMs = fileMs
            return true
        }
        override suspend fun retargetInPlace(item: QueueItem, startPlayback: Boolean): Boolean {
            calls += "retarget ${item.id}"
            if (!retargetOk) return false
            retargets += item.id to startPlayback
            mediaId = item.id
            if (startPlayback) playing = true
            return true
        }
        override suspend fun pause() { calls += "pause"; playing = false }
    }

    /** id -> window start in the shared file (every row streams `rips/side.mp3`). */
    private class SideResolver(val starts: Map<String, Long>) : RowSourceResolver {
        override val id = "side"
        override val rung = Rung.MANIFEST
        override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
            starts[item.id]?.let { StreamSource(PlayAction.Stream("https://rips/side.mp3", it, it + 100_000)) }
    }

    private class Rig(
        val port: RunPort,
        val seq: SetlistSequencer,
        val player: AlbumRunPlayer,
        val settle: () -> Unit,
        val logs: MutableList<String>,
    ) {
        var declines = false
    }

    private fun TestScope.rig(
        starts: Map<String, Long>,
        detectedEnd: Map<String, Long> = emptyMap(),
        declines: () -> Boolean = { false },
    ): Rig {
        val port = RunPort()
        val logs = mutableListOf<String>()
        val seq = SetlistSequencer(
            scope = backgroundScope,
            port = port,
            registry = RowResolverRegistry(listOf(SideResolver(starts))),
            log = { logs += it },
        )
        val tl = AlbumFileTimeline("rips/side.mp3", starts.map { Segment(it.key, it.value) }, detectedEndMs = detectedEnd)
        val source = AlbumTimelineSource { id -> tl.takeIf { t -> t.segment(com.levi.pocketdj.data.edition.SongVariant.baseId(id)) != null } }
        seq.albumTimelines = source
        val player = AlbumRunPlayer(seq, port, source, backgroundScope, declines = declines, log = { logs += it })
        seq.addAdvanceInterceptor(player)
        seq.addStartInterceptor(player)
        return Rig(port, seq, player, { runCurrent() }, logs)
    }

    private fun rows(vararg specs: Pair<String, Long>) = specs.map { QueueItem(id = it.first, title = it.first, lengthMs = it.second) }

    @Test fun analogSideGlidesAtTheNextSongsStartWithoutReloading() = runTest {
        val r = rig(mapOf("gl_1" to 0L, "gl_2" to 180_000L))
        r.seq.play(rows("gl_1" to 150_000, "gl_2" to 120_000)); r.settle()
        // The catalog length (2:30) is NOT the end: the record's next song (3:00) is.
        assertEquals(180_000L, r.port.armed!!.second)
        assertNull("one item: no clip end", r.port.loads.single().albumRun!!.clipEndMs)
        r.port.fileMs = 180_200
        r.seq.handleEnded("gl_1"); r.settle()
        assertEquals(1, r.seq.currentIndex())
        assertEquals("gl_2", r.seq.currentSongId)
        assertEquals("no reload: the same file keeps playing", 1, r.port.loads.size)
        assertEquals(listOf("gl_2" to false), r.port.retargets)
        assertTrue(r.logs.any { it.contains("album glide to=gl_2") })
        assertTrue("no seek: the playhead just rolled on", r.port.seeks.isEmpty())
        // the last song reached through the album plays to the file's end: nothing armed
        assertNull(r.port.armed!!.second)
    }

    @Test fun failedGlideRetargetFallsBackToALoadOfTheCurrentRow() = runTest {
        val r = rig(mapOf("gl_1" to 0L, "gl_2" to 180_000L))
        r.seq.play(rows("gl_1" to 150_000, "gl_2" to 120_000)); r.settle()
        r.port.retargetOk = false
        r.port.fileMs = 180_200
        r.seq.handleEnded("gl_1"); r.settle()
        assertEquals(1, r.seq.currentIndex())
        assertEquals("the engine item must carry the new song", "gl_2", r.port.mediaId)
        assertEquals(listOf("load gl_1", "retarget gl_2", "load gl_2").filter { it != "retarget gl_2" }, r.port.calls.filter { it.startsWith("load") })
    }

    @Test fun albumRunPlaysThroughTheGapAfterADetectedEnd() = runTest {
        val r = rig(mapOf("gp_1" to 0L, "gp_2" to 240_000L), detectedEnd = mapOf("gp_1" to 150_000L))
        r.seq.play(rows("gp_1" to 150_000, "gp_2" to 120_000)); r.settle()
        // armed at the NEXT start (4:00), not at the detected end + grace (2:45): the 90 s run-out plays
        assertEquals(240_000L, r.port.armed!!.second)
        r.port.fileMs = 240_100
        r.seq.handleEnded("gp_1"); r.settle()
        assertEquals("gp_2", r.seq.currentSongId)
        assertEquals(1, r.port.loads.size)
        assertTrue(r.port.seeks.isEmpty())
    }

    @Test fun aBoundaryFiringFarBeforeTheNextStart_skipsTheGapInPlaceSeekBeforeRearming() = runTest {
        val r = rig(mapOf("g_1" to 0L, "g_2" to 240_000L, "g_3" to 400_000L))
        r.seq.play(rows("g_1" to 150_000, "g_2" to 120_000, "g_3" to 100_000)); r.settle()
        r.port.fileMs = 200_000 // 40 s short of g_2's start (a side flip / run-out)
        r.port.calls.clear()
        r.seq.handleEnded("g_1"); r.settle()
        assertEquals("g_2", r.seq.currentSongId)
        assertEquals(listOf(240_000L), r.port.seeks)
        val seekAt = r.port.calls.indexOf("seek 240000")
        val armAt = r.port.calls.indexOfFirst { it.startsWith("arm g_2") }
        assertTrue("seek happens BEFORE the new boundary is armed: ${r.port.calls}", seekAt in 0 until armAt)
        assertEquals(400_000L, r.port.armed!!.second)
        assertEquals(1, r.port.loads.size)
    }

    @Test fun playheadPastTheToleranceDeclines_andTheNextRowLoadsNormally() = runTest {
        val r = rig(mapOf("g_1" to 0L, "g_2" to 240_000L))
        r.seq.play(rows("g_1" to 150_000, "g_2" to 120_000)); r.settle()
        r.port.fileMs = 250_000 // scrubbed well past the next start
        r.seq.handleEnded("g_1"); r.settle()
        assertEquals(listOf("g_1", "g_2"), r.port.loads.map { it.item.id })
    }

    @Test fun loneVinylSong_keepsItsOwnWindow_noRunPlan() = runTest {
        val r = rig(mapOf("lo_1" to 0L, "lo_2" to 240_000L, "lo_x" to 0L))
        // lo_x lives in another file in real life; here the next row simply is not lo_2
        r.seq.play(rows("lo_1" to 150_000, "lo_x" to 120_000)); r.settle()
        assertNull(r.port.loads.single().albumRun)
        assertNull("no boundary armed for a lone song", r.port.armed!!.second)
        assertFalse(r.port.isRun)
        r.seq.handleEnded("lo_1"); r.settle()
        assertEquals("a natural end of a lone song loads the next row", listOf("lo_1", "lo_x"), r.port.loads.map { it.item.id })
    }

    @Test fun queueNextThatIsNotTheNextSong_declinesTheGlideAfterARun() = runTest {
        val r = rig(mapOf("q_1" to 0L, "q_2" to 100_000L, "q_3" to 200_000L))
        r.seq.play(rows("q_1" to 100_000, "q_2" to 100_000, "q_3" to 100_000)); r.settle()
        // a listener edit puts q_3 next AFTER the run item was loaded
        r.seq.insertNextInQueue(listOf(QueueItem(id = "q_3", title = "q_3")))
        r.settle()
        r.port.fileMs = 100_100
        r.seq.handleEnded("q_1"); r.settle()
        assertEquals("q_3", r.seq.currentSongId)
        assertEquals(listOf("q_1", "q_3"), r.port.loads.map { it.item.id })
    }

    @Test fun lastSongPlaysToTheEndOfTheFile() = runTest {
        val r = rig(mapOf("en_1" to 0L, "en_2" to 180_000L), detectedEnd = mapOf("en_2" to 300_000L))
        r.seq.play(rows("en_1" to 180_000, "en_2" to 100_000)); r.settle()
        r.port.fileMs = 180_100
        r.seq.handleEnded("en_1"); r.settle()
        assertEquals(1, r.seq.currentIndex())
        assertNull("the detected end arms no boundary", r.port.armed!!.second)
        assertTrue(r.seq.isRunning)
        // the file really ending is the sequencer's natural end of the last row
        r.seq.handleEnded("en_2"); r.settle()
        assertFalse(r.seq.isRunning)
    }

    @Test fun skipWithinTheAlbumFileSeeksInPlace() = runTest {
        val r = rig(mapOf("sk_1" to 0L, "sk_2" to 180_000L, "sk_3" to 400_000L))
        r.seq.play(rows("sk_1" to 180_000, "sk_2" to 220_000, "sk_3" to 200_000)); r.settle()
        r.port.fileMs = 60_000
        r.seq.skipNext(); r.settle()
        assertEquals(1, r.seq.currentIndex())
        assertEquals("sk_2", r.seq.currentSongId)
        assertEquals("no reload", 1, r.port.loads.size)
        assertEquals(listOf(180_000L), r.port.seeks)
        assertEquals(400_000L, r.port.armed!!.second)
        r.seq.skipNext(); r.settle()
        assertEquals("sk_3", r.seq.currentSongId)
        assertEquals(400_000L, r.port.seeks.last())
        r.seq.skipPrevious(); r.settle()
        assertEquals(1, r.seq.currentIndex())
        assertEquals("sk_2", r.seq.currentSongId)
        assertEquals(180_000L, r.port.seeks.last())
        assertEquals("still one load", 1, r.port.loads.size)
        assertTrue(r.logs.any { it.contains("album jump in-place to=sk_2") })
    }

    @Test fun skipRecordsOneHistoryPlayPerSong() = runTest {
        val r = rig(mapOf("h_1" to 0L, "h_2" to 180_000L))
        val seen = mutableListOf<PlayStarted>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { PlayEventBus.events.collect { seen += it } }
        r.seq.play(rows("h_1" to 180_000, "h_2" to 220_000)); r.settle()
        r.seq.skipNext(); r.settle()
        // the engine reports the first play (a load); the in-place jump is recorded by the sequencer exactly once
        assertEquals(listOf("h_2"), seen.map { it.songId })
    }

    @Test fun skipWhilePausedStartsPlayback() = runTest {
        val r = rig(mapOf("p_1" to 0L, "p_2" to 180_000L))
        r.seq.play(rows("p_1" to 180_000, "p_2" to 220_000)); r.settle()
        r.port.playing = false
        r.seq.skipNext(); r.settle()
        assertEquals(listOf("p_2" to true), r.port.retargets)
        assertTrue(r.port.playing)
    }

    @Test fun skipBackBeforeTheItemsClipStartReloads() = runTest {
        // started ON song 2 (clip starts at its own start): ⏮ onto song 1 cannot seek before the clip
        val r = rig(mapOf("b_1" to 0L, "b_2" to 180_000L, "b_3" to 400_000L))
        r.seq.play(rows("b_1" to 180_000, "b_2" to 220_000, "b_3" to 200_000), startIndex = 1); r.settle()
        assertEquals(180_000L, r.port.clipStart)
        r.seq.skipPrevious(); r.settle()
        assertEquals("b_1", r.seq.currentSongId)
        assertEquals(listOf("b_2", "b_1"), r.port.loads.map { it.item.id })
    }

    @Test fun albumFromTheTopStartsAtTheFilesLeadIn() = runTest {
        val r = rig(mapOf("li_1" to 8_000L, "li_2" to 190_000L))
        r.seq.play(rows("li_1" to 180_000, "li_2" to 120_000)); r.settle()
        val plan = r.port.loads.single().albumRun!!
        assertEquals("the album starts at the file's 0:00", 0L, plan.clipStartMs)
        assertEquals("the song's own start is unchanged", 8_000L, plan.songStartMs)
        assertEquals(0L, r.port.clipStart)
        r.seq.stop()

        val lone = rig(mapOf("li_1" to 8_000L, "li_2" to 190_000L))
        lone.seq.play(rows("li_1" to 180_000)); lone.settle()
        assertNull("the same song alone starts at its detected start", lone.port.loads.single().albumRun)
        assertEquals(8_000L, lone.port.clipStart)
    }

    @Test fun repeatOneKeepsTheSongsOwnEnd() = runTest {
        val r = rig(mapOf("r_1" to 0L, "r_2" to 180_000L))
        r.seq.setRepeatMode(RepeatMode.ONE)
        r.seq.play(rows("r_1" to 150_000, "r_2" to 120_000)); r.settle()
        assertNull(r.port.loads.single().albumRun)
    }

    @Test fun declinesWhenAnotherOwnerHasTheAudio() = runTest {
        var busy = false
        val r = rig(mapOf("d_1" to 0L, "d_2" to 180_000L, "d_3" to 400_000L), declines = { busy })
        r.seq.play(rows("d_1" to 150_000, "d_2" to 120_000, "d_3" to 100_000)); r.settle()
        busy = true // DSP engaged / Stem Lock / DJ tail deck owns the audio
        r.port.fileMs = 180_100
        r.seq.handleEnded("d_1"); r.settle()
        assertEquals(listOf("d_1", "d_2"), r.port.loads.map { it.item.id })
        // and a listener skip reloads too
        r.seq.skipNext(); r.settle()
        assertEquals(listOf("d_1", "d_2", "d_3"), r.port.loads.map { it.item.id })
    }

    @Test fun haltedAdvanceHoldsTheDeck_theSideDoesNotPlayOn() = runTest {
        val r = rig(mapOf("h_1" to 0L, "h_2" to 180_000L))
        r.seq.play(rows("h_1" to 150_000, "h_2" to 120_000)); r.settle()
        r.seq.autoAdvanceGate = { false }
        r.port.fileMs = 180_100
        r.seq.handleEnded("h_1"); r.settle()
        assertEquals(0, r.seq.currentIndex())
        assertTrue(r.port.calls.contains("pause"))
        assertTrue(r.port.retargets.isEmpty())
    }

    @Test fun staleBoundaryOfAnotherItemNeverGlides() = runTest {
        val r = rig(mapOf("s_1" to 0L, "s_2" to 180_000L))
        r.seq.play(rows("s_1" to 150_000, "s_2" to 120_000)); r.settle()
        r.port.mediaId = "someone-else" // the engine's item is not the row that "ended"
        r.port.fileMs = 180_100
        r.seq.handleEnded("s_1"); r.settle()
        assertEquals(listOf("s_1", "s_2"), r.port.loads.map { it.item.id })
    }

    @Test fun nextRowPreloaderNeverPreloadsARunContinuation() = runTest {
        val r = rig(mapOf("n_1" to 0L, "n_2" to 180_000L))
        val fake = r.port
        r.seq.preloadEnabled = true
        r.seq.play(rows("n_1" to 150_000, "n_2" to 120_000)); r.settle()
        r.seq.onFirstAudio("n_1"); r.settle()
        assertTrue("the run's next song is the same file: nothing to preload", fake.base.preloadCalls.isEmpty())
        // control: the same queue with runs off preloads the next row normally
        val off = rig(mapOf("n_1" to 0L, "n_2" to 180_000L))
        off.seq.albumTimelines = null
        off.seq.preloadEnabled = true
        off.seq.play(rows("n_1" to 150_000, "n_2" to 120_000)); off.settle()
        off.seq.onFirstAudio("n_1"); off.settle()
        assertEquals(listOf<String?>("n_2"), off.port.base.preloadCalls)
    }

    @Test fun iosShapedRowsWithoutTimelinesAreUnchanged() = runTest {
        val r = rig(mapOf("u_1" to 0L, "u_2" to 180_000L))
        r.seq.albumTimelines = null
        r.seq.play(rows("u_1" to 150_000, "u_2" to 120_000)); r.settle()
        assertNull(r.port.loads.single().albumRun)
        r.seq.handleEnded("u_1"); r.settle()
        assertEquals(listOf("u_1", "u_2"), r.port.loads.map { it.item.id })
    }
}
