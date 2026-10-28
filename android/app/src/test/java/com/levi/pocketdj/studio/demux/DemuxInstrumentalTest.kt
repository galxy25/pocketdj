package com.levi.pocketdj.studio.demux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemuxInstrumentalTest {
    private val g120 = DemuxInstrumental.Grid(120.0, 0, emptyList())   // beat = 500 ms
    private fun chord(root: Int, minor: Boolean, s: Int, e: Int, conf: Double = 0.8) = DemuxChordSegment(root, minor, s, e, conf)

    @Test fun beatsSpannedCountsMeasuredBeatsElseRoundsFromBpmAndIsAtLeastOne() {
        val measured = DemuxInstrumental.Grid(100.0, 0, listOf(0, 600, 1200, 1800, 2400))
        assertEquals(3, DemuxInstrumental.beatsSpanned(0, 1_800, measured))     // beats at 0,600,1200
        assertEquals(1, DemuxInstrumental.beatsSpanned(100, 500, measured))     // falls between beats -> bpm fallback -> min 1
        assertEquals(4, DemuxInstrumental.beatsSpanned(0, 2_000, g120))
        assertEquals(1, DemuxInstrumental.beatsSpanned(0, 100, g120))
        assertEquals(4, DemuxInstrumental.beatsSpanned(0, 2_000, DemuxInstrumental.Grid(0.0, 0)))  // bad bpm -> 120
    }

    @Test fun snapToBeatUsesTheMeasuredLatticeOrTheAnchoredConstantGrid() {
        assertEquals(600, DemuxInstrumental.snapToBeat(700, DemuxInstrumental.Grid(100.0, 0, listOf(0, 600, 1200))))
        assertEquals(500, DemuxInstrumental.snapToBeat(430, g120))
        assertEquals(1_000, DemuxInstrumental.snapToBeat(1_240, g120))
        // Anchored at a non-zero first downbeat: beats land on 250 + k*500.
        assertEquals(750, DemuxInstrumental.snapToBeat(700, DemuxInstrumental.Grid(120.0, 250)))
        assertEquals(0, DemuxInstrumental.snapToBeat(-40, DemuxInstrumental.Grid(120.0, 0)))
    }

    @Test fun compingEmitsTheFullTriadQuantizedToBeatsAndReanchoredToTheFirstDownbeat() {
        val grid = DemuxInstrumental.Grid(120.0, 1_000, emptyList())
        val r = DemuxInstrumental.events(listOf(chord(0, false, 1_020, 3_010), chord(9, true, 3_010, 5_000)), grid)
        assertEquals(120.0, r.bpm, 0.0)
        // C major: held round(1990/500)=4 beats from onset 0 (1020 snaps to 1000 -> 0 ms)
        val c = r.events.filter { it.onMs == 0 }
        assertEquals(listOf(60, 64, 67), c.map { it.note }.sorted())
        assertTrue(c.all { it.offMs == 2_000 && it.velocity == 88 })
        // A minor from 3010 -> snaps to 3000 -> onset 2000; triad A C E.
        val a = r.events.filter { it.onMs == 2_000 }
        assertEquals(listOf(0, 4, 9), a.map { it.note % 12 }.sorted())
        assertEquals(3, a.size)
        assertTrue("every onset is on a beat", r.events.all { it.onMs % 500 == 0 })
    }

    @Test fun twoChordsSnappingToTheSameBeatKeepOnlyTheMoreConfidentTriad() {
        val r = DemuxInstrumental.events(
            listOf(chord(0, false, 480, 700, conf = 0.5), chord(7, false, 510, 800, conf = 0.9), chord(2, false, 520, 900, conf = 0.9)),
            g120,
        )
        val onsets = r.events.map { it.onMs }.toSet()
        assertEquals(setOf(500), onsets)
        assertEquals(3, r.events.size)                                  // one triad, never a union
        assertEquals(setOf(7, 11, 2), r.events.map { it.note % 12 }.toSet())   // G (first 0.9) wins the tie
    }

    @Test fun aChordEndingJustBeforeABeatNeverSoundsAfterItsOwnEnd() {
        val r = DemuxInstrumental.events(listOf(chord(0, false, 460, 480)), g120)   // 460 snaps to 500 > end 480
        assertEquals(480, r.events.first().onMs)
    }

    @Test fun melodyIsOneEventPerOnsetAndMonophonic() {
        val notes = listOf(
            DemuxMelodyNote(60, 0, 450), DemuxMelodyNote(64, 40, 1_100),       // both snap to 0: the LONGER one (64) wins
            DemuxMelodyNote(67, 1_000, 1_450), DemuxMelodyNote(71, 1_030, 1_480), // equal length -> earlier (67) wins
        )
        val r = DemuxInstrumental.melodyEvents(notes, g120)
        assertEquals(listOf(64, 67), r.events.map { it.note })
        assertEquals(listOf(0, 1_000), r.events.map { it.onMs })
        assertTrue(r.events.all { it.velocity == 90 })
        assertEquals(1, r.events.map { it.onMs }.groupingBy { it }.eachCount().values.max())
    }

    @Test fun melodyReanchorsToFirstDownbeatAndClampsAtZero() {
        val grid = DemuxInstrumental.Grid(120.0, 2_000, emptyList())
        val r = DemuxInstrumental.melodyEvents(listOf(DemuxMelodyNote(60, 500, 1_000)), grid)   // before beat 1 -> clamp 0
        assertEquals(0, r.events.single().onMs)
        assertEquals(500, r.events.single().offMs)
    }

    @Test fun emptyInputsGiveEmptyEventsAndFallbackBpm() {
        val r = DemuxInstrumental.events(emptyList(), DemuxInstrumental.Grid(-3.0, 0))
        assertTrue(r.events.isEmpty()); assertEquals(120.0, r.bpm, 0.0)
        assertTrue(DemuxInstrumental.melodyEvents(emptyList(), g120).events.isEmpty())
    }

    // ---- content + take switch -------------------------------------------------------------------

    @Test fun contentCarriesTheModeStoredOnTheTake() {
        val comp = DemuxInstrumentalContent.Comping(listOf(chord(0, false, 0, 1000)))
        val mel = DemuxInstrumentalContent.Melody(listOf(DemuxMelodyNote(60, 0, 400)))
        assertEquals("comping", comp.mode); assertEquals("melody", mel.mode)
        assertEquals(1, comp.elementCount); assertTrue(mel.isMelody); assertTrue(!comp.isMelody)
        assertEquals(3, comp.build(g120).events.size); assertEquals(1, mel.build(g120).events.size)
    }

    @Test fun targetModeIsTheOppositeAndMenuLabelsSayWhere() {
        assertEquals("comping", DemuxTakeSwitch.targetMode("melody"))
        assertEquals("melody", DemuxTakeSwitch.targetMode("comping"))
        assertEquals("melody", DemuxTakeSwitch.targetMode(null))
        assertEquals("Switch to melody", DemuxTakeSwitch.menuLabel("comping"))
        assertEquals("Switch to chord comping", DemuxTakeSwitch.menuLabel("melody"))
    }

    private fun doc(chords: List<DemuxChordSegment> = emptyList(), notes: List<DemuxMelodyNote>? = null) =
        DemuxDocument(sourceKey = "k", displayName = "K", chords = chords, melodyNotes = notes)

    private fun run(
        key: String? = "k", mode: String?, doc: DemuxDocument?, track: suspend (String) -> List<DemuxMelodyNote>? = { null },
        cache: (String, List<DemuxMelodyNote>) -> Unit = { _, _ -> },
    ) = kotlinx.coroutines.runBlocking {
        DemuxTakeSwitch.switchEvents(key, mode, { doc }, { g120 }, track, cache)
    }

    private fun err(block: () -> Unit): DemuxSwitchError = try { block(); error("expected a DemuxSwitchException") } catch (e: DemuxSwitchException) { e.error }

    @Test fun switchingMelodyToCompingRebuildsFromTheChordsAndFlipsTheMode() {
        val (mode, events) = run(mode = "melody", doc = doc(chords = listOf(chord(0, false, 0, 2_000))))
        assertEquals("comping", mode); assertEquals(3, events.size)
    }

    @Test fun switchingCompingToMelodyUsesCachedNotesWithoutTracking() {
        var tracked = 0
        val (mode, events) = run(mode = "comping", doc = doc(notes = listOf(DemuxMelodyNote(60, 0, 450))), track = { tracked++; null })
        assertEquals("melody", mode); assertEquals(1, events.size); assertEquals(0, tracked)
    }

    @Test fun switchingToMelodyTracksOnceAndCachesWhenNoNotesAreCached() {
        val cached = ArrayList<List<DemuxMelodyNote>>()
        val (mode, events) = run(mode = "comping", doc = doc(), track = { listOf(DemuxMelodyNote(62, 0, 450)) }, cache = { k, n -> assertEquals("k", k); cached.add(n) })
        assertEquals("melody", mode); assertEquals(listOf(62), events.map { it.note }); assertEquals(1, cached.size)
    }

    @Test fun switchFailuresMapToTheirCopy() {
        assertEquals(DemuxSwitchError.NO_SOURCE, err { run(key = null, mode = "comping", doc = doc()) })
        assertEquals(DemuxSwitchError.NO_DOC, err { run(mode = "comping", doc = null) })
        assertEquals(DemuxSwitchError.NO_CHORDS, err { run(mode = "melody", doc = doc()) })
        assertEquals(DemuxSwitchError.NEED_STEMS, err { run(mode = "comping", doc = doc(), track = { null }) })
        assertEquals(DemuxSwitchError.NO_MELODY, err { run(mode = "comping", doc = doc(), track = { emptyList() }) })
        assertTrue(DemuxSwitchError.NEED_STEMS.message.contains("stems"))
    }

    @Test fun customSourcesNeverFetchASidecarGrid() {
        var calls = 0
        val g = kotlinx.coroutines.runBlocking { DemuxTakeSwitch.resolveGrid("dmx_abc") { calls++; null } }
        assertEquals(0, calls); assertEquals(DemuxInstrumental.Grid(120.0, 0, emptyList()), g)
        val song = kotlinx.coroutines.runBlocking {
            DemuxTakeSwitch.resolveGrid("sng_1") { com.levi.pocketdj.data.burns.BeatGridSidecar(beatGridBpm = 98.0, firstDownbeatMs = 350, beatsMs = listOf(350, 960)) }
        }
        assertEquals(DemuxInstrumental.Grid(98.0, 350, listOf(350, 960)), song)
        val noBpm = kotlinx.coroutines.runBlocking { DemuxTakeSwitch.resolveGrid("sng_2") { com.levi.pocketdj.data.burns.BeatGridSidecar() } }
        assertEquals(120.0, noBpm.bpm, 0.0)
    }
}
