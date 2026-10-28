package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class AutoReadinessTest {
    private val A = Deck.A
    private val B = Deck.B

    // ---------------------------------------------------------------- pure rules

    @Test fun strictReadinessTable() {
        val inc = StreamView(false, 20.0)
        // nothing loaded
        assertFalse(AutoReadiness.ready(false, true, null, false, 0.0, 30.0))
        // plain on-disk deck
        assertTrue(AutoReadiness.ready(true, true, null, false, 0.0, 30.0))
        assertFalse("a loaded deck with no audio open", AutoReadiness.ready(true, false, null, false, 0.0, 30.0))
        // finished stream
        assertTrue(AutoReadiness.ready(true, true, StreamView(true, null), false, 0.0, 30.0))
        // holding is never ready, even complete
        assertFalse(AutoReadiness.ready(true, true, StreamView(true, null), true, 0.0, 30.0))
        // 15 s of runway past the playhead
        assertTrue(AutoReadiness.ready(true, true, inc, false, 5.0, 100.0))       // 20-5 = 15
        assertFalse(AutoReadiness.ready(true, true, inc, false, 5.5, 100.0))      // 14.5
        // a short song needs only what is left of it (minus 0.1 s)
        assertTrue(AutoReadiness.ready(true, true, StreamView(false, 9.95), false, 0.0, 10.0))
        assertFalse(AutoReadiness.ready(true, true, StreamView(false, 9.8), false, 0.0, 10.0))
        // unknown frontier
        assertFalse(AutoReadiness.ready(true, true, StreamView(false, null), false, 0.0, 30.0))
    }

    @Test fun lenientReadinessIsJustNotHolding() {
        assertFalse(AutoReadiness.canAir(false, true, null, false))
        assertTrue(AutoReadiness.canAir(true, true, null, false))
        assertTrue(AutoReadiness.canAir(true, true, StreamView(false, 0.5), false))
        assertFalse(AutoReadiness.canAir(true, true, StreamView(false, 0.5), true))
    }

    @Test fun constantsMatchTheField() {
        assertEquals(15.0, AutoReadiness.READY_RUNWAY, 0.0)
        assertEquals(0.5, AutoReadiness.EXTEND_AT_SECONDS_LEFT, 0.0)
        assertEquals(8.0, AutoReadiness.STALL_SKIP_SECONDS, 0.0)
    }

    @Test fun engineDeckReadinessFollowsTheDeckAndTheStreamSeam() {
        val r = AutoRig()
        assertFalse("empty deck", r.dj.readiness.deckReadyToAir(A))
        r.start()
        assertTrue(r.dj.readiness.deckReadyToAir(B))
        r.seams.streams[B] = StreamView(false, 3.0)
        assertFalse(r.dj.readiness.deckReadyToAir(B))
        assertTrue(r.dj.readiness.deckCanAir(B))
        r.held += B
        assertFalse(r.dj.readiness.deckCanAir(B))
    }

    // ---------------------------------------------------------------- promote / wait / extend

    @Test fun aNotReadyStandbyIsReplacedByAnOnDeviceUpcomingSongAndNeverDropped() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 2.0)     // s1 is streaming, 2 s downloaded
        r.seams.onDevice = { it != "s1" }
        r.run(20.2)                                     // the lead is reached
        assertEquals("s2 promoted into the next slot", "s2", r.id(B))
        assertEquals(listOf("s0", "s2", "s1", "s3"), r.dj.queueSongIds)
        assertTrue("the not-ready song stays queued behind it", "s1" in r.dj.queueSongIds)
        assertTrue(r.dj.autoTransitioning)
        assertTrue(r.advLines().any { it == "mixadvance promote s2 over not-ready s1 (auto)" })
    }

    @Test fun withNothingReadyTheMachineWaitsThenAdvancesTheMomentTheNextHasAudio() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 2.0)
        r.seams.onDevice = { false }
        r.run(25.0)
        assertFalse("waits instead of fading into a buffering deck", r.dj.autoTransitioning)
        assertEquals("one await line per wait, not per tick", 1, r.advLines().count { it.contains("await next s1") })
        r.seams.streams[B] = StreamView(true, null)     // download finished
        r.run(0.3)
        assertTrue(r.dj.autoTransitioning)
        assertTrue(r.advLines().any { it.startsWith("mixadvance advance -> s1 after wait") })
    }

    @Test fun atHalfASecondLeftWithNothingAiringTheLiveSongIsExtended() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 0.0)
        r.seams.onDevice = { false }
        r.held += B
        r.run(29.4)
        assertFalse(r.dj.autoTransitioning)
        assertTrue(r.dj.extending.not())
        r.run(0.3)                                      // crosses 0.5 s left
        assertTrue(r.dj.extending)
        assertTrue(r.advLines().any { it.startsWith("mixadvance extend s0") })
        assertTrue("replayed from the top", r.e.position(A) < 1.0)
        assertTrue(r.e.isPlaying(A))
        // end clock re-armed for the full song
        assertEquals(30.0, (r.dj.deckEndsAt[A]!! - r.h.nowMs) / 1000.0, 0.5)
        // the next song gets audio: the window is open at once (extending), no lead wait
        r.held.clear(); r.seams.streams[B] = StreamView(true, null)
        r.run(0.3)
        assertTrue(r.dj.autoTransitioning)
        assertFalse(r.dj.extending)
        assertTrue(r.advLines().any { it.startsWith("mixadvance advance -> s1 after wait") })
    }

    @Test fun anExtendedSongStillTransitionsWithTheFullFadeNotACappedOne() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 0.0); r.seams.onDevice = { false }; r.held += B
        r.run(30.0)
        assertTrue(r.dj.extending)
        r.held.clear(); r.seams.streams[B] = StreamView(true, null)
        r.run(0.3)
        assertEquals("secondsLeft was ~30 after the replay: no cap", 4.0, r.dj.fadeSeconds, 0.0)
        assertEquals(null, r.dj.pendingFadeRestore)
    }

    @Test fun lenientCanAirAtTheVeryEndLetsAnUnreadyButNotHoldingStandbyThrough() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 4.0)     // not ready (needs 15 s) but not holding
        r.seams.onDevice = { false }
        r.run(29.3)
        assertFalse("still waiting for the strict bar", r.dj.autoTransitioning)
        r.run(0.4)                                      // <= 0.5 s left: the lenient bar
        assertTrue(r.dj.autoTransitioning)
        assertTrue(r.e.isPlaying(B))
    }

    // ---------------------------------------------------------------- frozen fade / abandon

    @Test fun aFadeFrozenOnAHoldingIncomingKeepsTheOutgoingOnAirAndResumesReTimed() {
        val r = AutoRig()
        r.start(); r.run(21.0)                          // 1 s into the 4 s fade
        assertTrue(r.dj.autoTransitioning)
        val before = r.e.crossfader
        r.held += B
        r.run(0.2)
        r.run(5.0)
        val frozen = r.e.crossfader
        assertEquals("sweep frozen while the incoming buffers", before, frozen, 0.06)
        assertTrue(r.e.isPlaying(A))
        assertTrue(r.advLines().any { it.startsWith("mixadvance fade frozen - s1 buffering") })
        r.held.clear()
        r.run(0.2)
        assertTrue(r.advLines().any { it.startsWith("mixadvance fade resumed - s1 has audio") })
        val resumed = r.e.crossfader
        assertEquals("resumes from where it froze, not from the wall clock", frozen, resumed, 0.08)
        r.run(2.0)
        assertTrue(r.dj.autoTransitioning)
        r.run(1.5)
        assertFalse(r.dj.autoTransitioning)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals(1, r.dj.livePos)
    }

    @Test fun noAudibleGapDuringAFrozenFadeAtSampleResolution() {
        val r = AutoRig()
        r.start()
        val window = 88                                  // ~2 ms at 44.1 kHz
        val frozenOut = ArrayList<Float>()
        var t = 0.0
        fun step(freeze: Boolean) {
            val out = r.h.render(4410)
            r.h.tick(100)
            t += 0.1
            if (freeze) for (x in out) frozenOut += x
        }
        repeat(210) { step(false) }                      // 21 s: fade under way
        assertTrue(r.dj.autoTransitioning)
        r.held += B
        repeat(60) { step(true) }                        // 6 s frozen
        assertTrue("still frozen", r.dj.autoTransitioning)
        var worst = Float.MAX_VALUE
        var i = 0
        while (i + window * 2 <= frozenOut.size) {
            var m = 0f
            for (k in i until i + window * 2) m = maxOf(m, abs(frozenOut[k]))
            worst = minOf(worst, m)
            i += window * 2
        }
        assertTrue("an audible window every 2 ms while frozen (min peak $worst)", worst > 1e-3f)
    }

    @Test fun outgoingRunningOutWhileTheIncomingBuffersAbandonsAndExtends() {
        val r = AutoRig()
        r.start(); r.run(21.0)
        r.seams.onDevice = { false }                    // nothing else to promote
        r.seams.streams[B] = StreamView(false, 0.5)     // s1 is a stream with no runway
        r.held += B
        r.e.seek(A, 29.2)                                // transition in flight: seek does not re-time
        r.run(1.0)
        assertFalse(r.dj.autoTransitioning)
        assertEquals(Deck.A, r.dj.liveDeck)
        assertEquals(0.0, r.e.crossfader, 0.0)
        assertFalse("incoming silenced", r.e.isPlaying(B))
        assertEquals("s1", r.id(B))                     // still loaded: it keeps downloading
        assertTrue(r.dj.extending)
        assertTrue(r.advLines().any { it.contains("abandon fade") && it.contains("outgoing ran out while incoming buffering") })
        assertTrue(r.advLines().any { it.contains("extend s0") && it.contains("next still buffering") })
        assertEquals("cursor never moved", 0, r.dj.livePos)
    }

    @Test fun anIncomingDeckEjectedMidFadeBacksOut() {
        val r = AutoRig()
        r.start(); r.run(21.0)
        r.seams.onDevice = { false }
        r.e.clearDeck(B)
        r.h.tick(100)
        assertTrue(r.advLines().any { it.contains("abandon fade") && it.contains("incoming deck emptied") })
        assertEquals(Deck.A, r.dj.liveDeck)
        assertEquals("cursor never moved", 0, r.dj.livePos)
        assertEquals(0.0, r.e.crossfader, 0.0)
        assertTrue("outgoing stays on air", r.e.isPlaying(A))
        // the idle lane re-preloads the next song and the mix carries on (never silence)
        r.run(0.3)
        assertEquals("s1", r.id(B))
        r.run(5.0)
        assertEquals(Deck.B, r.dj.liveDeck)
    }

    @Test fun abandoningRestoresTheBaselineFadeAndTheCursor() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.skipToNext(1.0)
        assertEquals(1.0, r.dj.fadeSeconds, 0.0)
        r.e.clearDeck(B)
        r.run(0.2)
        assertEquals(4.0, r.dj.fadeSeconds, 0.0)
        assertEquals(null, r.dj.pendingFadeRestore)
    }

    // ---------------------------------------------------------------- stall skip

    @Test fun aLiveDeckStalledEightSecondsHandsOverInOneSecond() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.held += A
        r.run(7.7)
        assertFalse("not yet", r.dj.autoTransitioning)
        r.run(0.6)
        assertTrue(r.dj.autoTransitioning)
        assertEquals("1 s hand-over", 1.0, r.dj.fadeSeconds, 0.0)
        assertEquals(4.0, r.dj.pendingFadeRestore!!, 0.0)
        assertTrue(r.advLines().any { it.startsWith("mixadvance stall-skip s0 held 8s -> s1") })
        assertTrue(r.e.isPlaying(B))
        r.held.clear()
        r.run(1.5)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals(4.0, r.dj.fadeSeconds, 0.0)
    }

    @Test fun aShortHoldNeverTriggersAStallSkip() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.held += A; r.run(5.0); r.held.clear(); r.run(5.0)
        assertFalse(r.dj.autoTransitioning)
        assertTrue(r.advLines().any { it.contains("deck A resumed after") })
    }

    // ---------------------------------------------------------------- deferred, never dropped

    @Test fun streamGateClosedSongsAreDeferredWhileVanishedOnesAreDropped() {
        val r = AutoRig(n = 5)
        r.h.removeSong("s1"); r.h.removeSong("s2")
        r.seams.gated += "s1"                             // ripped, gate closed right now
        r.start()
        assertEquals("s0", r.id(A)); assertEquals("s3", r.id(B))
        assertEquals("s1 kept (deferred), s2 dropped", listOf("s0", "s3", "s1", "s4"), r.dj.queueSongIds)
        assertTrue(r.advLines().any { it.startsWith("mixadvance slot 1: deferred") })
    }

    @Test fun anUnloadableTailEntryIsDroppedAndTheCursorStaysConsistent() {
        val r = AutoRig(n = 4)
        r.start()
        r.h.removeSong("s2")                              // purged after the start-time preload
        r.run(25.0)                                       // A -> B; the retired deck's preload skips gone s2
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals("s3 took the retired deck", "s3", r.id(A))
        assertEquals(1, r.dj.livePos)
        r.run(16.0)                                       // next lead: ensureNextPreloaded drops the dead row
        assertEquals(listOf("s0", "s1", "s3"), r.dj.queueSongIds)
        assertEquals(1, r.dj.livePos)
        assertEquals(3, r.dj.nextToLoad)
        assertTrue(r.dj.autoTransitioning)
    }

    @Test fun skipPrefersAReadySongOverABufferingOne() {
        val r = AutoRig()
        r.start(); r.run(2.0)
        r.seams.streams[B] = StreamView(false, 1.0)
        r.seams.onDevice = { it != "s1" }
        r.dj.skipToNext(2.0)
        assertEquals("s2", r.id(B))
        assertTrue(r.advLines().any { it == "mixadvance skip -> s2 ready=1" })
    }

    @Test fun everyDecisionLogsOnTheMixadvanceLane() {
        val r = AutoRig()
        r.start()
        r.seams.streams[B] = StreamView(false, 0.0); r.seams.onDevice = { false }; r.held += B
        r.run(31.0)
        val lines = r.advLines()
        assertTrue(lines.isNotEmpty())
        assertTrue(lines.all { it.startsWith("mixadvance ") })
        assertNotEquals(0, lines.count { it.contains("await") || it.contains("extend") })
    }
}
