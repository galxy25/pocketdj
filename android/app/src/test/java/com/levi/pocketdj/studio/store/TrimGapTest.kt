package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TrimGapTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }

    private fun c(id: String, start: Int, dur: Int, fs: Int = 0, file: String = "f.m4a") =
        StudioClip(id, id, file, startMs = start, durationMs = dur, fileStartMs = fs)

    private var n = 0
    private val mint = { "new${n++}" }

    @Test fun headTailMiddleAndDisjointCases() {
        // Middle split: head keeps id + file; tail gets a NEW id, same fileName, window slid by (ce - s).
        val mid = TrimGap.trimGap(listOf(c("a", 100, 1000, fs = 40, file = "x.m4a")), 300, 600, mint)
        assertEquals(listOf("a", "new0"), mid.map { it.id })
        assertEquals(200, mid[0].durationMs)
        assertEquals("x.m4a", mid[1].fileName)
        assertEquals(600, mid[1].startMs)
        assertEquals(40 + (600 - 100), mid[1].fileStartMs)
        assertEquals(1100 - 600, mid[1].durationMs)
        // Head trim only: identity kept, window slides.
        val head = TrimGap.trimGap(listOf(c("a", 0, 1000)), 0, 250, mint)
        assertEquals(listOf("a"), head.map { it.id }); assertEquals(250, head[0].startMs); assertEquals(250, head[0].fileStartMs)
        // Tail trim only.
        val tail = TrimGap.trimGap(listOf(c("a", 0, 1000)), 700, 5000, mint)
        assertEquals(listOf("a"), tail.map { it.id }); assertEquals(700, tail[0].durationMs)
        // Disjoint and inverted cut: untouched. Fully covered: dropped.
        assertEquals(listOf(c("a", 0, 100)), TrimGap.trimGap(listOf(c("a", 0, 100)), 200, 300, mint))
        assertEquals(listOf(c("a", 0, 100)), TrimGap.trimGap(listOf(c("a", 0, 100)), 50, 50, mint))
        assertTrue(TrimGap.trimGap(listOf(c("a", 100, 100)), 0, 1000, mint).isEmpty())
        // Nothing slides left: later clips keep their start (the gap stays silent).
        val later = TrimGap.trimGap(listOf(c("a", 0, 100), c("b", 500, 100)), 50, 400, mint)
        assertEquals(500, later.last().startMs)
    }

    @Test fun seedRegionIsFourBeatsClampedAndSnapped() {
        // 120 bpm => iOS 'bar4' = 4 beats = 2000 ms.
        assertEquals(0 to 2000, TrimGap.seedRegion(0, 20_000, 120.0))
        assertEquals(2000 to 4000, TrimGap.seedRegion(2000, 20_000, 120.0))
        // Clamped to the timeline end.
        assertEquals(10_000 to 12_000, TrimGap.seedRegion(10_000, 12_000, 120.0))
        // Cursor stranded past the end falls back to a region from 0.
        val (s, e) = TrimGap.seedRegion(99_999, 3000, 120.0)
        assertTrue(s >= 0 && e > s)   // iOS keeps a >=1 ms band after snapping
    }

    private fun arr(vararg tracks: StudioTrack) = StudioArrangement("arr_1", "A", tracks = tracks.toList(), bpm = 120.0)
    private fun trk(id: String, vararg clips: StudioClip) = StudioTrack(id, id, clips = clips.toList())

    @Test fun beginSelectsAllTracksAndStagesEveryClip() {
        val a = arr(trk("t1", c("a", 0, 1000)), trk("t2", c("b", 0, 1000)))
        val s = TrimSession.begin(a, 0)!!
        assertTrue(s.allSelected()); assertEquals(setOf("t1", "t2"), s.selected)
        assertEquals("All tracks", s.selectionLabel { it })
        assertEquals(listOf("a"), s.clipsFor("t1").map { it.id })
        assertNull(TrimSession.begin(arr(), 0))
    }

    private fun assertNull(o: Any?) = org.junit.Assert.assertNull(o)

    @Test fun cutThenUndoRestoresAndStagingNeverTouchesTheModel() {
        val t1 = trk("t1", c("a", 0, 1000))
        val s = TrimSession.begin(arr(t1), 0)!!
        s.setRegion(300, 600)
        assertTrue(s.cut(mint))
        assertEquals(2, s.clipsFor("t1").size)
        assertTrue(s.canUndo)
        assertTrue(s.undo())
        assertEquals(listOf(c("a", 0, 1000)), s.clipsFor("t1"))
        assertFalse(s.canUndo)
        assertFalse(s.undo())
        assertEquals(1, t1.clips.size)  // model value untouched
    }

    @Test fun selectionIsLockedOnceACutIsStaged() {
        val s = TrimSession.begin(arr(trk("t1", c("a", 0, 1000)), trk("t2", c("b", 0, 1000))), 0)!!
        s.setSelected("t2", false)
        assertEquals(setOf("t1"), s.selected)
        assertEquals("t1", s.selectionLabel { it })
        s.setRegion(100, 200)
        s.cut(mint)
        assertTrue(s.selectionLocked)
        s.setSelected("t2", true); s.selectAll()
        assertEquals(setOf("t1"), s.selected)         // locked: ignored
        // Only the selected track was cut.
        assertEquals(2, s.clipsFor("t1").size); assertEquals(1, s.clipsFor("t2").size)
        s.undo()
        assertFalse(s.selectionLocked)
        s.selectAll(); assertTrue(s.allSelected())
    }

    @Test fun cutNeedsARegionAndASelection() {
        val s = TrimSession.begin(arr(trk("t1", c("a", 0, 1000))), 0)!!
        s.setRegion(500, 500); assertFalse(s.canCut); assertFalse(s.cut(mint))
        s.setRegion(100, 500); s.setSelected("t1", false)
        assertFalse(s.canCut); assertEquals("No tracks", s.selectionLabel { it })
        assertFalse(s.canSave)
    }

    @Test fun cancelIsAPureRevertWithZeroWrites() {
        val store = env.store()
        val a = store.createArrangement("A"); val t = store.addTrack(a.id)!!
        File(env.roots.arrangementsDir(), "clip-x.m4a").writeText("x")
        store.addClip(a.id, t.id, StudioClip("clip_x", "X", "clip-x.m4a", durationMs = 1000))
        val before = store.arrangement(a.id)!!
        val s = TrimSession.begin(before, 0)!!
        s.setRegion(200, 400); s.cut(mint)
        s.cancel()
        assertTrue(s.closed)
        assertEquals(before, store.arrangement(a.id))
        assertEquals(listOf("clip-x.m4a"), env.roots.arrangementsDir().listFiles()!!.map { it.name }.filter { it.startsWith("clip-") })
        assertFalse(s.save(store, a.id))   // closed session cannot commit
        assertEquals(before, store.arrangement(a.id))
    }

    @Test fun saveCommitsEverySelectedTrackDedupesTailAndCleansOrphans() {
        val store = env.store()
        val a = store.createArrangement("A")
        val t1 = store.addTrack(a.id)!!; val t2 = store.addTrack(a.id)!!
        val dir = env.roots.arrangementsDir()
        File(dir, "clip-one.m4a").writeText("one"); File(dir, "clip-two.m4a").writeText("two"); File(dir, "clip-gone.m4a").writeText("g")
        store.addClip(a.id, t1.id, StudioClip("clip_one", "One", "clip-one.m4a", durationMs = 1000))
        store.addClip(a.id, t2.id, StudioClip("clip_two", "Two", "clip-two.m4a", durationMs = 1000))
        store.addClip(a.id, t2.id, StudioClip("clip_gone", "Gone", "clip-gone.m4a", startMs = 400, durationMs = 100))
        val s = TrimSession.begin(store.arrangement(a.id)!!, 0)!!
        s.setRegion(300, 600)
        assertTrue(s.cut())
        assertTrue(s.save(store, a.id))
        val after = store.arrangement(a.id)!!
        for (t in after.tracks) assertEquals(t.id, 2, t.clips.size.coerceAtMost(2))
        val one = after.tracks[0].clips
        assertEquals(2, one.size); assertNotEquals(one[0].fileName, one[1].fileName)   // shared tail got its own file
        assertEquals(600, one[1].startMs); assertEquals(600, one[1].fileStartMs)
        val two = after.tracks[1].clips
        assertEquals(2, two.size)   // clip_gone sat fully inside the cut and was dropped
        assertFalse(two.any { it.id == "clip_gone" })
        assertFalse(File(dir, "clip-gone.m4a").exists())                                // orphan cleaned
        (one + two).forEach { assertTrue(File(dir, it.fileName).exists()) }
    }
}
