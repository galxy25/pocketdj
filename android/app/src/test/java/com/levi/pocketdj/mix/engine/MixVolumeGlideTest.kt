package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.dsp.LoudnessLeveling
import com.levi.pocketdj.mix.graph.MixGraph
import com.levi.pocketdj.mix.graph.ParamsComposer
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.playback.dj.LoudnessCache
import java.io.File
import kotlin.math.abs
import kotlin.math.log10
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A driver that, unlike [ManualTickDriver], can run several repeating tasks (one per deck ramp). */
class MultiTickDriver : TickDriver {
    class Task(val block: () -> Boolean) : AutoCloseable { var open = true; override fun close() { open = false } }
    val tasks = mutableListOf<Task>()
    override fun start(intervalMs: Long, block: () -> Boolean): AutoCloseable = Task(block).also { tasks += it }
    val live: Int get() = tasks.count { it.open }
    /** One 20 ms step of every open task. */
    fun step() { for (t in tasks.toList()) if (t.open && !t.block()) t.open = false }
    fun stepAll(max: Int = 1000) { var n = 0; while (live > 0 && n++ < max) step() }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MixVolumeGlideTest {
    private val A = Deck.A
    private val B = Deck.B

    // ---------------------------------------------------------------- the pure rules

    @Test fun readoutWordsMatchTheIosStrings() {
        assertEquals("+2.1 dB", VolumeGlideRules.words(LevelSide(LevelingStatus.MEASURED, 2.14)))
        assertEquals("−3.4 dB", VolumeGlideRules.words(LevelSide(LevelingStatus.MEASURED, -3.44)))
        assertEquals("0.0 dB", VolumeGlideRules.words(LevelSide(LevelingStatus.MEASURED, 0.04)))
        assertEquals("0.0 dB", VolumeGlideRules.words(LevelSide(LevelingStatus.MEASURED, -0.04)))
        assertEquals("measuring…", LevelSide(LevelingStatus.MEASURING).words)
        assertEquals("unavailable", LevelSide(LevelingStatus.UNAVAILABLE).words)
        assertEquals("—", LevelSide().words)
    }

    @Test fun clampRampAndAudibleRules() {
        assertEquals(LoudnessLeveling.MAX_GAIN_DB, VolumeGlideRules.clamp(40.0), 0.0)
        assertEquals(LoudnessLeveling.MIN_GAIN_DB, VolumeGlideRules.clamp(-40.0), 0.0)
        assertEquals(0.0, VolumeGlideRules.clamp(Double.NaN), 0.0)
        assertEquals(100, VolumeGlideRules.rampSteps(2.0))
        assertEquals(1, VolumeGlideRules.rampSteps(0.001))
        assertEquals(3.0, VolumeGlideRules.stepValue(0.0, 6.0, 50, 100), 1e-9)
        assertTrue(VolumeGlideRules.shouldRamp(true, 0.0, 3.0, 2.0))
        assertFalse("a silent deck is set at once", VolumeGlideRules.shouldRamp(false, 0.0, 3.0, 2.0))
        assertFalse("an imperceptible change is not worth a ramp", VolumeGlideRules.shouldRamp(true, 3.0, 3.005, 2.0))
        assertFalse("a zero ramp length means at once", VolumeGlideRules.shouldRamp(true, 0.0, 3.0, 0.0))
    }

    // ---------------------------------------------------------------- the machine, over a fake host

    private class FakeHost : VolumeGlideHost {
        override var autoMixing = true
        val songs = HashMap<Deck, String?>()
        val sources = HashMap<Deck, LevelSource?>()
        val streaming = HashSet<Deck>()
        val audible = HashSet<Deck>()
        val writes = mutableListOf<Pair<Deck, Double>>()
        val lines = mutableListOf<String>()
        override fun loadedSongId(deck: Deck) = songs[deck]
        override fun levelSource(deck: Deck) = sources[deck]
        override fun isStreaming(deck: Deck) = deck in streaming
        override fun isAudible(deck: Deck) = deck in audible
        override fun writeTrim(deck: Deck, db: Double) { writes += deck to db }
        override fun log(line: String) { lines += line }
    }

    private class Rig(measure: (String) -> Double?) {
        val scheduler = TestCoroutineScheduler()
        val dispatcher = StandardTestDispatcher(scheduler)
        val scope = CoroutineScope(dispatcher)
        val calls = mutableListOf<String>()
        val cache = LoudnessCache(
            file = null, scope = scope, ioDispatcher = dispatcher, saveDebounceMs = 1,
            measure = { path, _, _ -> calls += path; measure(path) },
        )
        val host = FakeHost()
        val driver = MultiTickDriver()
        val glide = MixVolumeGlide(host, { cache }, driver, scope)
        val files = HashMap<String, File>()
        fun file(name: String, bytes: Int = 8): File = files.getOrPut(name) {
            File.createTempFile("vg-$name", ".mp3").also { it.writeBytes(ByteArray(bytes)); it.deleteOnExit() }
        }
        fun load(deck: Deck, id: String) {
            host.songs[deck] = id
            host.sources[deck] = LevelSource(file(id), null, null)
            glide.deckLoaded(deck)
        }
        fun settle() = scheduler.advanceUntilIdle()
    }

    @Test fun offIsExactlyWhatItWas() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(false)
        r.load(A, "s1")
        r.settle()
        assertEquals(LevelSide(), r.glide.leveling.value[A])
        assertTrue("no trim is ever written", r.host.writes.isEmpty())
        assertTrue("and nothing is measured", r.calls.isEmpty())
    }

