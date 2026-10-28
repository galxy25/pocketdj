package com.levi.pocketdj.screens.producer.demux

import com.levi.pocketdj.studio.demux.DemuxDrumKind
import com.levi.pocketdj.studio.demux.DemuxLine
import com.levi.pocketdj.studio.demux.DemuxWord
import com.levi.pocketdj.studio.demux.DrumPatternDetector.Bar
import androidx.compose.ui.graphics.Color
import com.levi.pocketdj.studio.demux.DemuxInstrumental
import com.levi.pocketdj.studio.demux.DemuxInstrumentalContent
import com.levi.pocketdj.studio.demux.DemuxMelodyNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DemuxPanelMathTest {
    private val bar = Bar(2, 4_000, 6_000)

    @Test fun currentStepIsTheSixteenthTheClockIsIn() {
        assertEquals(0, DrumPanelMath.currentStep(4_000, bar))
        assertEquals(4, DrumPanelMath.currentStep(4_500, bar))
        assertEquals(15, DrumPanelMath.currentStep(5_999, bar))
        assertNull(DrumPanelMath.currentStep(6_000, bar))   // half-open: that is the next bar's step 0
        assertNull(DrumPanelMath.currentStep(3_999, bar))
        assertNull(DrumPanelMath.currentStep(5_000, null))
    }

    @Test fun stepTapSeeksToTheSixteenthBoundary() {
        assertEquals(4_000, DrumPanelMath.stepMs(bar, 0))
        assertEquals(4_500, DrumPanelMath.stepMs(bar, 4))
        assertEquals(5_875, DrumPanelMath.stepMs(bar, 15))
        // Two-way: seeking to a step lands inside that same step.
        for (c in 0 until 16) assertEquals(c, DrumPanelMath.currentStep(DrumPanelMath.stepMs(bar, c), bar))
    }

    @Test fun exportRangeIsTheSelectedBarOrEveryBar() {
        assertEquals(listOf(3), DrumPanelMath.exportRange(false, 3, 8))
        assertEquals((0 until 8).toList(), DrumPanelMath.exportRange(true, 3, 8))
        assertEquals(emptyList<Int>(), DrumPanelMath.exportRange(false, 9, 8))
    }

    @Test fun everyLaneHasItsOwnColour() {
        assertEquals(DemuxDrumKind.entries.size, DemuxDrumKind.entries.map { DrumPanelMath.laneColor(it) }.toSet().size)
    }

    @Test fun scoreClockIsTheSongClockMinusTheCountIn() {
        assertNull(InstrumentalMath.scoreMs(500, 1_000))
        assertEquals(0, InstrumentalMath.scoreMs(1_000, 1_000))
        assertEquals(1_500, InstrumentalMath.scoreMs(2_500, 1_000))
        assertEquals(2_500, InstrumentalMath.songMs(1_500, 1_000))
        assertEquals(0f, InstrumentalMath.scrollFraction(null, 4_000), 0f)
        assertEquals(0.5f, InstrumentalMath.scrollFraction(2_000, 4_000), 0f)
        assertEquals(1f, InstrumentalMath.scrollFraction(9_000, 4_000), 0f)
        assertEquals(0f, InstrumentalMath.scrollFraction(100, 0), 0f)
    }

    @Test fun rebuildKeyChangesWithModeContentAndGrid() {
        val g = DemuxInstrumental.Grid(120.0, 0)
        val mel = DemuxInstrumentalContent.Melody(listOf(DemuxMelodyNote(60, 0, 400)))
        val comp = DemuxInstrumentalContent.Comping(emptyList())
        val k = InstrumentalMath.rebuildKey(mel, g, 1000)
        assertNotEquals(k, InstrumentalMath.rebuildKey(comp, g, 1000))
        assertNotEquals(k, InstrumentalMath.rebuildKey(mel, g.copy(bpm = 121.0), 1000))
        assertEquals(k, InstrumentalMath.rebuildKey(mel, g.copy(), 1000))
    }

    @Test fun karaokeFillsOnlyTheCurrentLinesSungWords() {
        val line = DemuxLine(listOf(DemuxWord("a", 0, 200), DemuxWord("b", 500, 700), DemuxWord("c", 1_000, 1_200)))
        assertEquals(listOf(true, true, false), LyricsMath.sungFlags(line, 600))
        assertEquals(listOf(false, false, false), LyricsMath.sungFlags(line, 5_000))     // past the line: dimmed
        val fg = Color.White; val dim = Color.Gray; val acc = Color.Red
        val t = karaoke(line, 600, fg, dim, acc)
        assertEquals("a b c ", t.text)
        assertEquals(listOf(acc, acc, fg), t.spanStyles.map { it.item.color })
        assertTrue(karaoke(line, 5_000, fg, dim, acc).spanStyles.all { it.item.color == dim })
    }
}
