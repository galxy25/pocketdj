package com.levi.pocketdj.playback.album

import androidx.media3.common.C
import androidx.media3.common.Player
import com.levi.pocketdj.data.rips.AlbumFileTimeline
import com.levi.pocketdj.data.rips.AlbumFileTimeline.Segment
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.playback.sequencer.AlbumFileState
import com.levi.pocketdj.playback.sequencer.FakePlayerPort
import com.levi.pocketdj.playback.sequencer.PlayRequest
import com.levi.pocketdj.playback.sequencer.PlayerPort
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.ResolveContext
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.RowSource
import com.levi.pocketdj.playback.sequencer.RowSourceResolver
import com.levi.pocketdj.playback.sequencer.Rung
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StreamSource
import com.levi.pocketdj.playback.session.FakeControl
import com.levi.pocketdj.playback.session.FakePlayerState
import com.levi.pocketdj.playback.session.SequencerForwardingPlayer
import com.levi.pocketdj.playback.session.fakePlayer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** P2-ALB-5: song-relative clocks (pure maps + the session player), seekAlbumFile / cueNextStart. */
@OptIn(ExperimentalCoroutinesApi::class)
class SongRelativeClockTest {
    // ---- pure maps ----------------------------------------------------------------------------------------------

    private val span = SongSpan(startMs = 180_000, endMs = 400_000)

    @Test fun leadInShowsZeroUntilTheSongStarts() {
        // clip from 0 (lead-in): the engine is 30 s into the groove, the song starts at 3:00
        assertEquals(0L, AlbumSeek.relativePosition(30_000, 0, span))
        assertEquals(0L, AlbumSeek.relativePosition(180_000, 0, span))
        assertEquals(5_000L, AlbumSeek.relativePosition(185_000, 0, span))
    }

    @Test fun clippedItemIsOffsetBySongStart() {
        // clip starts at the song: item position IS song-relative
        assertEquals(12_000L, AlbumSeek.relativePosition(12_000, 180_000, span))
    }

    @Test fun durationIsSongEndMinusStart_orRemainingFileForTheLastSong() {
        assertEquals(220_000L, AlbumSeek.relativeDuration(9_999_999, 180_000, span))
        val last = SongSpan(500_000, null)
        // item duration 300 s from clip 500 s => file ends at 800 s => last song is 300 s long
        assertEquals(300_000L, AlbumSeek.relativeDuration(300_000, 500_000, last))
        assertNull(AlbumSeek.relativeDuration(null, 500_000, last))
        assertNull(AlbumSeek.relativeDuration(0, 500_000, last))
    }

    @Test fun remoteSeekMapsBackToTheItemAndClampsToTheSong() {
        assertEquals(60_000L, AlbumSeek.toItemPosition(60_000, 180_000, span))
        // lead-in item (clip 0): song-relative 60 s is file 4:00
        assertEquals(240_000L, AlbumSeek.toItemPosition(60_000, 0, span))
        assertEquals("negative -> the song's start", 180_000L, AlbumSeek.toItemPosition(-5, 0, span))
        assertEquals("past the end -> the song's end", 400_000L, AlbumSeek.toItemPosition(9_000_000, 0, span))
        // round trip
        assertEquals(77_000L, AlbumSeek.relativePosition(AlbumSeek.toItemPosition(77_000, 0, span), 0, span))
    }

    @Test fun nearestOccurrencePrefersForwardOnATie() {
        val ids = listOf("a", "b", "a", "c", "a")
        assertEquals(4, AlbumSeek.nearestOccurrence(ids, "a", 3)) // 2 and 4 tie -> forward
        assertEquals(2, AlbumSeek.nearestOccurrence(ids, "a", 1)) // 0 and 2 tie -> forward
        assertEquals(2, AlbumSeek.nearestOccurrence(ids, "a", 2))
        assertEquals(4, AlbumSeek.nearestOccurrence(ids, "a", 4))
        assertEquals(0, AlbumSeek.nearestOccurrence(ids, "a", 0))
        assertEquals(3, AlbumSeek.nearestOccurrence(ids, "c", 0))
        assertNull(AlbumSeek.nearestOccurrence(ids, "zzz", 0))
    }

    @Test fun startCueIsOneShotMatchedAndExpires() {
        var now = 1_000L
        val cue = AlbumSeek.StartCue { now }
        cue.arm("song", 42_000)
        assertEquals(42_000L, cue.consume("song"))
        assertNull("consumed", cue.consume("song"))
        cue.arm("song", 42_000)
        assertNull("another song's start consumes it either way", cue.consume("other"))
        assertNull(cue.consume("song"))
        cue.arm("song", 42_000)
        now += AlbumSeek.CUE_TTL_MS
        assertNull("expired after 30 s", cue.consume("song"))
    }

