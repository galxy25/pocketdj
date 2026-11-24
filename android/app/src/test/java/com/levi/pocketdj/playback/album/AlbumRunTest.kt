package com.levi.pocketdj.playback.album

import com.levi.pocketdj.data.rips.AlbumFileTimeline
import com.levi.pocketdj.data.rips.AlbumFileTimeline.Segment
import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AlbumRunTest {
    private val tl = AlbumFileTimeline(
        "rips/side.mp3",
        listOf(Segment("a", 8_000), Segment("b", 190_000), Segment("c", 400_000)),
        detectedEndMs = mapOf("a" to 150_000),
    )

    private fun q(vararg ids: String) = ids.map { QueueItem(id = it, title = it) }

    // ---- run detection matrix -------------------------------------------------------------------------------

    @Test fun inOrderNeighbours_continueTheRun() {
        val run = AlbumRun.albumRun(q("a", "b", "c"), 0, tl, repeatOne = false)
        assertEquals("b", run.next?.songId)
        assertFalse(run.fromPrevious)
        val mid = AlbumRun.albumRun(q("a", "b", "c"), 1, tl, repeatOne = false)
        assertEquals("c", mid.next?.songId)
        assertTrue(mid.fromPrevious)
        val last = AlbumRun.albumRun(q("a", "b", "c"), 2, tl, repeatOne = false)
        assertNull(last.next)
        assertTrue(last.fromPrevious)
    }

    @Test fun nextRowThatIsNotTheNextSong_isNotARun() {
        assertNull(AlbumRun.albumRun(q("a", "c", "b"), 0, tl, false).next)
        assertNull(AlbumRun.albumRun(q("a", "x"), 0, tl, false).next)
        assertNull(AlbumRun.albumRun(q("a"), 0, tl, false).next)
    }

    @Test fun repeatOne_breaksTheRun() {
        assertNull(AlbumRun.albumRun(q("a", "b"), 0, tl, repeatOne = true).next)
    }

    @Test fun perRowRepeatCountOverOne_breaksTheRun_butOneDoesNot() {
        val twice = listOf(QueueItem("a", repeatCount = 2), QueueItem("b"))
        assertNull(AlbumRun.albumRun(twice, 0, tl, false).next)
        val once = listOf(QueueItem("a", repeatCount = 1), QueueItem("b"))
        assertEquals("b", AlbumRun.albumRun(once, 0, tl, false).next?.songId)
    }

    @Test fun editionVariantsMatchByBaseId() {
        val vtl = AlbumFileTimeline("k", listOf(Segment("sng_0123456789ab", 0), Segment("sng_ba9876543210", 100_000)))
        val rows = listOf(QueueItem("sng_0123456789ab_clean"), QueueItem("sng_ba9876543210_clean"))
        assertEquals("sng_ba9876543210", AlbumRun.albumRun(rows, 0, vtl, false).next?.songId)
    }

    @Test fun cleanOnlySkipNeighbour_isNeverGlidedOnto() {
        val rows = listOf(QueueItem("a"), QueueItem("b", cleanOnlySkip = true))
        assertNull(AlbumRun.albumRun(rows, 0, tl, false).next)
    }

    @Test fun fromPreviousNeedsTheRecordsPreviousSong() {
        assertFalse(AlbumRun.albumRun(q("x", "b"), 1, tl, false).fromPrevious)
        assertTrue(AlbumRun.albumRun(q("a", "b"), 1, tl, false).fromPrevious)
        assertFalse(AlbumRun.albumRun(q("b"), 0, tl, false).fromPrevious)
    }

    // ---- plan: one item per run -----------------------------------------------------------------------------

    @Test fun albumFromTheTop_startsAtTheFilesLeadIn_keepingTheSongsOwnStart() {
        val p = AlbumRun.plan(q("a", "b"), 0, tl, 8_000, false, fresh = true, resumeAtMs = null)!!
        assertTrue(p.leadIn)
        assertEquals(0L, p.clipStartMs)
        assertEquals(8_000L, p.songStartMs)
        assertNull("one item: no clip end", p.clipEndMs)
        assertEquals(190_000L, p.boundaryFileMs)
    }

    @Test fun leadIn_neverOnResumeCueOrRepeatPass() {
        assertEquals(8_000L, AlbumRun.plan(q("a", "b"), 0, tl, 8_000, false, fresh = true, resumeAtMs = 5_000)!!.clipStartMs)
        assertEquals(8_000L, AlbumRun.plan(q("a", "b"), 0, tl, 8_000, false, fresh = false, resumeAtMs = null)!!.clipStartMs)
    }

    @Test fun leadIn_onlyForTheFirstSongOfTheSide() {
        val p = AlbumRun.plan(q("b", "c"), 0, tl, 190_000, false, fresh = true, resumeAtMs = null)!!
        assertFalse(p.leadIn)
        assertEquals(190_000L, p.clipStartMs)
        assertEquals(400_000L, p.boundaryFileMs)
    }

    @Test fun lastSongReachedThroughTheAlbum_playsToFileEnd() {
        val p = AlbumRun.plan(q("b", "c"), 1, tl, 400_000, false, fresh = true, resumeAtMs = null)!!
        assertNull(p.clipEndMs)
        assertNull("no boundary: the side plays out", p.boundaryFileMs)
        assertEquals(400_000L, p.clipStartMs)
    }

    @Test fun loneSong_hasNoPlan_andKeepsItsOwnWindow() {
        assertNull(AlbumRun.plan(q("a"), 0, tl, 8_000, false, true, null))
        assertNull(AlbumRun.plan(q("a", "x"), 0, tl, 8_000, false, true, null))
        // a lone LAST song (nothing before it) is not "through the album" either
        assertNull(AlbumRun.plan(q("c"), 0, tl, 400_000, false, true, null))
    }

    @Test fun planNeedsTheManifestStartToMatchTheTimeline() {
        assertNull("a stale start (user edit moved it) is not this side's song", AlbumRun.plan(q("a", "b"), 0, tl, 9_999, false, true, null))
        assertNull(AlbumRun.plan(q("a", "b"), 0, null, 8_000, false, true, null))
        assertNull(AlbumRun.plan(q("a", "b"), 0, tl, null, false, true, null))
    }

    @Test fun boundaryMs_runNextStart_elseOwnEndPlusGrace_elseNull() {
        assertEquals(190_000L, AlbumRun.boundaryMs(q("a", "b"), 0, tl, 8_000, false, 100_000))
        // alone: detected end 150 s + 15 s grace, capped at the next start
        assertEquals(165_000L, AlbumRun.boundaryMs(q("a", "x"), 0, tl, 8_000, false, 100_000))
        // last through the album: plays to the end of the file
        assertNull(AlbumRun.boundaryMs(q("b", "c"), 1, tl, 400_000, false, 100_000))
    }

    @Test fun runContinuation_isOnlyTheTimelinesNextSong() {
        assertTrue(AlbumRun.isRunContinuation(q("a", "b"), 0, tl, false))
        assertFalse(AlbumRun.isRunContinuation(q("a", "x"), 0, tl, false))
        assertFalse(AlbumRun.isRunContinuation(q("a", "b"), 0, tl, true))
        assertFalse(AlbumRun.isRunContinuation(q("a", "b"), 0, null, false))
    }

    // ---- glide decision -------------------------------------------------------------------------------------

    @Test fun glide_atTheNextStart_retargetsWithoutSeek() {
        assertEquals(AlbumRun.GlideStep.Retarget, AlbumRun.glideStep(190_200, 8_000, 190_000))
        assertEquals(AlbumRun.GlideStep.Retarget, AlbumRun.glideStep(193_000, 8_000, 190_000)) // edge of tolerance
    }

    @Test fun glide_aGapLongerThanTolerance_seeksFirst() {
        assertEquals(AlbumRun.GlideStep.SeekThenRetarget(240_000), AlbumRun.glideStep(200_000, 8_000, 240_000))
        assertEquals(AlbumRun.GlideStep.Retarget, AlbumRun.glideStep(237_000, 8_000, 240_000))
        assertEquals(AlbumRun.GlideStep.SeekThenRetarget(240_000), AlbumRun.glideStep(236_999, 8_000, 240_000))
    }

    @Test fun glide_declinesOutsideTheWindow() {
        assertNull("before the current song's start", AlbumRun.glideStep(5_000, 8_000, 190_000))
        assertNull("way past the next start (scrubbed beyond)", AlbumRun.glideStep(193_001, 8_000, 190_000))
    }

    // ---- in-place jump --------------------------------------------------------------------------------------

    @Test fun jump_targetsASegmentOfTheSameFileAtOrAfterTheClipStart() {
        assertEquals(190_000L, AlbumRun.jumpTargetMs("b", tl, 0))
        val vtl = AlbumFileTimeline("k", listOf(Segment("sng_0123456789ab", 0), Segment("sng_ba9876543210", 100_000)))
        assertEquals(100_000L, AlbumRun.jumpTargetMs("sng_ba9876543210_clean", vtl, 100_000))
        assertNull("⏮ before the item's clip start cannot seek in place", AlbumRun.jumpTargetMs("a", tl, 190_000))
        assertNull(AlbumRun.jumpTargetMs("zzz", tl, 0))
        assertNull(AlbumRun.jumpTargetMs("a", null, 0))
        assertNotNull(AlbumRun.jumpTargetMs("a", tl, 8_000))
    }

    // ---- boundary gate --------------------------------------------------------------------------------------

    @Test fun gate_firesOnceAtTheBoundaryInItemTime() {
        val g = BoundaryGate()
        val a = g.arm("a", 190_000, 0)!!
        assertEquals(190_000L, a.itemMs)
        assertFalse(g.reached("a", 0, 189_999))
        assertTrue(g.reached("a", 0, 190_000))
        assertNotNull(g.consume(a.token))
        assertNull("one-shot", g.consume(a.token))
        assertFalse(g.reached("a", 0, 200_000))
    }

    @Test fun gate_mapsFileTimeThroughTheClipStart() {
        val g = BoundaryGate()
        val a = g.arm("b", 400_000, 190_000)!!
        assertEquals(210_000L, a.itemMs)
        assertTrue(g.reached("b", 190_000, 210_000))
    }

    @Test fun gate_reArmingSupersedesTheOldTokenAndIdentityMustMatch() {
        val g = BoundaryGate()
        val old = g.arm("a", 190_000, 0)!!
        val fresh = g.arm("b", 400_000, 0)!!
        assertNull("a stale message of the superseded arm", g.consume(old.token))
        assertFalse("engine still holds song a's item", g.reached("a", 0, 500_000))
        assertFalse("different clip start = a different item", g.reached("b", 190_000, 500_000))
        assertTrue(g.reached("b", 0, 400_000))
        assertNotNull(g.consume(fresh.token))
    }

    @Test fun gate_nullOrUnreachableDisarms() {
        val g = BoundaryGate()
        g.arm("a", 190_000, 0)
        assertNull(g.arm("a", null, 0))
        assertNull(g.armed)
        assertNull("a boundary before the clip start can never be reached", g.arm("a", 100, 5_000))
    }
}
