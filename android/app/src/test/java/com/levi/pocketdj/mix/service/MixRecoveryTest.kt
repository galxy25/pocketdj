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
        val voice = mutableSetOf(Deck.A)
        var remaining = 120.0
        var sinkOk = true
        val calls = mutableListOf<String>()
        override fun deckPlaying(deck: Deck) = deck in playing
        override fun deckHeld(deck: Deck) = deck in held
        override fun voicePlaying(deck: Deck) = deck in voice
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

    @Test fun silentPlayingStrikesRekickThenPause() {
        p.voice.clear()
        r.silentPlayingCheck()
        r.silentPlayingCheck()
        assertEquals(listOf("reprimeA", "reprimeA"), p.calls)
        assertEquals(2, r.strikeCount(Deck.A))
        r.silentPlayingCheck()
        assertEquals("pauseA", p.calls.last())
        assertEquals(1, r.silentPlayingEvents)
        assertEquals(0, r.strikeCount(Deck.A))
    }

    @Test fun recordingKeepsSuspectsRunning() {
        p.voice.clear(); p.recording = true
        repeat(3) { r.silentPlayingCheck() }
        assertFalse(p.calls.any { it.startsWith("pause") })
        assertEquals(1, r.silentPlayingEvents)
    }

    @Test fun healthyHeldEndingOrDarkSinkResetStrikes() {
        p.voice.clear()
        r.silentPlayingCheck()
        assertEquals(1, r.strikeCount(Deck.A))
        p.voice += Deck.A
        r.silentPlayingCheck()
        assertEquals(0, r.strikeCount(Deck.A))

        p.voice.clear(); r.silentPlayingCheck()
        p.held += Deck.A; r.silentPlayingCheck()
        assertEquals(0, r.strikeCount(Deck.A))
        p.held.clear()

        r.silentPlayingCheck()
        p.remaining = 0.5; r.silentPlayingCheck()    // natural end of the file
        assertEquals(0, r.strikeCount(Deck.A))

        p.remaining = 100.0; r.silentPlayingCheck()
        p.isRendering = false; r.silentPlayingCheck()  // a dark sink is the stall path, not a voice fault
        assertEquals(0, r.strikeCount(Deck.A))
    }

    @Test fun pausedDeckIsNeverSuspect() {
        p.voice.clear(); p.playing.clear()
        repeat(5) { r.silentPlayingCheck() }
        assertTrue(p.calls.isEmpty())
    }
}