    // ---- the session player -------------------------------------------------------------------------------------

    private val ps = FakePlayerState()
    private var clock: RunClock? = null
    private val fwd = SequencerForwardingPlayer(fakePlayer(ps), FakeControl(), log = { _, _, _ -> }, runClock = RunClockSource { clock })

    @Test fun sessionPlayerReportsSongRelativePositionAndDuration() {
        clock = RunClock(clipStartMs = 0, span = span)
        ps.position = 30_000; ps.duration = 900_000
        assertEquals("lead-in reads 0:00", 0L, fwd.currentPosition)
        assertEquals(0L, fwd.contentPosition)
        assertEquals(220_000L, fwd.duration)
        ps.position = 200_000
        assertEquals(20_000L, fwd.currentPosition)
        assertEquals(20_000L, fwd.contentPosition)
        assertEquals(220_000L, fwd.contentDuration)
        // glide: the clock source now names the next song and the position restarts at 0
        clock = RunClock(0, SongSpan(400_000, null))
        ps.position = 400_000
        assertEquals(0L, fwd.currentPosition)
        assertEquals(500_000L, fwd.duration) // file 900 s - song start 400 s
    }

    @Test fun sessionPlayerWithoutARunKeepsTheEnginesOwnClock() {
        clock = null
        ps.position = 123; ps.duration = 456
        assertEquals(123L, fwd.currentPosition)
        assertEquals(456L, fwd.duration)
        fwd.seekTo(99)
        assertEquals(99L, ps.seeks.last())
    }

    @Test fun unknownDurationOfALastSongStaysUnset() {
        clock = RunClock(500_000, SongSpan(500_000, null))
        ps.duration = C.TIME_UNSET
        assertEquals(C.TIME_UNSET, fwd.duration)
    }

    @Test fun remoteSeekMapsBackToFileMs() {
        clock = RunClock(0, span)
        fwd.seekTo(60_000)
        assertEquals(240_000L, ps.seeks.last())
        fwd.seekTo(0, 10_000) // same-item indexed seek maps too
        assertEquals(190_000L, ps.seeks.last())
        fwd.seekTo(5_000_000)
        assertEquals("clamped to the song's end", 400_000L, ps.seeks.last())
    }

    @Test fun rekickReseeksTheRawPositionNeverTheMappedOne() {
        clock = RunClock(0, span)
        ps.position = 30_000 // inside the lead-in: song-relative is 0, raw is 30 s
        ps.state = Player.STATE_BUFFERING; ps.playWhenReady = true
        fwd.rekick()
        assertEquals("rekick seeks the raw playhead, not the song start", 30_000L, ps.seeks.last())
    }

    // ---- sequencer: seekAlbumFile + cueNextStart ----------------------------------------------------------------

    private class RunPort(val base: FakePlayerPort = FakePlayerPort()) : PlayerPort by base {
        val loads = mutableListOf<PlayRequest>()
        val calls = mutableListOf<String>()
        val retargets = mutableListOf<String>()
        var mediaId: String? = null
        var clipStart = 0L
        var fileMs = 0L
        var isRun = false
        override suspend fun load(request: PlayRequest) {
            loads += request
            mediaId = request.item.id
            val plan = request.albumRun
            isRun = plan != null
            clipStart = plan?.clipStartMs ?: 0L
            fileMs = clipStart + (request.resumeAtMs ?: 0L)
        }
        override suspend fun replay(songId: String): Boolean = false
        override fun armBoundary(songId: String, fileMs: Long?, clipStartMs: Long) { calls += "arm $songId $fileMs" }
        override fun albumFileState(): AlbumFileState? = if (isRun && mediaId != null) AlbumFileState(mediaId!!, clipStart, fileMs, true) else null
        override fun seekInFile(fileMs: Long): Boolean {
            if (!isRun || fileMs < clipStart) return false
            calls += "seek $fileMs"
            this.fileMs = fileMs
            return true
        }
        override suspend fun retargetInPlace(item: QueueItem, startPlayback: Boolean): Boolean {
            calls += "retarget ${item.id}"
            retargets += item.id
            mediaId = item.id
            return true
        }
    }

    private class SideResolver(val starts: Map<String, Long>) : RowSourceResolver {
        override val id = "side"
        override val rung = Rung.MANIFEST
        override suspend fun resolve(item: QueueItem, ctx: ResolveContext): RowSource? =
            starts[item.id]?.let { StreamSource(PlayAction.Stream("https://rips/side.mp3", it, it + 100_000)) }
    }

