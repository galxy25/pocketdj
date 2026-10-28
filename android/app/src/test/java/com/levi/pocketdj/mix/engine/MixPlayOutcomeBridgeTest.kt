package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayStarted
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixPlayOutcomeBridgeTest {
    /** A history stand-in: events appear when the test says the store "recorded" them. */
    private class Rig {
        val emitted = ArrayList<PlayStarted>()
        val known = HashMap<String, String>()          // "song@atMs" -> event id
        val listened = ArrayList<Pair<String, Double>>()
        val skipped = ArrayList<String>()
        val skipCounts = ArrayList<String>()
        val alreadySkipped = HashSet<String>()
        var label: String? = "Warmup"
        var sessionId: String? = null
        var now = 1_000L
        var latest: String? = null                      // fallback (collapsed) event
        var deferred = ArrayList<(Boolean) -> Boolean>()
        var async = false

        val bridge = MixPlayOutcomeBridge(
            emit = { emitted += it },
            findEvent = { song, at, final -> known["$song@$at"] ?: if (final) latest else null },
            noteListened = { id, f -> listened += id to f },
            markSkipped = { skipped += it },
            wasSkipped = { it in alreadySkipped },
            noteSkip = { skipCounts += it },
            trackInfo = { d -> "Title-$d" to "Artist" },
            contextLabel = { label },
            contextId = { sessionId },
            nowMs = { now },
            resolveAsync = { attempt -> if (async) deferred += attempt else { attempt(false) || attempt(true) } },
        )

        fun play(song: String, deck: Deck, id: String? = "ev-$song-$deck") {
            if (id != null) known["$song@$now"] = id
            bridge.onSongPlayed(song, deck)
            now += 1000
        }
    }

    @Test fun playEmitsMixSourceEventTaggedWithCrateName() {
        val r = Rig()
        r.play("s1", Deck.A)
        val e = r.emitted.single()
        assertEquals("s1", e.songId)
        assertEquals(PlayContext.SOURCE_MIX, e.context.source)
        assertEquals("Warmup", e.context.contextName)
        assertNull(e.context.contextId)
        assertEquals("Title-A", e.title)
        assertEquals(1_000L, e.atMs)
    }

    @Test fun mixSessionIdRidesTheContext() {
        val r = Rig(); r.sessionId = "sess-1"
        r.play("s1", Deck.A)
        assertEquals("sess-1", r.emitted.single().context.contextId)
    }

    @Test fun handDrivenMixHasNoContextName() {
        val r = Rig(); r.label = null
        r.play("s1", Deck.A)
        assertNull(r.emitted.single().context.contextName)
    }

    @Test fun naturalAndStoppedEndsNeverSkip_evenWhenShort() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 5.0, 200.0, MixTrackEndReason.NATURAL, Deck.A)
        r.play("s2", Deck.B)
        r.bridge.onDeckTrackEnded("s2", 1.0, 200.0, MixTrackEndReason.STOPPED, Deck.B)
        assertTrue(r.skipped.isEmpty())
        assertTrue(r.skipCounts.isEmpty())
        assertEquals(listOf("ev-s1-A" to 0.025, "ev-s2-B" to 0.005), r.listened)
    }

    @Test fun skipUnderHalfMarksSkippedAndCountsOnce() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 40.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertEquals(listOf("ev-s1-A"), r.skipped)
        assertEquals(listOf("s1"), r.skipCounts)
        assertEquals(0.2, r.listened.single().second, 1e-9)
    }

    @Test fun replacedUnderHalfIsASkipToo() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 10.0, 100.0, MixTrackEndReason.REPLACED, Deck.A)
        assertEquals(listOf("ev-s1-A"), r.skipped)
    }

    @Test fun skipAtOrOverHalfIsNotASkip() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 100.0, 200.0, MixTrackEndReason.SKIP, Deck.A) // exactly 50 %
        assertTrue(r.skipped.isEmpty())
        assertEquals(0.5, r.listened.single().second, 1e-9)
    }

    @Test fun secondEndForTheSameEventIsIgnored() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 40.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        r.bridge.onDeckTrackEnded("s1", 190.0, 200.0, MixTrackEndReason.NATURAL, Deck.A)
        assertEquals(1, r.listened.size)
        assertEquals(1, r.skipCounts.size)
    }

    @Test fun collapsedReplayMappingBackOntoAnEndedEventIsIgnored() {
        val r = Rig()
        r.play("s1", Deck.A, id = "same")
        r.bridge.onDeckTrackEnded("s1", 190.0, 200.0, MixTrackEndReason.NATURAL, Deck.A)
        r.play("s1", Deck.B, id = "same") // 30 s window: store returns the same event
        r.bridge.onDeckTrackEnded("s1", 3.0, 200.0, MixTrackEndReason.SKIP, Deck.B)
        assertEquals(1, r.listened.size)
        assertTrue(r.skipped.isEmpty())
    }

    @Test fun mappingIsKeyedByDeck_repeatOneDoesNotCrossCapture() {
        val r = Rig()
        r.play("rep", Deck.A, id = "evA")
        r.play("rep", Deck.B, id = "evB") // incoming deck, same song
        r.bridge.onDeckTrackEnded("rep", 195.0, 200.0, MixTrackEndReason.NATURAL, Deck.A)
        assertEquals(listOf("evA" to 0.975), r.listened)
        r.bridge.onDeckTrackEnded("rep", 20.0, 200.0, MixTrackEndReason.SKIP, Deck.B)
        assertEquals(listOf("evB"), r.skipped)
    }

    @Test fun endForADifferentSongOnTheDeckIsDroppedWithoutVerdict() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("other", 1.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertTrue(r.listened.isEmpty())
        assertFalse(r.bridge.isMapped(Deck.A))
    }

    @Test fun unknownDurationReportsNothing() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 5.0, 0.0, MixTrackEndReason.SKIP, Deck.A)
        assertTrue(r.listened.isEmpty())
        assertTrue(r.skipped.isEmpty())
    }

    @Test fun playedBeyondDurationClampsToOne() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.bridge.onDeckTrackEnded("s1", 260.0, 200.0, MixTrackEndReason.NATURAL, Deck.A)
        assertEquals(1.0, r.listened.single().second, 0.0)
    }

    @Test fun peerAlreadySkipped_marksButDoesNotRecountCumulativeSkip() {
        val r = Rig()
        r.play("s1", Deck.A)
        r.alreadySkipped += "ev-s1-A"
        r.bridge.onDeckTrackEnded("s1", 10.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertEquals(listOf("ev-s1-A"), r.skipped)
        assertTrue(r.skipCounts.isEmpty())
    }

    @Test fun unresolvedEventFallsBackToTheCollapsedRow() {
        val r = Rig()
        r.latest = "collapsed"
        r.play("s1", Deck.A, id = null)
        r.bridge.onDeckTrackEnded("s1", 10.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertEquals(listOf("collapsed"), r.skipped)
    }

    @Test fun noEventAtAll_dropsMappingSoNoStaleEndLands() {
        val r = Rig()
        r.play("s1", Deck.A, id = null)
        assertFalse(r.bridge.isMapped(Deck.A))
        r.bridge.onDeckTrackEnded("s1", 10.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertTrue(r.listened.isEmpty())
    }

    @Test fun endBeforeResolutionIsHeldThenApplied() {
        val r = Rig(); r.async = true
        r.play("s1", Deck.A) // known, but resolution deferred
        r.bridge.onDeckTrackEnded("s1", 10.0, 200.0, MixTrackEndReason.SKIP, Deck.A)
        assertTrue(r.listened.isEmpty()) // not yet
        r.deferred.single()(false)
        assertEquals(listOf("ev-s1-A"), r.skipped)
        assertEquals(listOf("s1"), r.skipCounts)
    }

    @Test fun supersededLoadDoesNotResolveIntoTheNewOne() {
        val r = Rig(); r.async = true
        r.play("s1", Deck.A, id = "old")
        r.play("s2", Deck.A, id = "new")
        assertTrue(r.deferred[0](false)) // superseded: settles without mapping
        r.deferred[1](false)
        r.bridge.onDeckTrackEnded("s2", 10.0, 100.0, MixTrackEndReason.SKIP, Deck.A)
        assertEquals(listOf("new"), r.skipped)
    }

    // ---- pickEvent ---------------------------------------------------------------------------

    private data class Ev(val id: String, val song: String, val at: Double, val local: Boolean = true)
    private fun pick(events: List<Ev>, song: String, at: Long, final: Boolean) =
        MixPlayOutcomeBridge.pickEvent(events, song, at, final, { it.id }, { it.song }, { it.at }, { it.local })

    @Test fun pickEvent_exactStampWins_andIgnoresPeerRows() {
        val evs = listOf(Ev("a", "s", 100.0), Ev("b", "s", 5_000.0, local = false), Ev("c", "s", 5_000.0))
        assertEquals("c", pick(evs, "s", 5_000, false))
        assertNull(pick(evs, "s", 7_000, false))
    }

    @Test fun pickEvent_finalFallsBackOnlyInsideTheRecountWindow() {
        val evs = listOf(Ev("a", "s", 100_000.0))
        assertEquals("a", pick(evs, "s", 120_000, true))
        assertNull(pick(evs, "s", 131_000, true))  // outside 30 s
        assertNull(pick(evs, "s", 90_000, true))   // older stamp than the row: distinct play, not collapsed
        assertNull(pick(emptyList(), "s", 1, true))
    }
}
