package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.longestSilence
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A source that logs every seek and the furthest frame ever read (post-reset). */
class RecSource(private val inner: SyntheticPcmSource) : PcmSource by inner {
    val seeks = mutableListOf<Long>()
    @Volatile var maxEnd = 0L
    private var pos = 0L
    override fun seek(frame: Long) { synchronized(seeks) { seeks += frame }; pos = frame; inner.seek(frame) }
    override fun read(dst: FloatArray, frames: Int): Int {
        val r = inner.read(dst, frames)
        if (r > 0) { pos += r; if (pos > maxEnd) maxEnd = pos }
        return r
    }
    fun resetLog() { synchronized(seeks) { seeks.clear() }; maxEnd = 0 }
    fun seeksSnapshot(): List<Long> = synchronized(seeks) { seeks.toList() }
}

class LoopWindowTest {
    private val A = Deck.A
    private fun track(bpm: Double? = null, beats: List<Int>? = null, downbeats: List<Int>? = null, firstDownbeat: Int? = null) =
        LoadedTrack("s", "t", "a", gridBpm = bpm, firstDownbeatMs = firstDownbeat, beatsMs = beats, downbeatsMs = downbeats)

    // ---------------------------------------------------------------- pure math

    @Test fun unitsAreBeatsWhenAGridOrBpmExistsElseSeconds() {
        assertFalse(LoopMath.usesBeats(null))
        assertFalse(LoopMath.usesBeats(track()))
        assertTrue(LoopMath.usesBeats(track(bpm = 128.0)))
        assertTrue(LoopMath.usesBeats(track(beats = listOf(0, 500))))
        assertFalse("a single beat is not a lattice", LoopMath.usesBeats(track(beats = listOf(0))))
        assertEquals(1.0, LoopMath.unitSeconds(track()), 0.0)
        assertEquals(0.5, LoopMath.unitSeconds(track(bpm = 120.0)), 1e-9)
        assertEquals("bpm clamps to 20...300", 3.0, LoopMath.unitSeconds(track(bpm = 5.0)), 1e-9)
        // the MEASURED lattice wins: median gap, immune to one drifted beat
        val t = track(bpm = 60.0, beats = listOf(0, 500, 1000, 1510, 2000))
        assertEquals(0.5, LoopMath.unitSeconds(t), 1e-9)
    }

    @Test fun windowSnapsBackToThePreviousUnitBoundary() {
        assertEquals(3.0 to 4.0, LoopMath.windowMath(3.3, 0.0, 0.5, 2.0, 10.0))
        val ph = LoopMath.windowMath(3.3, 0.1, 0.5, 2.0, 10.0)!!
        assertEquals(3.1, ph.first, 1e-9); assertEquals(4.1, ph.second, 1e-9)
        assertEquals("before the first downbeat the window starts at the phase", 0.4, LoopMath.windowMath(0.1, 0.4, 0.5, 2.0, 10.0)!!.first, 1e-9)
        assertNull(LoopMath.windowMath(1.0, 0.0, 0.0, 2.0, 10.0))
        assertNull(LoopMath.windowMath(1.0, 0.0, 0.5, 2.0, 0.0))
    }

    @Test fun aWindowThatWouldOverrunSlidesBackKeepingItsLength() {
        assertEquals(8.0 to 10.0, LoopMath.clampWindow(9.5, 11.5, 10.0))
        assertEquals("a 4-beat loop engaged in the last bar stays 4 beats", 8.0 to 10.0, LoopMath.windowMath(9.8, 0.0, 0.5, 4.0, 10.0))
        val tiny = LoopMath.clampWindow(1.0, 1.01, 10.0)!!
        assertEquals("a sub-50 ms window is a click, not a loop", 0.05, tiny.second - tiny.first, 1e-9)
        assertEquals(0.0 to 3.0, LoopMath.clampWindow(-2.0, 1.0, 3.0))
    }

