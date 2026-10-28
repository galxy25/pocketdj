package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.AutoRepeatMode
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.store.AutoSnapshot
import com.levi.pocketdj.mix.store.MixEventKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Fake outside facts for the Auto-DJ: streams, on-device predicate, closed stream gate. */
internal class FakeSeams : AutoSeams {
    val streams = HashMap<Deck, StreamView>()
    var onDevice: (String) -> Boolean = { true }
    val gated = HashSet<String>()
    override fun stream(deck: Deck): StreamView? = streams[deck]
    override fun songOnDevice(songId: String) = onDevice(songId)
    override fun transientlyUnloadable(songId: String) = songId in gated
}

/** Engine harness + a wired Auto-DJ over synthetic [n] songs of [seconds] each. */
internal class AutoRig(
    n: Int = 4, val seconds: Double = 30.0, val lead: Double = 10.0, val fade: Double = 4.0,
    seed: Int = 7,
    store: com.levi.pocketdj.mix.store.MixDeckSessionStore? = null,
    tweak: (Int, com.levi.pocketdj.mix.model.MixLoadable) -> com.levi.pocketdj.mix.model.MixLoadable = { _, l -> l },
) {
    val h = EngineHarness(store)
    val e get() = h.engine
    val seams = FakeSeams()
    val dj = AutoDj(h.engine, seams, Random(seed))
    /** Decks the fake stream layer reports as waiting for bytes. */
    val held = HashSet<Deck>()
    val items: List<AutoMixItem>

    init {
        e.autoDj = dj
        e.streamHeldProvider = { it in held }
        items = (0 until n).map { AutoMixItem(tweak(it, h.addSong("s$it", seconds)), (seconds * 1000).toInt(), "crate") }
    }

    fun start(shuffled: Boolean = false) = dj.startAutoMix(items, shuffled, lead, fade, "crate")

    /** Advance the wall clock + engine tick in 100 ms steps. */
    fun run(sec: Double, stepMs: Long = 100) {
        var left = Math.round(sec * 1000)
        while (left > 0) { val s = minOf(stepMs, left); h.tick(s); left -= s }
    }

    fun id(d: Deck) = e.loaded(d)?.songId
    fun advLines() = h.diags.filter { it.startsWith("mixadvance") }
}

class AutoDjTest {
    private val A = Deck.A
    private val B = Deck.B

    // ---------------------------------------------------------------- start

    @Test fun startLoadsFirstTwoOntoDecksCentersNothingAndPlaysA() {
        val r = AutoRig()
        r.e.setCrossfader(0.7)
        r.h.recorder.events.clear()
        r.start()
        assertEquals("s0", r.id(A)); assertEquals("s1", r.id(B))
        assertEquals(0.0, r.e.crossfader, 0.0)
        assertTrue(r.e.isPlaying(A)); assertFalse(r.e.isPlaying(B))
        assertEquals(2, r.dj.nextToLoad)
        assertTrue(r.dj.isMixing); assertFalse(r.dj.isPaused)
        assertEquals("1 / 4 · Deck A", r.dj.autoStatus)
        // the auto start wiped both decks and says so honestly: .resetDeck x2, never a user .crossfader
        assertEquals(listOf("A", "B"), r.h.recorder.of(MixEventKind.ResetDeck).map { it.deck })
        assertTrue(r.h.recorder.of(MixEventKind.Crossfader).isEmpty())
    }

    @Test fun startEjectsAnAlreadyPlayingDeckAndItsParameters() {
        val r = AutoRig()
        r.e.load(r.h.addSong("old", 20.0), B)
        r.e.setVolume(1.5, B); r.e.setRate(1.3, B); r.e.setCued(true, B); r.e.play(B)
        r.start()
        assertEquals("s1", r.id(B))
        assertFalse(r.e.isPlaying(B))
        assertEquals(1.0, r.e.volume(B), 0.0)
        assertEquals(1.0, r.e.rate(B), 0.0)
        assertFalse(r.e.cued(B))
    }

    @Test fun startOpensOnAnOnDeviceSongWhenShuffled() {
        val r = AutoRig(n = 6)
        r.seams.onDevice = { it == "s4" }      // only s4 is fully on device
        r.dj.startAutoMix(r.items, shuffled = true, lead = 10.0, fade = 4.0)
        assertEquals("s4", r.id(A))
        assertTrue(r.advLines().any { it.contains("open on on-device s4") })
    }