    @Test fun handMixesAreNeverLeveled() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.host.autoMixing = false
        r.load(A, "s1"); r.settle()
        assertEquals(LevelingStatus.INACTIVE, r.glide.leveling.value[A].status)
        assertTrue(r.host.writes.isEmpty()); assertTrue(r.calls.isEmpty())
    }

    @Test fun onMeasuresOffMainThenSetsTheTrimAtOnceOnASilentDeck() {
        val r = Rig { -20.0 }                        // -14 target => +6 dB
        r.glide.setEnabled(true)
        r.load(A, "s1")
        assertEquals("says measuring… until the analysis lands", LevelingStatus.MEASURING, r.glide.leveling.value[A].status)
        assertEquals(0.0, r.glide.levelDb(A), 0.0)
        r.settle()
        assertEquals(LevelSide(LevelingStatus.MEASURED, 6.0), r.glide.leveling.value[A])
        assertEquals(6.0, r.glide.levelDb(A), 1e-9)
        assertEquals("a silent deck: one write, no ramp", listOf(A to 6.0), r.host.writes)
        assertEquals(0, r.driver.tasks.size)
        assertTrue(r.host.lines.any { it.startsWith("volume glide deck=A gain=") })
    }

    @Test fun aLoudSongIsTurnedDownAndAQuietOneUp() {
        val r = Rig { path -> if ("loud" in path) -8.0 else -22.0 }
        r.glide.setEnabled(true)
        r.load(A, "loud"); r.load(B, "quiet"); r.settle()
        assertEquals(-6.0, r.glide.levelDb(A), 1e-9)
        assertEquals(6.0, r.glide.levelDb(B), 1e-9)       // +8 clamps to +6
    }

    @Test fun aSoundingDeckRampsOverTwoSecondsInTwentyMsSteps() {
        val r = Rig { -20.0 }
        r.host.audible += A
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle()
        assertEquals("the gain has not jumped", 0.0, r.glide.levelDb(A), 0.0)
        assertEquals(1, r.driver.live)
        r.driver.step()
        assertEquals(0.06, r.glide.levelDb(A), 1e-9)
        var prev = r.glide.levelDb(A); var steps = 1
        while (r.driver.live > 0) { r.driver.step(); steps++; assertTrue(r.glide.levelDb(A) >= prev); prev = r.glide.levelDb(A) }
        assertEquals(100, steps)
        assertEquals(6.0, r.glide.levelDb(A), 1e-9)
        assertEquals(LevelSide(LevelingStatus.MEASURED, 6.0), r.glide.leveling.value[A])
        assertTrue(r.glide.rampsSettled)
    }

    @Test fun theReadoutFollowsEveryThirdRampStep() {
        val r = Rig { -20.0 }
        r.host.audible += A
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle()
        r.driver.step(); r.driver.step()
        assertEquals(0.0, r.glide.leveling.value[A].trimDb, 0.0)     // steps 1-2: readout still at the start
        r.driver.step()
        assertEquals(0.18, r.glide.leveling.value[A].trimDb, 1e-9)   // step 3 publishes
    }

    @Test fun stoppingTheAutoDjClearsTheTrimAndTheReadout() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle()
        r.host.autoMixing = false
        r.glide.refresh()
        assertEquals(0.0, r.glide.levelDb(A), 0.0)
        assertEquals(LevelSide(), r.glide.leveling.value[A])
        assertEquals(A to 0.0, r.host.writes.last())
    }

    @Test fun turningGlideOffMidMixRampsASoundingDeckBackToZero() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle()
        r.host.audible += A
        r.glide.setEnabled(false)
        assertEquals(6.0, r.glide.levelDb(A), 0.0)                   // ramping, not jumped
        r.driver.stepAll()
        assertEquals(0.0, r.glide.levelDb(A), 1e-9)
        assertEquals(LevelingStatus.INACTIVE, r.glide.leveling.value[A].status)
    }

    @Test fun ejectingADeckDropsItsTrimAndCancelsItsRamp() {
        val r = Rig { -20.0 }
        r.host.audible += A
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle(); r.driver.step()
        r.glide.deckCleared(A)
        assertEquals(0, r.driver.live)
        assertEquals(0.0, r.glide.levelDb(A), 0.0)
        assertEquals(LevelSide(), r.glide.leveling.value[A])
        assertEquals(A to 0.0, r.host.writes.last())
    }

    @Test fun anUnmeasurableOrFailedSongReadsUnavailableAtZero() {
        val unmeasurable = Rig { null }
        unmeasurable.glide.setEnabled(true)
        unmeasurable.load(A, "silence"); unmeasurable.settle()
        assertEquals(LevelSide(LevelingStatus.UNAVAILABLE, 0.0), unmeasurable.glide.leveling.value[A])

        val failing = Rig { error("decoder blew up") }
        failing.glide.setEnabled(true)
        failing.load(A, "bad"); failing.settle()
        assertEquals(LevelSide(LevelingStatus.UNAVAILABLE, 0.0), failing.glide.leveling.value[A])
        assertEquals(0.0, failing.glide.levelDb(A), 0.0)
    }

    @Test fun aSongWithNoReadableFileIsUnavailableNotMeasuringForever() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.host.songs[A] = "ghost"; r.host.sources[A] = LevelSource(File("/nonexistent/ghost.mp3"), null, null)
        r.glide.deckLoaded(A)
        assertEquals(LevelingStatus.UNAVAILABLE, r.glide.leveling.value[A].status)
        assertTrue(r.calls.isEmpty())
    }

    @Test fun aStreamingDeckWaitsForItsFileThenIsMeasured() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.host.songs[A] = "stream"; r.host.streaming += A
        r.glide.deckLoaded(A)
        assertEquals(LevelingStatus.MEASURING, r.glide.leveling.value[A].status)
        r.settle()
        assertTrue("nothing is measured while the file grows", r.calls.isEmpty())
        r.host.streaming -= A
        r.host.sources[A] = LevelSource(r.file("stream"), null, null)
        r.glide.deckSettled(A); r.settle()
        assertEquals(LevelSide(LevelingStatus.MEASURED, 6.0), r.glide.leveling.value[A])
    }

    @Test fun aSharedAlbumSideIsMeasuredAsItsOwnSlice() {
        val segs = mutableListOf<Any?>()
        val scheduler = TestCoroutineScheduler(); val d = StandardTestDispatcher(scheduler); val scope = CoroutineScope(d)
        val cache = LoudnessCache(null, scope, d, 1, { _, seg, _ -> segs += seg; -20.0 })
        val host = FakeHost()
        val glide = MixVolumeGlide(host, { cache }, MultiTickDriver(), scope)
        val f = File.createTempFile("side", ".mp3").also { it.writeBytes(ByteArray(8)); it.deleteOnExit() }
        glide.setEnabled(true)
        host.songs[A] = "t1"; host.sources[A] = LevelSource(f, 30_000, 200_000)
        host.songs[B] = "t2"; host.sources[B] = LevelSource(f, 230_000, 180_000)
        glide.deckLoaded(A); glide.deckLoaded(B); scheduler.advanceUntilIdle()
        assertEquals(2, segs.size)
        assertEquals(com.levi.pocketdj.audio.dsp.LoudnessSegment(30_000, 200_000), segs[0])
        assertEquals(com.levi.pocketdj.audio.dsp.LoudnessSegment(230_000, 180_000), segs[1])
    }

    @Test fun aResultForASongThatLeftTheDeckIsIgnored() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.load(A, "old")
        r.load(A, "new")                      // the deck moved on before the first measurement landed
        r.settle()
        assertEquals(LevelSide(LevelingStatus.MEASURED, 6.0), r.glide.leveling.value[A])
        assertEquals(2, r.calls.size)         // each song was measured once
    }

    @Test fun repeatRefreshesQueueOneAnalysisPerDeck() {
        val r = Rig { -20.0 }
        r.glide.setEnabled(true)
        r.load(A, "s1")
        repeat(5) { r.glide.refresh() }
        r.settle()
        assertEquals(1, r.calls.size)
    }

    @Test fun aCancelledSharedAnalysisIsRekickedOnceNeverInALoop() {
        var n = 0
        val r = Rig { n++; if (n == 1) throw kotlin.coroutines.cancellation.CancellationException("DJ Mode off") else -20.0 }
        r.glide.setEnabled(true)
        r.load(A, "s1"); r.settle()
        assertEquals(LevelSide(LevelingStatus.MEASURED, 6.0), r.glide.leveling.value[A])
        assertEquals(2, r.calls.size)

        var m = 0
        val always = Rig { m++; throw kotlin.coroutines.cancellation.CancellationException("always") }
        always.glide.setEnabled(true)
        always.load(A, "s1"); always.settle()
        assertEquals("re-kicked once, then gives up", 2, m)
        assertEquals(LevelingStatus.MEASURING, always.glide.leveling.value[A].status)
    }

    @Test fun noCacheMeansUnavailable() {
        val host = FakeHost()
        val glide = MixVolumeGlide(host, { null }, MultiTickDriver(), CoroutineScope(StandardTestDispatcher()))
        glide.setEnabled(true)
        host.songs[A] = "s"; host.sources[A] = LevelSource(File.createTempFile("x", ".mp3").also { it.deleteOnExit() }, null, null)
        glide.deckLoaded(A)
        assertEquals(LevelingStatus.UNAVAILABLE, glide.leveling.value[A].status)
    }

    // ---------------------------------------------------------------- the composer (trim, not fader)

    @Test fun levelRidesTheTrimNeverTheFaderAndComposesWithBoost() {
        val c = ParamsComposer()
        c.setVolume(A, 0.5)
        val fader = c.current.a.mainGain
        c.setLevelDb(A, 3.0)
        val boostWrites = c.boostWrites
        assertEquals("the fader is untouched", fader, c.current.a.mainGain, 0f)
        assertEquals(3.0f, c.current.a.trimDb, 1e-6f)
        c.setVolume(A, 2.0)                                           // +6.02 dB boost composes with +3 dB level
        assertEquals((20 * log10(2.0) + 3.0).toFloat(), c.current.a.trimDb, 1e-4f)
        c.setCrossfader(0.9f)                                         // the crossfader sweeps; trim untouched
        assertEquals((20 * log10(2.0) + 3.0).toFloat(), c.current.a.trimDb, 1e-4f)
        assertEquals(boostWrites + 1, c.boostWrites)                  // only the volume change counted
        c.setLevelDb(A, 0.0)
        assertEquals((20 * log10(2.0)).toFloat(), c.current.a.trimDb, 1e-4f)
        assertEquals("setLevelDb is not a boost write", boostWrites + 1, c.boostWrites)
        assertEquals(0f, c.current.b.trimDb, 0f)
    }

    // ---------------------------------------------------------------- the engine, end to end

    private class EngineRig(measure: (String) -> Double?) {
        val sr = 44_100
        val scheduler = TestCoroutineScheduler()
        val dispatcher = StandardTestDispatcher(scheduler)
        val scope = CoroutineScope(dispatcher)
        val levelDriver = MultiTickDriver()
        val songs = HashMap<String, ResolvedTrack>()
        val engine = MixEngine(
            graph = MixGraph(sr, 2048),
            sinkFactory = { OfflineRenderer(sr, 512) },
            resolver = { id -> songs[id] },
            opener = { SyntheticPcmSource.tone(220.0, (20.0 * sr).toLong(), sr) },
            runner = { AutoCloseable {} },
            tickDriver = ManualTickDriver(),
            levelDriver = levelDriver,
            glideScope = scope,
        )
        val auto = FakeAutoDj().also { engine.autoDj = it }
        init {
            engine.loudnessCache = LoudnessCache(null, scope, dispatcher, 1, { p, _, _ -> measure(p) })
        }
        fun song(id: String): MixLoadable {
            val f = File.createTempFile("eng-$id", ".mp3").also { it.writeBytes(ByteArray(16)); it.deleteOnExit() }
            songs[id] = ResolvedTrack(f, isCut = true)
            return MixLoadable(id, "T $id", "A")
        }
        fun trim(d: Deck) = engine.params.current.deck(d).trimDb
        fun fader(d: Deck) = engine.params.current.deck(d).mainGain
        fun settle() = scheduler.advanceUntilIdle()
    }

    @Test fun engineOffByDefaultChangesNothing() {
        val e = EngineRig { -20.0 }
        assertFalse(e.engine.volumeGlideEnabled)
        e.auto.isMixing = true
        e.engine.loadNow(e.song("a"), A); e.engine.loadNow(e.song("b"), B); e.settle()
        assertEquals(0f, e.trim(A), 0f); assertEquals(0f, e.trim(B), 0f)
        assertEquals(LevelSide(), e.engine.volumeGlide.leveling.value[A])
        assertEquals(1.0, e.engine.volume(A), 0.0)
    }

    @Test fun engineLevelsBothAutoDjDecksOnTheTrimNotTheFader() {
        val e = EngineRig { p -> if ("eng-loud" in p) -8.0 else -20.0 }
        e.engine.setVolumeGlide(true)
        e.auto.isMixing = true
        val faderA = e.fader(A)
        e.engine.loadNow(e.song("loud"), A); e.engine.loadNow(e.song("quiet"), B)
        assertEquals(LevelingStatus.MEASURING, e.engine.volumeGlide.leveling.value[A].status)
        e.settle()
        assertEquals(-6.0f, e.trim(A), 1e-5f)
        assertEquals(6.0f, e.trim(B), 1e-5f)
        assertEquals("the Vol fader never moves", 1.0, e.engine.volume(A), 0.0)
        assertEquals(faderA, e.fader(A), 0f)
        e.engine.setVolume(2.0, A)                                    // boost composes with the trim
        assertEquals((20 * log10(2.0) - 6.0).toFloat(), e.trim(A), 1e-4f)
        assertEquals(LevelSide(LevelingStatus.MEASURED, -6.0), e.engine.volumeGlide.leveling.value[A])
    }

    @Test fun engineHandMixIsNeverLeveled() {
        val e = EngineRig { -20.0 }
        e.engine.setVolumeGlide(true)                                 // glide on, Auto-DJ NOT mixing
        e.engine.loadNow(e.song("a"), A); e.settle()
        assertEquals(0f, e.trim(A), 0f)
        assertEquals(LevelingStatus.INACTIVE, e.engine.volumeGlide.leveling.value[A].status)
    }

    @Test fun engineAutoDjStartLevelsLoadedDecksAndStopClearsThem() {
        val e = EngineRig { -20.0 }
        e.engine.setVolumeGlide(true)
        e.engine.loadNow(e.song("a"), A); e.engine.loadNow(e.song("b"), B); e.settle()
        assertEquals(0f, e.trim(A), 0f)                               // hand-mixed so far
        e.auto.isMixing = true
        e.engine.refreshVolumeGlide(); e.settle()                     // what the Auto-DJ does as it starts
        assertEquals(6.0f, e.trim(A), 1e-5f); assertEquals(6.0f, e.trim(B), 1e-5f)
        e.auto.isMixing = false
        e.engine.refreshVolumeGlide()                                 // ...and as it ends
        assertEquals(0f, e.trim(A), 1e-5f); assertEquals(0f, e.trim(B), 1e-5f)
        assertEquals(LevelSide(), e.engine.volumeGlide.leveling.value[B])
    }

    @Test fun engineEjectClearsTheDecksTrim() {
        val e = EngineRig { -20.0 }
        e.engine.setVolumeGlide(true); e.auto.isMixing = true
        e.engine.loadNow(e.song("a"), A); e.settle()
        assertEquals(6.0f, e.trim(A), 1e-5f)
        e.engine.clearDeck(A)
        assertEquals(0f, e.trim(A), 1e-5f)
        assertEquals(LevelSide(), e.engine.volumeGlide.leveling.value[A])
    }

    @Test fun engineCrossfaderSweepLeavesTheTrimAlone() {
        val e = EngineRig { -20.0 }
        e.engine.setVolumeGlide(true); e.auto.isMixing = true
        e.engine.loadNow(e.song("a"), A); e.settle()
        val before = e.trim(A)
        for (x in listOf(0.1, 0.5, 0.9, 1.0)) e.engine.applyCrossfader(x)
        assertEquals(before, e.trim(A), 0f)
        assertTrue(abs(e.fader(A) - 1f) > 0.01f)                      // the fader side did move
    }
}