    @Test fun measuredGridDrivesBothEdgesThroughBeatMath() {
        val beats = (0 until 40).map { 100 + it * 500 }
        val w = LoopMath.bounds(track(bpm = 120.0, beats = beats, firstDownbeat = 100), 2.0, 3.3, 20.0)!!
        assertEquals(3.1, w.first, 1e-9); assertEquals(4.1, w.second, 1e-9)
        // real tempo drift is honored: a stretched bar is longer than two nominal beats
        val drift = listOf(0, 500, 1000, 1600, 2300, 3000)
        val d = LoopMath.bounds(track(bpm = 120.0, beats = drift), 2.0, 1.2, 10.0)!!
        assertEquals(1.0, d.first, 1e-9); assertEquals(2.3, d.second, 1e-9)
        // units clamp to 1...32
        assertEquals(0.5, LoopMath.bounds(track(bpm = 120.0), 0.0, 3.3, 100.0)!!.let { it.second - it.first }, 1e-9)
        assertEquals(16.0, LoopMath.bounds(track(bpm = 120.0), 99.0, 3.3, 100.0)!!.let { it.second - it.first }, 1e-9)
    }

    @Test fun nudgeMovesOneEdgeByWholeUnitsAndKeepsTheLengthInRange() {
        val w = 3.0 to 4.0
        val end = LoopMath.nudge(w, LoopEdge.END, 1.0, 0.5, 10.0)!!
        assertEquals(3.0 to 4.5, end.window); assertEquals(3.0, end.units, 0.0)
        val start = LoopMath.nudge(w, LoopEdge.START, -1.0, 0.5, 10.0)!!
        assertEquals(2.5 to 4.0, start.window); assertEquals(3.0, start.units, 0.0)
        // the start edge can never cross the end (one unit minimum)
        assertEquals(3.5 to 4.0, LoopMath.nudge(w, LoopEdge.START, 9.0, 0.5, 10.0)!!.window)
        // the end edge stops at the deck's end
        assertEquals(10.0, LoopMath.nudge(w, LoopEdge.END, 99.0, 0.5, 10.0)!!.window.second.coerceAtMost(10.0), 0.0)
        // growing past 32 units is clamped on the WINDOW, not just the displayed count
        val big = LoopMath.nudge(0.0 to 15.5, LoopEdge.END, 5.0, 0.5, 100.0)!!
        assertEquals(16.0, big.window.second - big.window.first, 1e-9); assertEquals(32.0, big.units, 0.0)
    }

    @Test fun schedulableNeedsTheWholeWindowInsideTheStemFrontier() {
        assertTrue(LoopMath.schedulable(3.0 to 4.0, null, 9.9))
        assertTrue(LoopMath.schedulable(3.0 to 4.0, 4.0, 9.9))
        assertFalse(LoopMath.schedulable(3.0 to 4.5, 4.0, 9.9))
        assertFalse(LoopMath.schedulable(9.95 to 10.5, null, 9.9))
        assertFalse(LoopMath.schedulable(4.0 to 4.0, null, 9.9))
        assertTrue(LoopMath.resumeInside(3.5, 3.0 to 4.0)); assertFalse(LoopMath.resumeInside(3.01, 3.0 to 4.0)); assertFalse(LoopMath.resumeInside(null, 3.0 to 4.0))
    }

    // ---------------------------------------------------------------- the controller on a real engine

    private fun rig(bpm: Double? = 120.0, recorder: ((RecSource) -> Unit)? = null): StemRig {
        val r = StemRig()
        r.engine.load(
            r.h.addSong("s", 20.0, gridBpm = bpm, firstDownbeatMs = if (bpm != null) 0 else null) {
                RecSource(SyntheticPcmSource.counter(r.h.sr * 20L)).also { recorder?.invoke(it) }
            },
            A,
        )
        return r
    }

    @Test fun engagingWindowsTwoUnitsOffThePreviousBoundaryInBeatsOrSeconds() {
        val beats = rig(120.0)
        beats.engine.seek(A, 3.3)
        beats.loops.setLoop(A, true)
        assertTrue(beats.engine.deckState(A).loopOn)
        assertEquals(3.0 to 4.0, beats.loops.loopWindow(A))
        assertTrue(beats.loops.loopUsesBeats(A)); assertEquals(0.5, beats.loops.loopUnitSeconds(A), 1e-9)
        assertEquals("engaging keeps the playhead where it is", 3.3, beats.engine.position(A), 1e-9)
        assertEquals(beats.engine.loopWindow(A), beats.loops.loopWindow(A))

        val secs = rig(null)
        secs.engine.seek(A, 3.3)
        secs.loops.setLoop(A, true)
        assertFalse(secs.loops.loopUsesBeats(A))
        assertEquals(3.0 to 5.0, secs.loops.loopWindow(A))
    }

