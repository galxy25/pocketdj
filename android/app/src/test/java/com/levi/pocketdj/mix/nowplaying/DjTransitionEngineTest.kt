package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.engine.MixSourceOpener
import com.levi.pocketdj.mix.engine.VoiceRunner
import com.levi.pocketdj.mix.graph.ParamsComposer
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.playback.dj.AutoTransition
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * P2-DJ-7: the two-deck ("ping-pong") transition engine, driven offline: synthetic tones through a real
 * [NowPlayingDspEngine] + MixGraph, a fake clock advanced by the rendered frames, the ticker stepped by hand.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DjTransitionEngineTest {
    private val sr = 44_100

    private class Rig(songSeconds: Int = 10) {
        val sr = 44_100
        var now = 0.0
        val scope = TestScope(StandardTestDispatcher())
        val voices = ArrayList<Voice>()
        var sink: OfflineRenderer? = null
        var unreadable = setOf<String>()
        val opener = MixSourceOpener { f ->
            if (f.name in unreadable) null
            else {
                val freq = if (f.name.startsWith("next")) 660.0 else 440.0
                SyntheticPcmSource.tone(freq, sr.toLong() * songSeconds, sr, 0.5f) as PcmSource
            }
        }
        val engine = NowPlayingDspEngine(
            sinkFactory = { OfflineRenderer(sr, 512).also { sink = it } },
            opener = opener,
            runner = VoiceRunner { v -> voices += v; AutoCloseable { voices.remove(v) } },
            stemSource = object : DspStemSource {
                override fun localParts(songId: String): Map<String, File> = emptyMap()
                override fun obtainable(songId: String) = false
                override suspend fun fetch(songId: String, parts: List<String>) = false
            },
            scope = scope,
            djClock = { now },
            djTicker = false,
        )
        val events = ArrayList<String>()
        var fadeStartAccepts = true

        init {
            engine.dj.onFadeStart = { events += "fade:$it"; fadeStartAccepts }
            engine.dj.onTransitionEnded = { id, how -> events += "end:$id:$how" }
            engine.dj.onHandBack = { events += "back" }
            engine.dj.onDeclined = { events += "declined:$it" }
        }

        fun pump() {
            var guard = 0
            do { var any = false; for (v in voices.toList()) while (v.pump()) any = true; guard++ } while (any && guard < 100)
        }

        /** Render [frames], advancing the fake clock with the audio, stepping the DJ timeline and the host tick every block. */
        fun render(frames: Int): FloatArray {
            val out = FloatArray(frames * 2)
            var done = 0
            while (done < frames) {
                pump()
                val n = minOf(512, frames - done)
                val b = sink!!.renderFrames(n)
                System.arraycopy(b, 0, out, done * 2, n * 2)
                done += n
                now += n.toDouble() / sr
                engine.dj.step()
                engine.tick()
                scope.testScheduler.runCurrent()
            }
            return out
        }

        fun seconds(s: Double) = render(Math.round(s * sr).toInt())

        fun engageSong(id: String = "s1", file: String = "song.mp3", at: Double = 0.0) {
            check(engine.engage(File(file), 0, 0, at, play = true))
            engine.bindSong(id)
        }

        fun speed(d: Deck) = engine.djParams(d).speed.toDouble()
    }

    private val noGlide = AutoTransition.Plan(false, 0.0, 1.0, 0.0, null)

    private fun spec(
        plan: AutoTransition.Plan = noGlide, glide: AutoTransition.GlideTargets = AutoTransition.identityGlide,
        id: String = "s2", file: String = "next.mp3", levelDb: Double = 0.0,
        outBeat: AutoTransition.BeatRef = AutoTransition.BeatRef(null), inBeat: AutoTransition.BeatRef = AutoTransition.BeatRef(null),
        texture: AutoTransition.Texture? = null,
    ) = DjTransitionSpec(plan, glide, texture, outBeat, DjIncoming(id, File(file), beat = inBeat, levelDb = levelDb))

    private fun rms(buf: FloatArray, from: Int, to: Int): Double {
        var s = 0.0
        for (i in from until to) s += buf[2 * i].toDouble() * buf[2 * i]
        return sqrt(s / (to - from))
    }

    private fun db(r: Double, ref: Double) = 20 * log10(r / ref)

    // ---------------------------------------------------------------- the crossfade

    @Test fun equalPowerSumStaysWithinHalfADbAcrossTheFade() {
        val r = Rig()
        r.engageSong()
        val before = r.seconds(1.0)
        val ref = rms(before, sr / 2, sr)           // outgoing alone: 0.5 / sqrt2
        assertEquals(0.3536, ref, 0.01)
        assertNull(r.engine.dj.beginTransition(spec()))
        val fade = r.seconds(1.0)
        for (k in 0 until 10) {
            val w = rms(fade, k * 4410, (k + 1) * 4410)
            assertEquals("window $k power vs the solo level", 0.0, db(w, ref), 0.5)
        }
        val after = r.seconds(0.5)
        assertEquals("the incoming alone lands at the same level", 0.0, db(rms(after, 4410, 22050), ref), 0.5)
    }

    @Test fun theLiveDeckFlipsAndTheListenerControlsFollowIt() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertNull(r.engine.dj.beginTransition(spec()))
        assertEquals(DjPhase.FADING, r.engine.dj.phase)
        assertEquals("the crossfader sits at the live deck's end only after the fade", 0f, r.engine.djCrossfaderForTest(), 0.5f)
        r.seconds(1.2)
        assertEquals(Deck.B, r.engine.liveDeck)
        assertEquals(1f, r.engine.djCrossfaderForTest(), 0f)
        assertEquals("s2", r.engine.engagedSongId)
        assertEquals(listOf("fade:s2", "end:s2:complete"), r.events)
        assertFalse(r.engine.dj.isTransitioning)
        assertFalse(r.engine.dj.tailPresent)
        // controls are re-pointed at deck B
        r.engine.setRate(1.25)
        assertEquals(1.25, r.speed(Deck.B), 1e-6)
        assertEquals(1.0, r.speed(Deck.A), 1e-6)
        assertEquals("only the incoming voice is left running", 1, r.voices.size)
    }

    @Test fun theSecondTransitionPingPongsBackToDeckA() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec())
        r.seconds(1.5)
        assertEquals(Deck.B, r.engine.liveDeck)
        assertNull(r.engine.dj.beginTransition(spec(id = "s3", file = "song.mp3")))
        r.seconds(1.5)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertEquals(0f, r.engine.djCrossfaderForTest(), 0f)
        assertEquals("s3", r.engine.engagedSongId)
        assertEquals(1, r.voices.size)
    }

    @Test fun theIncomingStartsAtItsBeatPhaseAlignedPosition() {
        val r = Rig()
        r.engageSong()
        r.seconds(4.25)                              // 120 bpm, beat 0.5 s: the outgoing sits half a beat in
        val pos = r.engine.currentTimeSec
        val phase = (pos / 0.5) % 1.0
        val expected = (phase - 0.0) * 0.5           // the incoming (phase 0 at its start) waits this long
        assertNull(r.engine.dj.beginTransition(spec(outBeat = AutoTransition.BeatRef(120.0), inBeat = AutoTransition.BeatRef(120.0))))
        r.render(512 * 3)
        val inc = r.voices.first { it.name == "np-dsp-in" }
        val started = inc.playerFrame
        assertTrue("incoming starts ~${expected}s in (frame $started)", started >= Math.round(expected * sr) && started <= Math.round(expected * sr) + 512 * 4)
    }

    // ---------------------------------------------------------------- glide + leveling

    @Test fun glideRampsOutgoingThenPinsThenEasesTheIncomingToIdentity() {
        val r = Rig(songSeconds = 12)
        r.engageSong()
        r.seconds(1.0)
        val plan = AutoTransition.Plan(true, 2.0, 1.0, 1.0, null)
        val glide = AutoTransition.GlideTargets(outRate = 1.2, outPitch = 2.0, inRate = 0.8, inPitch = -2.0)
        assertNull(r.engine.dj.beginTransition(spec(plan, glide)))
        assertEquals(DjPhase.PREROLL, r.engine.dj.phase)
        assertEquals("the incoming waits at its glide start", 0.8, r.speed(Deck.B), 1e-6)
        r.seconds(1.0)                                // half the pre-roll
        assertEquals(1.1, r.speed(Deck.A), 0.02)
        assertEquals(1.0, r.engine.djParams(Deck.A).pitchSemitones.toDouble(), 0.1)
        r.seconds(1.2)                                // fade started
        assertEquals(DjPhase.FADING, r.engine.dj.phase)
        assertEquals("the tail is pinned at its out target", 1.2, r.speed(Deck.A), 1e-6)
        assertEquals(0.8, r.speed(Deck.B), 0.02)
        r.seconds(1.4)                                // post-roll under way
        assertEquals(DjPhase.POSTROLL, r.engine.dj.phase)
        assertTrue(r.speed(Deck.B) in 0.8..1.0)
        r.seconds(1.0)
        assertEquals(1.0, r.speed(Deck.B), 1e-6)
        assertEquals(0.0, r.engine.djParams(Deck.B).pitchSemitones.toDouble(), 1e-6)
        assertEquals("end:s2:complete", r.events.last())
    }

    @Test fun levelingRidesTheIncomingTrimAndNeverTouchesTheBoost() {
        val r = Rig()
        r.engageSong()
        r.seconds(0.5)
        assertNull(r.engine.dj.beginTransition(spec(levelDb = -3.5)))
        assertEquals(-3.5, r.engine.djParams(Deck.B).trimDb.toDouble(), 1e-4)
        assertEquals(0.0, r.engine.djParams(Deck.A).trimDb.toDouble(), 1e-4)
        r.seconds(1.5)
        assertEquals("the level follows the song onto the live deck", -3.5, r.engine.djParams(Deck.B).trimDb.toDouble(), 1e-4)
        assertEquals("the retired deck is back to 0 dB", 0.0, r.engine.djParams(Deck.A).trimDb.toDouble(), 1e-4)
    }

    @Test fun composerLevelAddsToTheBoostWithoutABoostWrite() {
        val c = ParamsComposer()
        c.setVolume(Deck.A, 2.0)
        val boost = c.current.a.trimDb
        val writes = c.boostWrites
        c.setLevelDb(Deck.A, -4.0)
        assertEquals(boost - 4f, c.current.a.trimDb, 1e-4f)
        assertEquals(writes, c.boostWrites)
        c.setCrossfader(0.3f)
        assertEquals("a crossfader move keeps the leveled trim", boost - 4f, c.current.a.trimDb, 1e-4f)
        assertEquals(0f, c.current.b.trimDb, 0f)
        c.setLevelDb(Deck.A, 0.0)
        assertEquals(boost, c.current.a.trimDb, 1e-4f)
    }

    // ---------------------------------------------------------------- cuts

    @Test fun aCutBeforeTheAdvanceHandsTheOutgoingBackAtItsPlayheadAndEasesTheGlideOut() {
        val r = Rig(songSeconds = 12)
        r.engageSong()
        r.seconds(1.0)
        val plan = AutoTransition.Plan(true, 3.0, 1.0, 1.0, null)
        assertNull(r.engine.dj.beginTransition(spec(plan, AutoTransition.GlideTargets(1.2, 0.0, 0.8, 0.0))))
        r.seconds(1.5)
        val at = r.engine.currentTimeSec
        r.engine.dj.cutTransition("stems")
        assertEquals(listOf("back", "end:null:stems"), r.events)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertEquals("s1", r.engine.engagedSongId)
        assertTrue("the song is still playing", r.engine.isPlaying)
        assertEquals(1, r.voices.size)               // the incoming deck was released
        assertFalse(r.engine.dj.isTransitioning)
        assertTrue(r.engine.dj.isEasing)
        assertTrue("the glide is still on at the instant of the cut", r.speed(Deck.A) > 1.05)
        r.seconds(0.3)
        assertTrue(r.speed(Deck.A) in 1.0..1.1)
        r.seconds(0.4)
        assertEquals("eased fully out in 0.5 s", 1.0, r.speed(Deck.A), 1e-6)
        assertFalse(r.engine.dj.isEasing)
        assertEquals(0f, r.engine.djCrossfaderForTest(), 0f)
        assertTrue("playhead carried on from the cut", r.engine.currentTimeSec > at)
        assertFalse(r.events.any { it.startsWith("fade:") })
    }

    @Test fun aCutAfterTheAdvanceRampsTheTailOutAndKeepsTheIncoming() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec())
        r.seconds(0.3)
        assertTrue(r.engine.dj.tailPresent)
        r.engine.dj.cutTransition("manual")
        assertTrue("the tail leaves over a short ramp, not at once", r.engine.dj.tailPresent)
        r.seconds(0.1)
        assertFalse(r.engine.dj.tailPresent)
        assertEquals(1f, r.engine.djCrossfaderForTest(), 0f)
        assertEquals(1, r.voices.size)
        assertEquals(Deck.B, r.engine.liveDeck)
        assertEquals("end:s2:cut", r.events.last())
        assertTrue(r.engine.isPlaying)
    }

    @Test fun pauseHoldsBothDecksAndTheTimeline() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec())
        r.seconds(0.4)
        r.engine.pause()
        val tailVoice = r.engine.dj.voiceForTest()!!
        assertFalse(tailVoice.isPlaying)
        assertFalse(r.engine.djOutgoingPlaying())
        val p = r.engine.dj.fadeProgress
        r.seconds(2.0)
        assertEquals("the fade does not run while paused", p, r.engine.dj.fadeProgress, 1e-9)
        assertEquals(DjPhase.FADING, r.engine.dj.phase)
        r.engine.play()
        assertTrue(tailVoice.isPlaying)
        assertTrue(r.engine.djOutgoingPlaying())
        r.seconds(1.0)
        assertEquals(DjPhase.IDLE, r.engine.dj.phase)
    }

    @Test fun aSeekCutsTheOtherDeck() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec())
        r.seconds(0.3)
        r.engine.seekTo(2.0)
        r.seconds(0.2)
        assertFalse(r.engine.dj.tailPresent)
        assertEquals(Deck.B, r.engine.liveDeck)
        assertEquals(1, r.voices.size)
        assertTrue("the seek landed on the live (incoming) song", r.engine.currentTimeSec in 1.9..2.6)
    }

    @Test fun aSeekInThePreRollHandsTheOutgoingBack() {
        val r = Rig(songSeconds = 12)
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec(AutoTransition.Plan(true, 3.0, 1.0, 0.0, null), AutoTransition.GlideTargets(1.1, 0.0, 0.9, 0.0)))
        r.seconds(0.5)
        r.engine.seekTo(5.0)
        r.seconds(0.1)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertFalse(r.engine.dj.isTransitioning)
        assertEquals("end:null:seek", r.events.last())
        assertEquals(1, r.voices.size)
    }

    @Test fun stopCutsEverything() {
        val r = Rig()
        r.engageSong()
        r.seconds(1.0)
        r.engine.dj.beginTransition(spec())
        r.seconds(0.3)
        assertEquals(2, r.voices.size)
        r.engine.disengage()
        assertEquals(0, r.voices.size)
        assertFalse(r.engine.dj.isTransitioning)
        assertFalse(r.engine.dj.tailPresent)
        assertEquals("end:s2:stop", r.events.last())
        assertFalse(r.engine.isEngaged)
    }

    @Test fun aListenerTouchEndsTheGlideWithoutAJumpAndTheFadeCarriesOn() {
        val r = Rig(songSeconds = 12)
        r.engageSong()
        r.seconds(1.0)
        val plan = AutoTransition.Plan(true, 2.0, 1.0, 1.0, null)
        r.engine.dj.beginTransition(spec(plan, AutoTransition.GlideTargets(1.2, 0.0, 0.8, 0.0)))
        r.seconds(0.8)
        r.engine.setRate(1.25)
        assertTrue(r.engine.dj.glideDropped)
        assertEquals("the listener's value, not listener x ramp", 1.25, r.speed(Deck.A), 1e-9)
        r.seconds(0.6)
        assertEquals("the ramp no longer moves it", 1.25, r.speed(Deck.A), 1e-9)
        assertEquals("the incoming waits plain", 1.0, r.speed(Deck.B), 1e-9)
        r.seconds(1.0)
        assertEquals(DjPhase.FADING, r.engine.dj.phase)
        r.seconds(1.2)
        assertEquals(Deck.B, r.engine.liveDeck)
        assertEquals(1.0, r.speed(Deck.B), 1e-9)
        assertEquals("end:s2:listener", r.events.last())
    }

    // ---------------------------------------------------------------- declines + commit rules

    @Test fun declinesAreReportedAndNothingIsTouched() {
        val r = Rig()
        // idle engine
        assertEquals(DjEngineDecline.NOT_PLAYING, r.engine.dj.beginTransition(spec()))
        r.engageSong()
        r.seconds(0.5)
        r.engine.pause()
        assertEquals(DjEngineDecline.NOT_PLAYING, r.engine.dj.beginTransition(spec()))
        r.engine.play()
        r.unreadable = setOf("next.mp3")
        assertEquals(DjEngineDecline.INCOMING_UNREADABLE, r.engine.dj.beginTransition(spec()))
        r.unreadable = emptySet()
        r.engine.setStemMuted("drums", true)
        assertEquals(DjEngineDecline.STEMS_MUTED, r.engine.dj.beginTransition(spec()))
        r.engine.setStemMuted("drums", false)
        assertEquals(1, r.voices.size)
        assertEquals(DjPhase.IDLE, r.engine.dj.phase)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertNull(r.engine.dj.beginTransition(spec()))
        assertEquals(DjEngineDecline.IN_FLIGHT, r.engine.dj.beginTransition(spec(id = "s9")))
    }

    @Test fun lessThanThreeTenthsOfASecondLeftDeclines() {
        val r = Rig(songSeconds = 10)
        r.engageSong(at = 9.8)
        r.seconds(0.05)
        assertEquals(DjEngineDecline.TOO_CLOSE, r.engine.dj.beginTransition(spec()))
        assertEquals(1, r.voices.size)
    }

    @Test fun theDeclineOrderIsTheContract() {
        val ok = DjEngineDecline.Inputs(false, true, true, false, false, false, false, true, 5.0)
        assertNull(DjEngineDecline.check(ok))
        assertEquals(DjEngineDecline.IN_FLIGHT, DjEngineDecline.check(ok.copy(inFlight = true, engaged = false)))
        assertEquals(DjEngineDecline.NOT_PLAYING, DjEngineDecline.check(ok.copy(engaged = false)))
        assertEquals(DjEngineDecline.NOT_PLAYING, DjEngineDecline.check(ok.copy(playing = false, growing = true)))
        assertEquals("holding at a stream frontier is not playing", DjEngineDecline.NOT_PLAYING, DjEngineDecline.check(ok.copy(buffering = true)))
        assertEquals(DjEngineDecline.GROWING, DjEngineDecline.check(ok.copy(growing = true, stemHandoverInFlight = true)))
        assertEquals(DjEngineDecline.STEM_HANDOVER, DjEngineDecline.check(ok.copy(stemHandoverInFlight = true, mutedStems = true)))
        assertEquals(DjEngineDecline.STEMS_MUTED, DjEngineDecline.check(ok.copy(mutedStems = true, incomingReadable = false)))
        assertEquals(DjEngineDecline.INCOMING_UNREADABLE, DjEngineDecline.check(ok.copy(incomingReadable = false, secondsLeft = 0.1)))
        assertEquals(DjEngineDecline.TOO_CLOSE, DjEngineDecline.check(ok.copy(secondsLeft = 0.29)))
        assertNull(DjEngineDecline.check(ok.copy(secondsLeft = 0.3)))
    }

    @Test fun theGenerationBumpsAtTheCommitPointBeforeTheTailIsStopped() {
        val r = Rig()
        r.engageSong()
        r.seconds(0.5)
        val gen = r.engine.djHandoverGen
        var genAtFadeStart = -1
        r.engine.dj.onFadeStart = { genAtFadeStart = r.engine.djHandoverGen; true }
        r.engine.dj.beginTransition(spec())
        assertTrue("bumped before the host hears of the advance", genAtFadeStart > gen)
        r.seconds(1.5)
        assertEquals("the tail's release is not a second commit", genAtFadeStart, r.engine.djHandoverGen)
    }

    @Test fun aRefusedFadeStartPutsTheOutgoingBack() {
        val r = Rig(songSeconds = 12)
        r.engageSong()
        r.seconds(1.0)
        r.fadeStartAccepts = false
        val plan = AutoTransition.Plan(true, 0.0, 1.0, 1.0, null)
        assertNull(r.engine.dj.beginTransition(spec(plan, AutoTransition.GlideTargets(1.2, 0.0, 0.8, 0.0))))
        assertEquals(listOf("fade:s2", "back", "end:null:refused"), r.events)
        assertEquals(Deck.A, r.engine.liveDeck)
        assertEquals("s1", r.engine.engagedSongId)
        assertEquals(0f, r.engine.djCrossfaderForTest(), 0f)
        assertEquals(1, r.voices.size)
        assertTrue(r.engine.isPlaying)
        r.seconds(0.7)
        assertEquals(1.0, r.speed(Deck.A), 1e-6)
        // and a fresh transition can follow
        r.fadeStartAccepts = true
        assertNull(r.engine.dj.beginTransition(spec(id = "s3")))
    }

    // ---------------------------------------------------------------- the lead-window watch

    @Test fun armedWatchBeginsInTheLeadWindowAndRetriesADeclineEverySecond() {
        val r = Rig(songSeconds = 10)
        var asked = 0
        var next: DjTransitionSpec? = null
        r.engageSong()
        r.engine.dj.armDj(3.0) { asked++; next }
        r.seconds(5.0)                               // 5 s left: outside the lead window
        assertEquals(0, asked)
        r.seconds(2.2)                               // inside; the host declines (next row not ready)
        val first = asked
        assertTrue(first >= 1)
        r.seconds(0.5)
        assertEquals("not asked again inside the retry second", first, asked)
        r.seconds(1.0)
        assertTrue(asked > first)
        next = spec()
        r.seconds(1.2)
        assertTrue(r.events.contains("fade:s2"))
        assertFalse("the armed song is consumed by the advance", r.engine.dj.isArmed)
    }

    @Test fun anArmedBeginThatIsDeclinedByTheEngineIsReported() {
        val r = Rig(songSeconds = 10)
        r.unreadable = setOf("next.mp3")
        r.engageSong()
        r.engine.dj.armDj(3.0) { spec() }
        r.seconds(7.5)
        assertTrue(r.events.contains("declined:${DjEngineDecline.INCOMING_UNREADABLE}"))
        assertTrue(r.engine.dj.isArmed)
    }

    @Test fun aDisengageDisarms() {
        val r = Rig()
        r.engageSong()
        r.engine.dj.armDj(3.0) { spec() }
        assertTrue(r.engine.dj.isArmed)
        r.engine.disengage()
        assertFalse(r.engine.dj.isArmed)
    }
}
