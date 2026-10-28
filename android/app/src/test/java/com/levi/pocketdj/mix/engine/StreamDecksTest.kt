package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.longestSilence
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.rms
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamDecksTest {
    private val A = Deck.A
    private val B = Deck.B

    // ---------------------------------------------------------------- fakes

    private class FakeHandle(override val songId: String, override var expectedBytes: Long?) : StreamHandle {
        override var resolved = true
        override var bytesReceived = 0L
        override var isComplete = false
        override var failed = false
        override var isCut = true
        override var startMs: Long? = null
        override var file: java.io.File? = null
    }

    private class FakeLoader : StreamLoaderPort {
        val handles = HashMap<String, FakeHandle>()
        var gateOpen = true
        var opens = 0
        override fun canStream(songId: String) = gateOpen && songId in handles
        override fun isRipped(songId: String) = songId in handles
        override fun open(songId: String, title: String, artist: String): StreamHandle? =
            handles[songId]?.also { opens++ }
        override fun stream(songId: String): StreamHandle? = handles[songId]
    }

    private class FakeFactory(val source: () -> PcmSource) : StreamSourceFactory {
        var ready = true
        var opens = 0
        var completes = 0
        var made: PcmSource? = null
        override fun open(h: StreamHandle): PcmSource? {
            if (!ready) return null
            opens++
            return source().also { made = it }
        }
        override fun markComplete(src: PcmSource) {
            completes++
            (src as? SyntheticPcmSource)?.forceIncomplete = false
        }
    }

    private class HeldCountingAuto : AutoDjHooks {
        override var isMixing = true
        override var isPaused = false
        var heldSeconds = 0.0
        val seeks = ArrayList<Deck>()
        override fun endAutoLoop() { isMixing = false }
        override fun onDeckHeld(deck: Deck, dtSeconds: Double) { heldSeconds += dtSeconds }
        override fun onSeek(deck: Deck) { seeks += deck }
    }

    private class FakeAutoStream(var live: Deck? = null) : AutoStreamHooks {
        var skips = ArrayList<Double>()
        override fun isLiveDeck(deck: Deck) = deck == live
        override var isTransitioning = false
        override fun skipToNext(fadeSeconds: Double) { skips += fadeSeconds }
    }

    /** A 100 s song by default: 40 000 B/s so the frontier is bytes/40000 - 1.5 s. */
    private class Rig(val seconds: Double = 100.0) {
        val h = EngineHarness()
        val engine get() = h.engine
        val sr = h.sr
        val total = (seconds * sr).toLong()
        val bps = 40_000.0
        val handle = FakeHandle("s", (seconds * bps).toLong())
        val loader = FakeLoader().also { it.handles["s"] = handle }
        val src = SyntheticPcmSource(sr, 2, total, 0L) { f, _ ->
            (0.5 * Math.sin(2 * Math.PI * 220.0 * f / sr)).toFloat()
        }.also { it.forceIncomplete = true }
        val factory = FakeFactory { src }
        val fake = FakeStems(sr)
        val extras = MixDeckExtras(
            engine = engine, provider = fake,
            runner = { v -> h.voices += v; AutoCloseable { h.voices -= v } },
            scope = kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined),
            localGrid = { null }, downloadGrid = { null },
        )
        val decks = StreamDecks(engine, loader, factory, extras.stems).also { it.install() }
        val A = Deck.A

        fun load(lengthMs: Int? = null, id: String = "s") {
            engine.load(MixLoadable(id, "T", "Art", lengthMs = lengthMs), A)
        }

        /** [sec] seconds of audio have downloaded (decodable frontier = sec; schedulable = sec - 1.5). */
        fun download(sec: Double) {
            handle.bytesReceived = (sec * bps).toLong()
            src.available = (sec * sr).toLong()
            decks.streamProgressed("s")
        }

        fun finish() {
            handle.bytesReceived = handle.expectedBytes!!
            handle.isComplete = true
            src.available = total
            decks.streamProgressed("s")
        }

        fun run(sec: Double): FloatArray {
            val steps = Math.round(sec * 10).toInt()
            val out = FloatArray(steps * 4410 * 2)
            for (i in 0 until steps) {
                val b = h.render(4410)
                System.arraycopy(b, 0, out, i * 4410 * 2, b.size)
                h.tick(100)
            }
            return out
        }

        val frontier: Double get() = decks.frontierSeconds(A) ?: -1.0
    }

    // ---------------------------------------------------------------- pure rules

    @Test fun resumeRunwayIs4SecondsPlayingAnd2SecondsStopped() {
        val sr = 44_100
        val full = 100L * sr
        // stopped: frontier 2.0 s past the playhead is enough; 1.9 is not
        assertTrue(StreamRules.canResume(false, 2L * sr, 0, full, sr, playing = false))
        assertFalse(StreamRules.canResume(false, (1.9 * sr).toLong(), 0, full, sr, playing = false))
        // playing: needs 4 s
        assertFalse(StreamRules.canResume(false, (3.9 * sr).toLong(), 0, full, sr, playing = true))
        assertTrue(StreamRules.canResume(false, 4L * sr, 0, full, sr, playing = true))
        // the runway is capped at the window's end; the frontier must still be PAST the playhead
        assertTrue(StreamRules.canResume(false, 10L * sr, 9L * sr, 10L * sr, sr, playing = true))
        assertFalse(StreamRules.canResume(false, 9L * sr, 9L * sr, 10L * sr, sr, playing = true))
        // a complete stream always resumes
        assertTrue(StreamRules.canResume(true, 0, 5L * sr, full, sr, playing = true))
    }

    @Test fun appendChunkIsSmallWhileRunwayShortAndBigOnceComfortable() {
        assertEquals(1.0, StreamRules.appendChunk(0.0), 0.0)
        assertEquals(1.0, StreamRules.appendChunk(9.99), 0.0)
        assertEquals(15.0, StreamRules.appendChunk(10.0), 0.0)
    }

    @Test fun shouldHoldOnlyWhenTheFrontierIsShortOfTheSongAndThePlayheadCaughtIt() {
        assertTrue(StreamRules.shouldHold(frontierSec = 10.0, durationSec = 100.0, posSec = 9.96))
        assertFalse(StreamRules.shouldHold(10.0, 100.0, 9.9))
        assertFalse("frontier at the song's end is no underrun", StreamRules.shouldHold(99.97, 100.0, 99.99))
    }

    @Test fun readyToAirNeedsCompletionOrFifteenSecondsOfRunway() {
        assertFalse(StreamRules.readyToAir(true, true, 100.0, 0.0, 100.0))
        assertTrue(StreamRules.readyToAir(false, true, null, 0.0, 100.0))
        assertFalse(StreamRules.readyToAir(false, false, 14.9, 0.0, 100.0))
        assertTrue(StreamRules.readyToAir(false, false, 15.0, 0.0, 100.0))
        // near the end of a short song only what is left is required
        assertTrue(StreamRules.readyToAir(false, false, 9.95, 0.0, 10.0))
        assertFalse(StreamRules.readyToAir(false, false, null, 0.0, 10.0))
    }

    // ---------------------------------------------------------------- load / hold / start / resume

    @Test fun aDeckLoadedOnAStreamWithNoBytesShowsBufferingAndStaysSilent() {
        val r = Rig()
        r.load(lengthMs = 100_000)
        assertTrue(r.decks.isStreaming(A)); assertTrue(r.decks.isBuffering(A))
        assertEquals(setOf(A), r.decks.buffering.value); assertEquals(setOf(A), r.decks.streaming.value)
        assertEquals("s", r.engine.loaded(A)?.songId)
        assertEquals("catalog length is the provisional duration", 100.0, r.engine.duration(A), 0.0)
        assertEquals(setOf("s"), r.decks.streamingSongIds)
        assertFalse(r.engine.controller(A).isOpen)
        r.engine.play(A)
        assertTrue(r.engine.isPlaying(A))
        val out = r.run(1.0)
        assertEquals("playhead frozen while held", 0.0, r.engine.position(A), 0.0)
        assertEquals(out.size / 2, longestSilence(out, 0, out.size / 2, eps = 1e-6f))
    }

    @Test fun noCatalogLengthFallsBackToThreeMinutes() {
        val r = Rig(); r.load(lengthMs = null)
        assertEquals(180.0, r.engine.duration(A), 0.0)
    }

    @Test fun aClosedStreamGateLeavesTheDeckUntouched() {
        val r = Rig(); r.loader.gateOpen = false
        r.load()
        assertNull(r.engine.loaded(A))
        assertFalse(r.decks.isStreaming(A))
        assertEquals(0, r.loader.opens)
    }

    @Test fun aStoppedDeckStartsWithTwoSecondsOfRunwayAndTheRealWindowReplacesTheGuess() {
        val r = Rig(); r.load(lengthMs = 99_000)
        r.download(3.0)     // frontier 1.5 s: attached but short of the 2 s start runway
        assertTrue(r.engine.controller(A).isOpen)
        assertTrue(r.decks.isBuffering(A))
        assertEquals(0.0, r.frontier, 0.0)
        r.download(3.6)     // frontier 2.1 s
        assertFalse(r.decks.isBuffering(A))
        assertTrue(r.decks.isStreaming(A))
        assertEquals(2.1, r.frontier, 0.02)
        assertEquals("the header's real window replaces the catalog guess", 100.0, r.engine.duration(A), 0.0)
        assertEquals(2.1, r.decks.endSeconds(A), 0.02)
        assertTrue(r.decks.canGrow(A)); assertFalse(r.decks.complete(A))
    }

    @Test fun aPlayingDeckWaitsForFourSecondsThenPlaysAudibly() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(4.6)     // frontier 3.1 s < 4 s resume runway for a PLAYING deck
        assertTrue(r.decks.isBuffering(A))
        r.run(0.5)
        assertEquals(0.0, r.engine.position(A), 0.0)
        r.download(5.6)     // frontier 4.1 s
        assertFalse(r.decks.isBuffering(A))
        assertTrue(r.engine.controller(A).isVoicePlaying)
        val out = r.run(2.0)
        assertEquals(2.0, r.engine.position(A), 0.15)
        assertTrue("audible", rms(out, 22_050, 88_200, 0) > 0.1)
        assertTrue(longestSilence(out, 11_025, 88_200) < 300)
    }

    @Test fun theTickHoldsAtTheFrontierAndResumesWithFourSecondsNoMatterHowLongTheHold() {
        val r = Rig(); r.load(lengthMs = 100_000)
        val auto = HeldCountingAuto(); r.engine.autoDj = auto
        r.engine.play(A)
        r.download(5.6)     // frontier 4.1 s
        r.run(5.0)
        assertTrue("held at the frontier", r.decks.isBuffering(A))
        val heldAt = r.engine.position(A)
        assertEquals(4.1, heldAt, 0.1)
        assertTrue(r.engine.isPlaying(A))
        assertFalse("voice parked", r.engine.controller(A).isVoicePlaying)
        val auto0 = auto.heldSeconds
        r.run(1.0)
        r.run(1.0)
        assertEquals("a held playhead does not advance", heldAt, r.engine.position(A), 0.0)
        assertEquals("held seconds are reported to the auto machine (its end clock stops)", 2.0, auto.heldSeconds - auto0, 0.15)
        // 3 s of runway is not enough for a resume ...
        r.download(heldAt + 3.0 + 1.5)
        assertTrue(r.decks.isBuffering(A))
        // ... 4.5 s is
        r.download(heldAt + 4.5 + 1.5)
        assertFalse(r.decks.isBuffering(A))
        assertTrue(auto.seeks.contains(A))   // the auto end was re-stamped (held seconds pushed it back)
        val out = r.run(2.0)
        assertEquals(heldAt + 2.0, r.engine.position(A), 0.15)
        assertTrue(longestSilence(out, 11_025, out.size / 2) < 300)
        assertTrue("badge cleared", r.decks.buffering.value.isEmpty())
    }

    @Test fun theWindowGrowsInOneSecondChunksWhileTheRunwayIsShort() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(5.6)     // frontier 4.1
        val end0 = r.decks.endSeconds(A)
        r.download(6.0)     // +0.4 s: below the 1 s chunk
        assertEquals(end0, r.decks.endSeconds(A), 0.0)
        r.download(6.7)     // +1.1 s
        assertEquals(5.2, r.decks.endSeconds(A), 0.02)
    }

    @Test fun theWindowGrowsInBigChunksOnceTheRunwayIsComfortable() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.download(14.0)    // frontier 12.5 s, stopped deck: starts
        val end0 = r.decks.endSeconds(A)
        assertEquals(12.5, end0, 0.02)
        r.download(20.0)    // +6 s < 15 s chunk while 12.5 s of runway
        assertEquals(end0, r.decks.endSeconds(A), 0.0)
        r.download(28.0)    // +14.5 -> still below 15
        assertEquals(end0, r.decks.endSeconds(A), 0.0)
        r.download(30.0)    // +16 s
        assertEquals(28.5, r.decks.endSeconds(A), 0.02)
    }

    @Test fun anUnreadableHeaderKeepsTheDeckHeldUntilTheFileOpens() {
        val r = Rig(); r.factory.ready = false
        r.load(lengthMs = 100_000)
        r.download(30.0)
        assertFalse(r.engine.controller(A).isOpen)
        assertTrue(r.decks.isBuffering(A))
        r.factory.ready = true
        r.download(31.0)
        assertTrue(r.engine.controller(A).isOpen)
        assertFalse(r.decks.isBuffering(A))
    }

    @Test fun analogStartMsAndWindowBoundTheStreamedSideToTheSong() {
        val r = Rig(); r.handle.isCut = false; r.handle.startMs = 10_000
        r.load(lengthMs = 30_000)
        r.download(60.0)
        assertEquals("window = the catalog length, not the rest of the side", 30.0, r.engine.duration(A), 0.0)
        assertEquals(10_000, r.engine.deckState(A).startMs)
        assertEquals(10L * r.sr, r.engine.controller(A).startFrame)
    }

    // ---------------------------------------------------------------- completion

    @Test fun completionHandsTheDeckToTheFinishedFileWithNoSeamAndNoReopen() {
        val r = Rig(seconds = 12.0); r.load(lengthMs = 12_000)
        r.engine.play(A)
        r.download(6.0)
        val outs = ArrayList<FloatArray>()
        outs += r.run(0.5)
        val seeksAtStart = r.src.seekCount
        assertTrue(seeksAtStart >= 1)
        var downloaded = 6.0
        for (i in 0 until 10) {
            outs += r.run(0.5)
            downloaded = minOf(12.0, downloaded + 1.5)
            if (downloaded < 12.0) r.download(downloaded)
        }
        r.finish()
        assertFalse(r.decks.isStreaming(A))
        assertEquals(1, r.factory.completes)
        assertEquals("one open for the whole song: no swap", 1, r.factory.opens)
        assertEquals("no re-seek across the append boundaries", seeksAtStart, r.src.seekCount)
        assertEquals(r.total, r.engine.controller(A).endFrame)
        assertTrue(r.decks.complete(A)); assertFalse(r.decks.canGrow(A))
        outs += r.run(8.0)
        val all = FloatArray(outs.sumOf { it.size }); var o = 0
        for (b in outs) { System.arraycopy(b, 0, all, o, b.size); o += b.size }
        val frames = all.size / 2
        // 5 s of audio streamed in four appends + the finish: contiguous tone, no gap anywhere from 0.3 s to the end
        assertTrue("seam gap ${longestSilence(all, 20_000, 12 * r.sr - 4410)}", longestSilence(all, 20_000, 12 * r.sr - 4410) < 300)
        assertTrue(frames > 12 * r.sr)
        assertFalse("deck retired at the song's end", r.engine.isPlaying(A))
    }

    @Test fun theVoiceWindowEndsFinalOnlyWhenTheFileIsComplete() {
        val r = Rig(seconds = 8.0); r.load(lengthMs = 8_000)
        r.engine.play(A)
        r.download(8.0)     // every byte present but the transfer not complete: frontier = bytes - margin
        val v: Voice = r.engine.controller(A).voice!!
        for (i in 0 until 9) r.h.render(44_100)      // (no engine ticks: nothing retires the deck)
        assertEquals("a non-final window UNDERRUNS at the frontier", Voice.Status.UNDERRUN, v.status)
        assertTrue(r.decks.isStreaming(A))
        r.finish()
        for (i in 0 until 5) r.h.render(44_100)
        assertEquals("final once complete: the voice ends, it does not underrun", Voice.Status.ENDED, v.status)
    }

    // ---------------------------------------------------------------- failure

    @Test fun failureBeforeAudioEjectsTheDeckAndSkipsAHalfSecondIfItWasLive() {
        val r = Rig(); r.load(lengthMs = 100_000)
        val live = FakeAutoStream(live = A); r.decks.autoHooks = live
        r.engine.autoDj = HeldCountingAuto()
        r.engine.play(A)
        r.handle.failed = true
        r.decks.streamProgressed("s")
        assertNull("track dropped", r.engine.loaded(A))
        assertFalse(r.engine.isPlaying(A))
        assertFalse(r.decks.isStreaming(A))
        assertEquals(listOf(0.5), live.skips)
        assertTrue(r.decks.buffering.value.isEmpty())
    }

    @Test fun failureBeforeAudioOnAStoppedDeckJustEjectsIt() {
        val r = Rig(); r.load(lengthMs = 100_000)
        val live = FakeAutoStream(live = Deck.B); r.decks.autoHooks = live
        r.handle.failed = true
        r.decks.streamProgressed("s")
        assertNull(r.engine.loaded(A))
        assertTrue(live.skips.isEmpty())
    }

    @Test fun failureMidSongTruncatesTheDurationAndRestampsTheAutoEnd() {
        val r = Rig(); r.load(lengthMs = 100_000)
        val auto = HeldCountingAuto(); r.engine.autoDj = auto
        r.engine.play(A)
        r.download(11.5)     // frontier 10 s
        r.run(2.0)
        auto.seeks.clear()
        r.handle.failed = true
        r.decks.streamProgressed("s")
        assertEquals("the bytes we have ARE the song", 10.0, r.engine.duration(A), 0.02)
        assertEquals(listOf(A), auto.seeks)
        auto.isMixing = false       // (a running auto machine, not the tick, retires a deck at its end)
        assertFalse(r.decks.isStreaming(A))
        assertNotNull(r.engine.loaded(A))
        r.run(9.0)   // plays out to the frontier and retires
        assertFalse(r.engine.isPlaying(A))
        assertEquals(10.0, r.engine.position(A), 0.15)
    }

    @Test fun failureWhileHeldReleasesTheHoldAtTheNewEnd() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(5.6)
        r.run(5.0)
        assertTrue(r.decks.isBuffering(A))
        r.handle.failed = true
        r.decks.streamProgressed("s")
        assertFalse(r.decks.isBuffering(A))
        assertEquals(r.engine.duration(A), 4.1, 0.05)
        assertTrue(r.engine.position(A) <= r.engine.duration(A))
    }

    @Test fun aCompleteFileThatWillNotOpenFailsTheDeck() {
        val r = Rig(); r.factory.ready = false
        r.load(lengthMs = 100_000)
        r.finish()
        assertNull(r.engine.loaded(A))
    }

    // ---------------------------------------------------------------- seeks, restart, replace

    @Test fun aSeekPastTheFrontierHoldsAtTheTargetAndResumesThereWithRunway() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(11.5)     // frontier 10 s
        r.run(1.0)
        r.engine.seek(A, 50.0)
        assertTrue(r.decks.isBuffering(A))
        assertEquals(50.0, r.engine.position(A), 0.0)
        assertFalse(r.engine.controller(A).isVoicePlaying)
        r.run(1.0)
        assertEquals("held at the target", 50.0, r.engine.position(A), 0.0)
        r.download(53.0)     // frontier 51.5: 1.5 s of runway < 4
        assertTrue(r.decks.isBuffering(A))
        r.download(56.0)     // frontier 54.5
        assertFalse(r.decks.isBuffering(A))
        r.run(1.0)
        assertEquals(51.0, r.engine.position(A), 0.15)
        // the voice is decoding from the target, not from 0:00
        assertTrue(r.src.position > 50L * r.sr)
    }

    @Test fun aSeekInsideTheFrontierNeverHolds() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(21.5)
        r.run(0.5)
        r.engine.seek(A, 12.0)
        assertFalse(r.decks.isBuffering(A))
        assertTrue(r.engine.controller(A).isVoicePlaying)
    }

    @Test fun aSeekBeforeTheFirstBytesHoldsThePlayheadThere() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.seek(A, 30.0)
        assertEquals(30.0, r.engine.position(A), 0.0)
        assertTrue(r.decks.isBuffering(A))
        r.download(40.0)    // frontier 38.5; stopped deck needs 2 s past 30 s
        assertFalse(r.decks.isBuffering(A))
        assertEquals(30.0, r.engine.position(A), 0.0)
    }

    @Test fun restartOfAHeldDeckRewindsTheHeldPlayhead() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(5.6)
        r.run(5.0)
        assertTrue(r.decks.isBuffering(A))
        r.engine.restart(A)
        // 0:00 already has runway (4.1 s) so the pump starts it right away
        assertFalse(r.decks.isBuffering(A))
        assertEquals(0.0, r.engine.position(A), 0.0)
        r.run(1.0)
        assertEquals(1.0, r.engine.position(A), 0.15)
    }

    @Test fun pausingAHeldDeckLowersTheBarFromFourSecondsToTwo() {
        val r = Rig(); r.load(lengthMs = 100_000)
        r.engine.play(A)
        r.download(5.6)
        r.run(5.0)
        val heldAt = r.engine.position(A)
        r.download(heldAt + 3.0 + 1.5)       // 3 s of runway: short of a PLAYING deck's 4 s
        assertTrue(r.decks.isBuffering(A))
        r.engine.pause(A)
        r.decks.streamProgressed("s")        // the next progress event: a STOPPED deck only needs 2 s
        assertFalse(r.decks.isBuffering(A))
        assertFalse("paused deck stays silent", r.engine.controller(A).isVoicePlaying)
        r.engine.play(A)
        assertTrue(r.engine.controller(A).isVoicePlaying)
        val out = r.run(1.5)
        assertEquals(heldAt + 1.5, r.engine.position(A), 0.15)
        assertTrue(longestSilence(out, 11_025, out.size / 2) < 300)
    }

    @Test fun loadingAFileOverAStreamDropsTheStream() {
        val r = Rig(); r.load(lengthMs = 100_000)
        assertTrue(r.decks.isStreaming(A))
        r.engine.loadFile(java.io.File("/fake/x.mp3"), null, null, com.levi.pocketdj.mix.model.LoadedTrack("x", "X", "Y"), A)
            .also { assertFalse("no opener for x.mp3", it) }
        r.h.addSong("x", 5.0)
        r.engine.load(MixLoadable("x", "X", "Y"), A)
        assertFalse(r.decks.isStreaming(A))
        assertEquals("x", r.engine.loaded(A)?.songId)
        assertTrue(r.decks.buffering.value.isEmpty())
    }

    @Test fun ejectingTheDeckDropsTheStreamAndPinnedIds() {
        val r = Rig(); r.load(lengthMs = 100_000)
        assertEquals(setOf("s"), r.decks.streamingSongIds)
        r.engine.clearDeck(A)
        assertFalse(r.decks.isStreaming(A))
        assertTrue(r.decks.streamingSongIds.isEmpty())
        assertTrue(r.decks.buffering.value.isEmpty())
    }

    @Test fun pinnedIdsCoverBothDecksStreams() {
        val r = Rig()
        r.loader.handles["t"] = FakeHandle("t", null)
        r.load(lengthMs = 100_000)
        r.engine.load(MixLoadable("t", "T2", "Art", lengthMs = 50_000), B)
        assertEquals(setOf("s", "t"), r.decks.streamingSongIds)
        assertEquals(setOf(A, B), r.decks.streaming.value)
    }

    // ---------------------------------------------------------------- readiness + queue

    @Test fun readinessIsStrictForTheLiveTransitionAndLenientForPlayability() {
        val r = Rig(); r.load(lengthMs = 100_000)
        assertFalse(r.decks.deckReadyToAir(A)); assertFalse(r.decks.deckCanAir(A))
        r.download(11.5)          // frontier 10 s, started
        assertTrue("sound right now", r.decks.deckCanAir(A))
        assertFalse("but <15 s of runway", r.decks.deckReadyToAir(A))
        r.download(20.0)          // frontier 18.5 (chunk policy: 8.5 s > 15? no -> stays 10)
        r.download(30.0)          // +20 s
        assertTrue(r.decks.deckReadyToAir(A))
        r.finish()
        assertTrue(r.decks.deckReadyToAir(A))
        assertFalse(r.decks.deckReadyToAir(B))
    }

    @Test fun songOnDeviceAndTransientGate() {
        val r = Rig()
        assertFalse(r.decks.songOnDevice("s"))
        r.handle.isComplete = true
        assertTrue("a finished stream airs at once", r.decks.songOnDevice("s"))
        r.handle.failed = true
        assertFalse(r.decks.songOnDevice("s"))
        r.loader.gateOpen = false
        assertTrue("ripped but the gate is closed right now", r.decks.transientlyUnloadable("s"))
        assertFalse("never ripped: permanent", r.decks.transientlyUnloadable("zzz"))
    }

    @Test fun autoUpcomingSongIdsIsEmptyUnlessAutoMixing() {
        val r = Rig()
        r.decks.upcomingProvider = { listOf("a", "b") }
        assertTrue(r.decks.autoUpcomingSongIds.isEmpty())
        r.engine.autoDj = HeldCountingAuto()
        assertEquals(listOf("a", "b"), r.decks.autoUpcomingSongIds)
    }

    @Test fun canStreamPassesThroughTheLoaderGate() {
        val r = Rig()
        assertTrue(r.decks.canStream("s")); assertFalse(r.decks.canStream("nope"))
        r.loader.gateOpen = false
        assertFalse(r.decks.canStream("s"))
    }

    // ---------------------------------------------------------------- stems

    @Test fun aDeadFullMixUnderStemsMarksItTruncatedAndKeepsTheDeckOnStems() {
        val r = Rig(seconds = 20.0); r.load(lengthMs = 20_000)
        r.fake.local["s"] = {
            StemParts(List(4) { SyntheticPcmSource.tone(220.0, 20L * r.sr, r.sr, 0.125f) }, complete = true)
        }
        r.engine.play(A)
        r.download(13.5)           // frontier 12 s
        r.run(1.0)
        r.extras.stems.setStemMode(true, A)
        r.run(1.0)
        assertTrue("complete stems carry the deck", r.extras.stems.active(A))
        r.handle.failed = true
        r.decks.streamProgressed("s")
        assertTrue(r.decks.truncated(A))
        assertFalse(r.decks.canGrow(A)); assertFalse(r.decks.complete(A))
        assertFalse(r.decks.isStreaming(A))
        assertTrue("the song is NOT ejected", r.engine.loaded(A) != null)
        assertTrue(r.extras.stems.active(A))
        // complete stems cover the whole song: the duration is not cut short
        assertEquals(20.0, r.engine.duration(A), 0.0)
        // a later load clears the mark
        r.engine.clearDeck(A)
        assertFalse(r.decks.truncated(A))
    }

    @Test fun theFullMixesReachFeedsTheStemMachineAndItsProgressReleasesAStemHold() {
        val r = Rig(seconds = 30.0); r.load(lengthMs = 30_000)
        assertEquals("nothing attached yet", 0.0, r.decks.endSeconds(A), 0.0)
        r.download(11.5)           // frontier 10 s
        assertEquals(10.0, r.decks.endSeconds(A), 0.02)
        assertTrue(r.decks.canGrow(A))
        r.finish()
        assertEquals(30.0, r.decks.endSeconds(A), 0.0)
        assertTrue(r.decks.complete(A))
    }

    @Test fun stemStreamPartsGrowInLockstepAndTheFrontierIsTheSlowestPart() {
        val r = Rig(seconds = 30.0); r.load(lengthMs = 30_000)
        r.engine.play(A)
        r.download(21.5)           // full mix frontier 20 s, playing
        r.run(0.5)
        val total = 30L * r.sr
        val parts = List(4) { i ->
            SyntheticPcmSource(r.sr, 2, total, (12.0 * r.sr).toLong()) { f, _ ->
                (0.125 * Math.sin(2 * Math.PI * 220.0 * f / r.sr)).toFloat()
            }.also { it.forceIncomplete = true; if (i == 2) it.available = (9.0 * r.sr).toLong() }
        }
        val stream = FakeStemStream("s", parts, r.sr)
        r.fake.streams["s"] = stream
        r.extras.stems.setStemMode(true, A)
        assertEquals(9.0, r.extras.stems.reach(A)!!.frontierSec!!, 0.02)
        parts.forEach { it.available = (15.0 * r.sr).toLong() }
        parts[2].available = (14.0 * r.sr).toLong()
        r.extras.stems.streamProgressed("s")
        assertEquals("slowest part", 14.0, r.extras.stems.reach(A)!!.frontierSec!!, 0.02)
    }
}