    @Test fun theDecoderWrapsFrameExactAtTheWindowAndNothingGoesSilent() {
        var rec: RecSource? = null
        val r = rig(120.0) { rec = it }
        r.engine.seek(A, 3.3)
        r.engine.play(A)
        r.run(0.3)
        r.loops.setLoop(A, true)
        r.h.render(2_048)   // the plan handshake flushed the read-ahead; the log starts at the re-seek
        rec!!.resetLog()
        val sr = r.h.sr
        val w = r.loops.loopWindow(A)!!   // the playhead had moved on to 3.6 s: the beat it is in is 3.5
        assertEquals(3.5 to 4.5, w)
        val ws = Math.round(w.first * sr); val we = Math.round(w.second * sr)
        val out = r.run(3.5)
        assertEquals("the decoder never reads past the loop end", we, rec!!.maxEnd)
        assertTrue("it re-seeks to the loop start at each wrap: ${rec!!.seeksSnapshot()}", rec!!.seeksSnapshot().count { it == ws } >= 2)
        assertTrue("no gap at the seam: ${longestSilence(out, 0, out.size / 2)}", longestSilence(out, 0, out.size / 2) < 200)
        val v = r.engine.controller(A).voice!!
        assertTrue(v.playerFrame in ws until we)
        assertTrue("the engine's playhead folds into the window", r.engine.position(A) in 3.5..4.5)
    }

    @Test fun releasingTheLoopCarriesStraightOnAndRetimesTheAutoEnd() {
        val r = rig(120.0)
        val auto = FakeAutoDj(); r.engine.autoDj = auto
        r.engine.play(A); r.engine.seek(A, 3.3); r.run(0.2)
        r.loops.setLoop(A, true)
        r.run(2.5)
        val seeksBefore = auto.seeks.size
        r.loops.setLoop(A, false)
        assertFalse(r.engine.deckState(A).loopOn)
        assertNull(r.loops.loopWindow(A))
        assertTrue("release re-times the auto end", auto.seeks.size > seeksBefore)
        val here = r.engine.position(A)
        r.run(2.0)
        assertTrue("plays on past the old window end", r.engine.position(A) > here + 1.5 && r.engine.position(A) > 4.5)
    }

    @Test fun nudgingEdgesAndSettingUnitsRearmTheWindow() {
        val r = rig(120.0)
        r.engine.seek(A, 3.3)
        r.loops.setLoop(A, true)
        r.loops.nudgeLoop(A, LoopEdge.END, 1.0)
        assertEquals(3.0 to 4.5, r.loops.loopWindow(A))
        assertEquals(3.0, r.loops.loopUnits(A), 0.0)
        r.loops.nudgeLoop(A, LoopEdge.START, -2.0)
        assertEquals(2.0 to 4.5, r.loops.loopWindow(A))
        assertEquals(5.0, r.loops.loopUnits(A), 0.0)
        r.loops.setLoopUnits(A, 4.0)
        assertEquals("setLoopUnits keeps the window start", 2.0 to 4.0, r.loops.loopWindow(A))
        r.loops.setLoopUnits(A, 99.0)
        assertEquals(32.0, r.loops.loopUnits(A), 0.0)
        assertEquals(2.0, r.loops.loopWindow(A)!!.first, 1e-9)
        assertEquals(18.0, r.loops.loopWindow(A)!!.second, 1e-9)
    }

    @Test fun seekingWhileLoopedMovesTheLoopToWhereTheyDropped() {
        val r = rig(120.0)
        r.engine.play(A)
        r.engine.seek(A, 3.3)
        r.loops.setLoop(A, true)
        r.run(0.5)
        r.engine.seek(A, 12.2)
        assertEquals(12.0 to 13.0, r.loops.loopWindow(A))
        assertEquals("a re-anchored loop plays from its new start", 12.0, r.engine.position(A), 1e-9)
        assertTrue(r.engine.deckState(A).loopOn)
        r.run(1.5)
        assertTrue(r.engine.position(A) in 12.0..13.0)
    }

    @Test fun aLoadOrRestartInvalidatesTheLoop() {
        val r = rig(120.0)
        r.engine.seek(A, 3.3)
        r.loops.setLoop(A, true)
        r.engine.restart(A)
        assertFalse(r.engine.deckState(A).loopOn)
        assertNull(r.loops.loopWindow(A))
        r.loops.setLoop(A, true)
        r.engine.load(r.h.addSong("other", 10.0), A)
        assertFalse(r.engine.deckState(A).loopOn)
        assertNull(r.engine.loopWindow(A))
    }

