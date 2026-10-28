package com.levi.pocketdj.mix.service

import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixRecoveryTest {
    private class FakePort : RecoveryPort {
        var now = 0L
        override fun nowMs() = now
        override var mixWantsAudio = true
        override var isRendering = true
        override var recording = false
        val playing = mutableSetOf(Deck.A)
        val held = mutableSetOf<Deck>()
        val looping = mutableSetOf<Deck>()
        val gain = mutableMapOf(Deck.A to 1.0, Deck.B to 1.0)
        val xf = mutableMapOf(Deck.A to 1.0, Deck.B to 1.0)
        val stemsMuted = mutableSetOf<Deck>()
        /** Seconds since the tap last saw an audible block (-1 = never). */
        var sigAge = 0.0
        var remaining = 120.0
        var sinkOk = true
        val calls = mutableListOf<String>()
        override fun deckPlaying(deck: Deck) = deck in playing
        override fun deckHeld(deck: Deck) = deck in held
        override fun deckLooping(deck: Deck) = deck in looping
        override fun deckGain(deck: Deck) = gain.getValue(deck)
        override fun crossfadeFactor(deck: Deck) = xf.getValue(deck)
        override fun allStemsMuted(deck: Deck) = deck in stemsMuted
        override fun signalAgeSeconds() = sigAge
        override fun remainingSeconds(deck: Deck) = remaining
        override fun parkClocks() { calls += "park" }
        override fun unparkClocks() { calls += "unpark" }
        override fun restartSink(): Boolean { calls += "restart"; return sinkOk }
        override fun reprime(deck: Deck) { calls += "reprime${deck.label}" }
        override fun pauseDeck(deck: Deck) { calls += "pause${deck.label}"; playing -= deck }
    }

    private val p = FakePort()
    private val r = MixRecovery(p, log = {})

    @Test fun sinkDownParksClocksOnce() {
        p.now = 1000
        r.onSinkRouting(false); r.onSinkRouting(false)
        assertEquals(listOf("park"), p.calls)
        assertEquals(1000L, r.downAtMs)
    }

    @Test fun sinkBackUnparksRestartsAndReprimesPlayingDecks() {
        p.playing += Deck.B
        r.onSinkRouting(false)
        p.now = 800
        r.onSinkRouting(true)
        assertEquals(listOf("park", "unpark", "restart", "reprimeA", "reprimeB"), p.calls)
        assertNull(r.downAtMs)
    }

    @Test fun routeChangeWithoutAnOutageStillReprimesButDoesNotUnpark() {
        r.onSinkRouting(true)   // the track was rebuilt between blocks: never observed down
        assertEquals(listOf("restart", "reprimeA"), p.calls)
    }

    @Test fun heldDecksAreNotReprimed() {
        p.held += Deck.A
        r.onSinkRouting(true)
        assertEquals(listOf("restart"), p.calls)
    }

    @Test fun idleMixDoesNotParkOnSinkLoss() {
        p.mixWantsAudio = false
        r.onSinkRouting(false)
        assertTrue(p.calls.isEmpty()); assertNull(r.downAtMs)
    }

    /** The mix has been running > 3 s with a dead tap: every gate open. */
    private fun silentFor4s() { p.sigAge = 10.0; p.now = 0; r.silentPlayingCheck(); p.calls.clear(); p.now = 4000 }
    private fun tick() { r.silentPlayingCheck() }

    @Test fun deckThatSaysPlayingButTapIsSilentStrikesThenPauses() {
        silentFor4s()    // first beat only starts the running clock (strike 0, no suspect yet)
        tick(); tick()
        assertEquals(listOf("reprimeA", "reprimeA"), p.calls)
        assertEquals(2, r.strikeCount(Deck.A))
        tick()
        assertEquals("pauseA", p.calls.last())
        assertEquals(1, r.silentPlayingEvents)
        assertEquals(0, r.strikeCount(Deck.A))
    }

    @Test fun neverAnySignalCountsAsSilent() {
        p.sigAge = -1.0; p.now = 0; r.silentPlayingCheck(); p.now = 4000
        repeat(3) { tick() }
        assertEquals(1, r.silentPlayingEvents)
    }

    @Test fun audibleTapSignalClearsStrikes() {
        silentFor4s(); tick()
        assertEquals(1, r.strikeCount(Deck.A))
        p.sigAge = 0.2; tick()
        assertEquals(0, r.strikeCount(Deck.A))
    }

    @Test fun youngMixIsNotSuspectUntilItHasRunThreeSeconds() {
        p.sigAge = -1.0; p.now = 0
        r.silentPlayingCheck(); p.now = 2500
        repeat(5) { tick() }
        assertEquals(0, r.strikeCount(Deck.A)); assertEquals(0, r.silentPlayingEvents)
    }

    @Test fun recordingKeepsSuspectsRunning() {
        silentFor4s(); p.recording = true
        repeat(3) { tick() }
        assertFalse(p.calls.any { it.startsWith("pause") })
        assertEquals(1, r.silentPlayingEvents)
    }

    @Test fun expectedSilenceIsNeverSuspect() {
        silentFor4s()
        p.held += Deck.A; tick(); p.held.clear()
        p.looping += Deck.A; tick(); p.looping.clear()
        p.gain[Deck.A] = 0.0; tick(); p.gain[Deck.A] = 1.0
        p.xf[Deck.A] = 0.0; tick(); p.xf[Deck.A] = 1.0
        p.stemsMuted += Deck.A; tick(); p.stemsMuted.clear()
        p.remaining = 0.5; tick(); p.remaining = 100.0          // natural end of the file
        p.isRendering = false; tick(); p.isRendering = true     // dark sink = the stall path
        assertEquals(0, r.strikeCount(Deck.A))
        assertTrue(p.calls.isEmpty())
    }

    @Test fun pausedDeckIsNeverSuspect() {
        p.playing.clear()
        repeat(5) { p.now += 1000; tick() }
        assertTrue(p.calls.isEmpty())
    }
}