    private class Rig(val port: RunPort, val seq: SetlistSequencer, val settle: () -> Unit)

    private fun TestScope.rig(starts: Map<String, Long>, declines: () -> Boolean = { false }): Rig {
        val port = RunPort()
        val seq = SetlistSequencer(scope = backgroundScope, port = port, registry = RowResolverRegistry(listOf(SideResolver(starts))), log = { })
        val tl = AlbumFileTimeline("rips/side.mp3", starts.map { Segment(it.key, it.value) })
        val source = AlbumTimelineSource { id -> tl.takeIf { t -> t.segment(com.levi.pocketdj.data.edition.SongVariant.baseId(id)) != null } }
        seq.albumTimelines = source
        val player = AlbumRunPlayer(seq, port, source, backgroundScope, declines = declines, log = { })
        seq.addAdvanceInterceptor(player)
        seq.addStartInterceptor(player)
        return Rig(port, seq) { runCurrent() }
    }

    private fun rows(vararg ids: String) = ids.map { QueueItem(id = it, title = it, lengthMs = 100_000) }

    private val side = mapOf("s_1" to 0L, "s_2" to 100_000L, "s_3" to 200_000L)

    @Test fun seekAlbumFileInTheSameSongIsAPlainSeek() = runTest {
        val r = rig(side)
        r.seq.play(rows("s_1", "s_2", "s_3")); r.settle()
        r.port.calls.clear()
        assertTrue(r.seq.seekAlbumFile(40_000))
        assertEquals(listOf("seek 40000"), r.port.calls)
        assertEquals(0, r.seq.currentIndex())
        assertEquals(1, r.port.loads.size)
    }

    @Test fun seekAlbumFileToAnotherSongMovesTheCursorSeeksThenRetargets() = runTest {
        val r = rig(side)
        r.seq.play(rows("s_1", "s_2", "s_3")); r.settle()
        r.port.calls.clear()
        assertTrue(r.seq.seekAlbumFile(230_000)) // 30 s into s_3
        r.settle()
        assertEquals(2, r.seq.currentIndex())
        assertEquals("s_3", r.seq.currentSongId)
        assertEquals("no reload: same item, retitled", 1, r.port.loads.size)
        val calls = r.port.calls
        val disarm = calls.indexOf("arm  null")
        val seek = calls.indexOf("seek 230000")
        val retarget = calls.indexOf("retarget s_3")
        val rearm = calls.indexOfFirst { it.startsWith("arm s_3") }
        assertTrue("disarm, then seek, then re-arm, then retarget: $calls", disarm in 0 until seek && seek < rearm && rearm < retarget)
    }

    @Test fun seekAlbumFileFallsBackToALoadAtTheSongRelativeOffsetWhenTheEngineDeclines() = runTest {
        var declines = false
        val r = rig(side) { declines }
        r.seq.play(rows("s_1", "s_2", "s_3")); r.settle()
        declines = true // e.g. a DSP engaged: never move in place
        assertTrue(r.seq.seekAlbumFile(230_000))
        r.settle()
        assertEquals("s_3", r.seq.currentSongId)
        assertEquals(2, r.port.loads.size)
        assertEquals("starts 30 s into the song", 30_000L, r.port.loads.last().resumeAtMs)
        assertTrue(r.port.retargets.isEmpty())
    }

    @Test fun seekAlbumFileDeclinesWhenNothingIsLoaded() = runTest {
        val r = rig(side)
        assertFalse(r.seq.seekAlbumFile(1_000))
        r.seq.play(rows("s_1")); r.settle() // a lone row: no run item
        assertFalse(r.seq.seekAlbumFile(150_000))
    }

    @Test fun cueNextStartMakesTheNextFreshStartLandInsideTheSong() = runTest {
        val r = rig(side)
        r.seq.cueNextStart("s_2", 25_000)
        r.seq.play(rows("s_2", "s_3")); r.settle()
        assertEquals(25_000L, r.port.loads.single().resumeAtMs)
        // one-shot: the next fresh start is from the top
        r.seq.play(rows("s_1", "s_2")); r.settle()
        assertEquals("s_1", r.port.loads.last().item.id)
        assertNull(r.port.loads.last().resumeAtMs)
    }

    @Test fun cueForAnotherSongIsDiscardedByTheFreshStart() = runTest {
        val r = rig(side)
        r.seq.cueNextStart("s_3", 25_000)
        r.seq.play(rows("s_1", "s_2")); r.settle()
        assertNull(r.port.loads.single().resumeAtMs)
        r.seq.play(rows("s_3")); r.settle()
        assertNull("the cue was consumed by the earlier start", r.port.loads.last().resumeAtMs)
    }
}