    @Test fun aLoopSurvivesTheDurableSnapshotRoundTrip() {
        val r = rig(120.0)
        r.engine.seek(A, 3.3)
        r.loops.setLoop(A, true)
        r.loops.setLoopUnits(A, 4.0)
        val snap = r.engine.mixDeckSnapshot()!!.deckA!!
        assertEquals(true, snap.loopOn); assertEquals(4.0, snap.loopUnits!!, 0.0)
        // a fresh engine restores length first, then engages around the restored playhead
        val r2 = rig(120.0)
        r2.engine.seek(A, 3.3)
        r2.loops.restore(A, snap)
        assertEquals(3.0 to 5.0, r2.loops.loopWindow(A))
    }

    // ---------------------------------------------------------------- loops and stems

    @Test fun aLoopOnStemsFollowsTheDeckAndWrapsOnTheStemVoices() {
        val r = rig(120.0)
        val recs = ArrayList<RecSource>()
        r.fake.local["s"] = { StemParts(List(4) { RecSource(SyntheticPcmSource.counter(r.h.sr * 20L)).also { recs += it } }, complete = true) }
        r.stems.setStemMode(true, A)
        r.engine.seek(A, 3.3)
        r.engine.play(A); r.run(0.3)
        r.loops.setLoop(A, true)
        r.h.render(2_048)
        recs.forEach { it.resetLog() }
        val out = r.run(3.0)
        val w = r.loops.loopWindow(A)!!
        val ws = Math.round(w.first * r.h.sr); val we = Math.round(w.second * r.h.sr)
        assertTrue(r.stems.active(A))
        assertTrue("stem voices wrap at the window end: ${recs.map { it.maxEnd }}", recs.all { it.maxEnd == we })
        assertTrue(recs.all { s -> s.seeksSnapshot().count { it == ws } >= 1 })
        assertTrue(longestSilence(out, 0, out.size / 2) < 200)
    }

    @Test fun aLoopOnStreamingStemsRefusesUntilTheWindowIsInsideTheFrontier() {
        val r = rig(120.0)
        val st = r.stream(secs = 20.0, availableSec = 5.0)
        r.engine.seek(A, 4.2)
        r.stems.setStemMode(true, A)   // paused + partial stems: cut once they have runway
        assertEquals("0.8 s of runway is not enough for a streaming source", StemHandover.TO_STEMS, r.stems.handover(A))
        st.growTo(12.0); r.stems.streamProgressed("s")
        assertTrue(r.stems.active(A))
        r.engine.seek(A, 4.9)
        st.growTo(5.2); r.stems.pumpStems(A)   // pretend the frontier sits at 5.2 s
        r.loops.setLoop(A, true)                // window 4.5-5.5 ends past it
        assertFalse("refused: lit-but-silent is never allowed", r.engine.deckState(A).loopOn)
        assertNull(r.loops.loopWindow(A))
        assertTrue(r.h.diags.any { it.contains("REFUSED") })
        st.growTo(5.6); r.stems.pumpStems(A)
        r.loops.setLoop(A, true)
        assertTrue(r.engine.deckState(A).loopOn)
        assertEquals(4.5 to 5.5, r.loops.loopWindow(A))
    }

    @Test fun aPendingStemHandoverWaitsForTheLoopWindowToFitTheStems() {
        val r = rig(120.0)
        val st = r.stream(secs = 20.0, availableSec = 6.0)
        r.engine.seek(A, 7.3)
        r.engine.play(A); r.run(0.2)
        r.loops.setLoop(A, true)
        assertEquals(7.0 to 8.0, r.loops.loopWindow(A))
        r.stems.setStemMode(true, A)
        // streaming stems that do not reach the window never take a looping deck over
        r.run(0.5)
        assertFalse(r.engine.deckState(A).stemMode)
        assertEquals(StemHandover.TO_STEMS, r.stems.handover(A))
        assertNotNull(r.loops.loopWindow(A))
        st.growTo(20.0); r.stems.streamProgressed("s")
        r.run(1.0)
        assertTrue(r.engine.deckState(A).stemMode)
        assertEquals("the loop followed the deck onto its stems", 7.0 to 8.0, r.loops.loopWindow(A))
        assertTrue(r.engine.position(A) in 7.0..8.0)
    }
}