    @Test fun unloadableLeadingItemsAreDroppedAndAllUnloadableMeansNoMix() {
        val r = AutoRig()
        r.h.removeSong("s0")
        r.start()
        assertEquals("s1", r.id(A)); assertEquals("s2", r.id(B))
        assertEquals(3, r.dj.queueSize)

        val none = AutoRig(n = 2)
        none.h.removeSong("s0"); none.h.removeSong("s1")
        none.start()
        assertFalse(none.dj.isMixing)
        assertEquals(0, none.dj.queueSize)
    }

    @Test fun emptyQueueIsAGuard() {
        val r = AutoRig()
        r.dj.startAutoMix(emptyList(), false, 10.0, 4.0)
        assertFalse(r.dj.isMixing)
    }

    // ---------------------------------------------------------------- natural transition

    @Test fun fadeSweepsOverFadeSecondsThenSilencesOutgoingAndPreloadsNextOntoIt() {
        val r = AutoRig()
        r.start()
        r.run(19.5)
        assertFalse("not yet at the lead", r.dj.autoTransitioning)
        assertEquals(0.0, r.e.crossfader, 0.0)
        r.run(1.0)                                // crosses secondsLeft <= lead (20 s)
        assertTrue(r.dj.autoTransitioning)
        assertTrue(r.e.isPlaying(B))
        r.run(1.5)
        assertEquals("mid fade", 0.5, r.e.crossfader, 0.05)
        r.run(3.0)                                // total > fade
        assertFalse(r.dj.autoTransitioning)
        assertEquals(1.0, r.e.crossfader, 0.0)
        assertFalse("outgoing silenced", r.e.isPlaying(A))
        assertTrue(r.e.isPlaying(B))
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals(1, r.dj.livePos)
        assertEquals("next preloaded onto the retired deck", "s2", r.id(A))
        assertEquals(3, r.dj.nextToLoad)
        assertEquals("2 / 4 · Deck B", r.dj.autoStatus)
        // auto sweeps never record user .crossfader gestures
        assertTrue(r.h.recorder.of(MixEventKind.Crossfader).isEmpty())
    }

    @Test fun theMixRunsThroughTheWholeQueueAndEndsExhausted() {
        val r = AutoRig(n = 3, seconds = 12.0, lead = 4.0, fade = 2.0)
        r.start()
        r.run(60.0)
        assertFalse(r.dj.isMixing)
        assertTrue("natural end arms the downloader pickup flag", r.e.autoEndedExhausted)
        assertEquals("fader recentered after a real mix", 0.5, r.e.crossfader, 0.0)
        assertFalse(r.e.isPlaying(A)); assertFalse(r.e.isPlaying(B))
    }

    @Test fun aManualLoadDisarmsTheExhaustedFlag() {
        val r = AutoRig(n = 2, seconds = 10.0, lead = 3.0, fade = 1.0)
        r.start(); r.run(40.0)
        assertTrue(r.e.autoEndedExhausted)
        r.e.load(r.h.addSong("hand", 5.0), A)
        assertFalse(r.e.autoEndedExhausted)
    }

    @Test fun userStopIsNotExhaustedAndPausesBoth() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.stopAutoMix()
        assertFalse(r.dj.isMixing)
        assertFalse(r.e.autoEndedExhausted)
        assertFalse(r.e.isPlaying(A))
        assertEquals(0.5, r.e.crossfader, 0.0)
    }

    // ---------------------------------------------------------------- skip

    @Test fun singleSkipUsesSkipFadeAndRestoresTheBaselineFade() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.skipToNext(2.0)
        assertTrue(r.dj.autoTransitioning)
        assertEquals(2.0, r.dj.fadeSeconds, 0.0)
        assertEquals(4.0, r.dj.pendingFadeRestore!!, 0.0)
        r.run(1.0)
        assertEquals(0.5, r.e.crossfader, 0.1)
        r.run(1.5)
        assertFalse(r.dj.autoTransitioning)
        assertEquals("baseline fade restored", 4.0, r.dj.fadeSeconds, 0.0)
        assertNull(r.dj.pendingFadeRestore)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals(1, r.dj.livePos)
    }

    @Test fun doubleSkipFadeIsFiveSecondsAndEndsTheListenAsASkip() {
        val r = AutoRig()
        val ended = ArrayList<Pair<String, MixTrackEndReason>>()
        r.e.onDeckTrackEnded = { id, _, _, reason, _ -> ended += id to reason }
        r.start(); r.run(3.0)
        r.dj.skipToNext(5.0)
        assertEquals(5.0, r.dj.fadeSeconds, 0.0)
        assertEquals("s0" to MixTrackEndReason.SKIP, ended.single())
        r.run(5.2)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals("the fade-finish natural report is a no-op after the skip", 1, ended.size)
    }

    @Test fun skipIsIgnoredMidFade() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.skipToNext(4.0)
        r.run(1.0)
        val xf = r.e.crossfader
        r.dj.skipToNext(1.0)                       // double-advance would jump the fader
        assertEquals(xf, r.e.crossfader, 0.0)
        assertEquals(4.0, r.dj.fadeSeconds, 0.0)
        assertTrue(r.advLines().any { it.contains("skip ignored") })
        r.run(4.0)
        assertEquals(1, r.dj.livePos)
    }

    @Test fun skipOnLastTrackEndsTheMixExhausted() {
        val r = AutoRig(n = 2)
        r.start(); r.run(3.0)
        r.dj.skipToNext(1.0); r.run(2.0)
        assertEquals(Deck.B, r.dj.liveDeck)
        r.dj.skipToNext(1.0)
        assertFalse(r.dj.isMixing)
        assertTrue(r.e.autoEndedExhausted)
    }

    @Test fun skipDuringAFadeFrozenOnABufferingIncomingBacksOutAndDefersThatSong() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.held += B                                 // standby is buffering
        r.dj.skipToNext(4.0)                        // begins a fade into the held deck (lenient fallback)
        r.run(0.3)
        assertTrue(r.dj.autoTransitioning)
        r.dj.skipToNext(4.0)                        // frozen on the buffering incoming: backs out and skips PAST it
        assertTrue(r.advLines().any { it.contains("abandon fade") && it.contains("skip while incoming buffering") })
        assertTrue(r.advLines().any { it.contains("skip: deferred buffering s1 to the end") })
        assertEquals("s1 moved behind the others", listOf("s0", "s2", "s3", "s1"), r.dj.queueSongIds)
    }

    // ---------------------------------------------------------------- fade cap

    @Test fun fadeIsCappedToTheRunwayLeftAndRestoredAfterwards() {
        val r = AutoRig()
        r.start(); r.run(2.0)
        r.e.seek(A, 29.0)                           // 1 s of runway: re-times the end clock
        assertEquals(2.0, r.dj.deckEndsAt[A]!! / 1000.0 - r.h.nowMs / 1000.0 + 1.0, 1.1)
        r.run(0.2)
        assertTrue(r.dj.autoTransitioning)
        assertEquals(4.0, r.dj.pendingFadeRestore!!, 0.0)
        assertTrue("capped but never under 0.5 s", r.dj.fadeSeconds in 0.5..1.0)
        r.run(2.0)
        assertFalse(r.dj.autoTransitioning)
        assertEquals(4.0, r.dj.fadeSeconds, 0.0)
        assertNull(r.dj.pendingFadeRestore)
    }

    @Test fun fadeCapFloorIsHalfASecond() {
        val r = AutoRig()
        r.start(); r.run(1.0)
        r.e.seek(A, 29.9)                           // 0.1 s left
        r.run(0.3)
        assertEquals(0.5, r.dj.fadeSeconds, 1e-9)
    }

    // ---------------------------------------------------------------- pause / resume

    @Test fun pauseAutoGatesOnlyTheTriggerAndRecordsOneMarker() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.pauseAuto()
        r.dj.pauseAuto()                            // idempotent
        assertEquals(1, r.h.recorder.of(MixEventKind.AutoPause).size)
        assertTrue(r.dj.isPaused)
        assertTrue("playback keeps running", r.e.isPlaying(A))
        r.run(40.0)                                 // way past the lead
        assertFalse(r.dj.autoTransitioning)
        assertEquals(Deck.A, r.dj.liveDeck)
        assertEquals(0, r.dj.livePos)
        assertTrue("a suspended machine retires a deck at its end like a manual deck", !r.e.isPlaying(A))
    }

    @Test fun resumeWithOneDeckRearmsFromItsRealRemainingTime() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.pauseAuto()
        r.e.seek(A, 5.0)                            // hand-seek while paused
        r.run(2.0)
        r.dj.resumeAuto()
        assertFalse(r.dj.isPaused)
        assertEquals(1, r.h.recorder.of(MixEventKind.AutoResume).size)
        val remaining = 30.0 - r.e.position(A)
        assertEquals(remaining, (r.dj.deckEndsAt[A]!! - r.h.nowMs) / 1000.0, 0.01)
        r.run(remaining - 10.5)                     // lead is 10 s: not yet
        assertFalse(r.dj.autoTransitioning)
        r.run(1.5)
        assertTrue(r.dj.autoTransitioning)
    }

    @Test fun resumeWithNothingPlayingRestartsTheLiveDeck() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.pauseAuto()
        r.e.pause(A)                                // paused auto: does not end the mix
        assertTrue(r.dj.isMixing)
        r.dj.resumeAuto()
        assertTrue(r.e.isPlaying(A))
        assertEquals("s0", r.id(A))
    }

    @Test fun resumeWithBothDecksBlendedKeepsTheLaterEndingAsSurvivorAndHandsOff() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.pauseAuto()
        r.e.play(B)                                 // hand-start B
        r.e.seek(B, 20.0)                           // B ends sooner (10 s left) than A (27 s left)
        r.run(0.5)
        r.dj.resumeAuto()
        assertEquals("A ends last: survivor", Deck.A, r.dj.liveDeck)
        r.run(10.2)                                 // B runs out
        assertTrue("handoff glides the survivor over to the freed deck", r.dj.autoTransitioning)
        assertEquals("freed deck B got the next unplayed track", "s2", r.id(B))
        r.run(4.5)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertFalse(r.e.isPlaying(A))
    }

    // ---------------------------------------------------------------- repeat

    @Test fun repeatOneReplaysTheSlotWithAFrozenCursor() {
        val r = AutoRig(n = 3, seconds = 12.0, lead = 4.0, fade = 2.0)
        r.start()
        r.dj.setAutoRepeat(AutoRepeatMode.ONE)
        r.run(9.0)                                  // lead reached
        assertTrue(r.dj.autoTransitioning)
        assertEquals("standby holds the SAME item", "s0", r.id(B))
        r.run(3.0)
        assertEquals(Deck.B, r.dj.liveDeck)
        assertEquals("cursor frozen", 0, r.dj.livePos)
        assertEquals("nextToLoad unconsumed", 2, r.dj.nextToLoad)
        assertEquals("s0", r.id(B))
        // an explicit skip overrides repeat-one
        r.dj.skipToNext(1.0); r.run(1.5)
        assertEquals(1, r.dj.livePos)
    }

    @Test fun repeatAllWrapsToIndexZeroWithAWrapPreload() {
        val r = AutoRig(n = 2, seconds = 12.0, lead = 4.0, fade = 2.0)
        r.start()
        r.dj.setAutoRepeat(AutoRepeatMode.ALL)
        r.run(9.0); r.run(3.0)                      // s0 -> s1
        assertEquals(1, r.dj.livePos)
        assertEquals(Deck.B, r.dj.liveDeck)
        r.run(5.0)                                  // the last track's lead (4 s) is reached at t=16
        assertTrue(r.dj.autoTransitioning)
        assertEquals("wrap preloaded the head onto the standby", "s0", r.id(A))
        r.run(3.0)
        assertEquals(0, r.dj.livePos)
        assertEquals("wrap reset to 1, then the retired deck preloaded slot 1", 2, r.dj.nextToLoad)
        assertEquals("s1", r.id(B))
        assertEquals(Deck.A, r.dj.liveDeck)
        assertTrue("never exhausted while repeating", r.dj.isMixing)
        assertFalse(r.e.autoEndedExhausted)
    }

    @Test fun repeatAllSkipOnTheLastTrackWraps() {
        val r = AutoRig(n = 2)
        r.start(); r.dj.setAutoRepeat(AutoRepeatMode.ALL)
        r.run(2.0); r.dj.skipToNext(1.0); r.run(1.5)
        r.dj.skipToNext(1.0); r.run(1.5)
        assertTrue(r.dj.isMixing)
        assertEquals(0, r.dj.livePos)
    }

    @Test fun cycleRepeatIsOffAllOneOff() {
        val r = AutoRig()
        assertEquals(AutoRepeatMode.OFF, r.dj.repeat)
        r.dj.cycleAutoRepeat(); assertEquals(AutoRepeatMode.ALL, r.dj.repeat)
        r.dj.cycleAutoRepeat(); assertEquals(AutoRepeatMode.ONE, r.dj.repeat)
        r.dj.cycleAutoRepeat(); assertEquals(AutoRepeatMode.OFF, r.dj.repeat)
    }

    // ---------------------------------------------------------------- remote freeze

    @Test fun remotePauseSuspendsNotEndsAndFreezesEveryArmedClock() {
        val r = AutoRig()
        r.start(); r.run(15.0)
        val endsBefore = r.dj.deckEndsAt[A]!!
        r.dj.remotePause()
        assertTrue("suspended, not ended", r.dj.isMixing && r.dj.isPaused)
        assertTrue(r.dj.remoteFrozen)
        assertFalse(r.e.isPlaying(A))
        r.h.nowMs += 60_000                         // a minute in the pocket
        r.h.tick(100)                               // engine tick: the machine must not fire
        assertFalse("no transition fired into silent decks", r.dj.autoTransitioning)
        assertFalse(r.e.isPlaying(B))
        r.dj.remotePlay()
        assertFalse(r.dj.remoteFrozen)
        assertFalse(r.dj.isPaused)
        assertTrue("only the parked deck resumed", r.e.isPlaying(A) && !r.e.isPlaying(B))
        val shift = r.dj.deckEndsAt[A]!! - endsBefore
        assertEquals("shifted by the frozen interval", 60_000.0, shift.toDouble(), 150.0)
    }

    @Test fun remotePauseMidFadeResumesWhereItStopped() {
        val r = AutoRig()
        r.start(); r.run(21.5)                      // 1.5 s into the 4 s fade
        assertTrue(r.dj.autoTransitioning)
        val before = r.e.crossfader
        r.dj.remotePause()
        r.h.nowMs += 30_000; r.h.tick(100)
        assertEquals("fader did not move while frozen", before, r.e.crossfader, 0.0)
        r.dj.remotePlay()
        r.run(0.2)
        assertEquals("a half-swept fade stays half-swept", before + 0.2 / 4 + 0.1 / 4, r.e.crossfader, 0.08)
        r.run(3.0)
        assertEquals(Deck.B, r.dj.liveDeck)
    }

    @Test fun duplicateRemotePauseKeepsTheFirstFreezeAndResumeIntent() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.remotePause()
        val frozeAt = r.dj.remotePausedAt
        r.h.nowMs += 5_000
        r.dj.remotePause()                          // Bluetooth head re-sends discrete PAUSE
        assertEquals(frozeAt, r.dj.remotePausedAt)
        assertTrue(r.h.diags.any { it.contains("remotePause guard=dup") })
        r.dj.remotePlay()
        assertFalse("the duplicate did not eat the resume intent", r.dj.isPaused)
    }

    @Test fun anInAppPauseDuringAPausedAutoStaysPausedAfterRemotePlay() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.pauseAuto()                            // the DJ stepped away in-app
        r.dj.remotePause()
        r.dj.remotePlay()
        assertTrue("remote play only undoes its own suspension", r.dj.isPaused)
    }

    @Test fun inAppMasterPauseEndsARunningAuto() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.e.pauseBoth()
        assertFalse(r.dj.isMixing)
        assertEquals(0.5, r.e.crossfader, 0.0)
    }

    @Test fun remoteSkipWhileSuspendedResumesOnTheNextTrack() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.remotePause()
        r.dj.remoteSkip(3.0)
        assertFalse(r.dj.isPaused)
        assertTrue(r.dj.autoTransitioning)
        r.run(3.5)
        assertEquals(Deck.B, r.dj.liveDeck)
    }

    // ---------------------------------------------------------------- engine stall

    @Test fun engineStallParksClocksAndUnparkShiftsThemPastTheStall() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        val ends = r.dj.deckEndsAt[A]!!
        r.dj.parkEngineStall()
        assertTrue(r.dj.engineStalled)
        r.h.nowMs += 12_000
        r.dj.fire(r.h.nowMs)                        // gated while stalled
        assertFalse(r.dj.autoTransitioning)
        r.dj.unparkEngineStall()
        assertFalse(r.dj.engineStalled)
        assertEquals(12_000.0, (r.dj.deckEndsAt[A]!! - ends).toDouble(), 1.0)
    }

    @Test fun stallParkIsSkippedWhileRemoteFrozen() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.remotePause()
        r.dj.parkEngineStall()
        assertFalse("stacked park would shift the clocks twice", r.dj.engineStalled)
    }

    @Test fun checkpointRebasesAnInProgressStall() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        r.dj.parkEngineStall()
        r.h.nowMs += 4_000
        val before = r.dj.deckEndsAt[A]!!
        r.dj.checkpointEngineStall()
        assertEquals(4_000.0, (r.dj.deckEndsAt[A]!! - before).toDouble(), 1.0)
        assertTrue("re-parked from now", r.dj.engineStalled)
    }

    @Test fun heldSecondsDoNotBurnTheLiveDecksRunway() {
        val r = AutoRig()
        r.start(); r.run(5.0)
        val ends = r.dj.deckEndsAt[A]!!
        r.held += A
        r.run(6.0)                                  // 6 s of Buffering...
        assertEquals("end clock advanced by exactly the held time", 6_000.0, (r.dj.deckEndsAt[A]!! - ends).toDouble(), 120.0)
        assertEquals("playhead frozen", 5.0, r.e.position(A), 0.15)
        assertFalse(r.dj.autoTransitioning)
    }

    // ---------------------------------------------------------------- persistence

    @Test fun snapshotRoundTripsThroughARestoreAsASuspendedMix() {
        val r = AutoRig()
        r.start(); r.run(23.0)                      // mid-fade into B
        r.run(2.0)
        r.dj.setAutoRepeat(AutoRepeatMode.ALL)
        val snap = r.dj.snapshot()!!
        assertEquals(1, snap.livePos); assertEquals(3, snap.nextToLoad)
        assertEquals("B", snap.liveDeck); assertEquals("all", snap.repeatMode)
        assertEquals(4, snap.queue.size)
        assertEquals("crate", snap.sourceLabel)

        val r2 = AutoRig()
        r2.dj.restoreSuspended(snap)
        assertTrue(r2.dj.isMixing && r2.dj.isPaused)
        assertEquals(AutoRepeatMode.ALL, r2.dj.repeat)
        assertEquals(1, r2.dj.livePos)
        assertEquals(Deck.B, r2.dj.liveDeck)
        assertTrue("nothing plays on restore", !r2.e.isPlaying(A) && !r2.e.isPlaying(B))
        assertEquals("1 of 4 persisted rows", 4, r2.dj.queueSize)
    }

    @Test fun snapshotCarriesThePendingFadeBaselineNotTheOneOffSkipFade() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.dj.skipToNext(1.0)
        assertEquals(4.0, r.dj.snapshot()!!.fadeSeconds, 0.0)
    }

    @Test fun noSnapshotWithoutAMix() {
        val r = AutoRig()
        assertNull(r.dj.snapshot())
        r.start(); assertNotNull(r.dj.snapshot())
        r.dj.stopAutoMix(); assertNull(r.dj.snapshot())
    }

    @Test fun restoredCuedStandbyBeatsThePlayLogOnFirstResume() {
        val r = AutoRig()
        // a restored mix: B holds the cued next (s1), A the live s0, cursor at 0
        r.e.load(r.items[0].loadable, A); r.e.load(r.items[1].loadable, B)
        r.dj.restoreSuspended(
            AutoSnapshot(
                queue = r.items.map { com.levi.pocketdj.mix.store.AutoRow(com.levi.pocketdj.mix.store.TrackRef(it.loadable.songId, it.loadable.title, it.loadable.artist), it.durationMs, it.sourceLabel) },
                livePos = 0, nextToLoad = 2, liveDeck = "A", leadSeconds = 10.0, fadeSeconds = 4.0, fxGlide = false, mixGlide = false,
            ),
        )
        r.h.recorder.played += "s1"                  // the log says s1 already "played" (a barely-begun fade before the kill)
        r.dj.resumeAuto()
        assertEquals("the cued standby is kept, not skipped past", "s1", r.id(B))
        assertEquals(0, r.dj.livePos)
        assertEquals(2, r.dj.nextToLoad)
    }

    // ---------------------------------------------------------------- loop / disabled

    @Test fun anEngagedLoopHoldsTheLiveDeckOnAir() {
        val r = AutoRig()
        r.start(); r.run(3.0)
        r.e.updateDeck(A) { it.copy(loopOn = true) }
        r.run(40.0)
        assertFalse(r.dj.autoTransitioning)
        assertEquals(0, r.dj.livePos)
    }

    @Test fun disablingAutoEndsTheLoop() {
        val r = AutoRig()
        r.start(); r.dj.setAutoEnabled(false)
        assertFalse(r.dj.isMixing)
    }
}
