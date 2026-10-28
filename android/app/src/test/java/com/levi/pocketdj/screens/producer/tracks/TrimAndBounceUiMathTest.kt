package com.levi.pocketdj.screens.producer.tracks

import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TrimAndBounceUiMathTest {
    private fun arr() = StudioArrangement(
        "A", "A", listOf(
            StudioTrack("t1", "Drums", listOf(StudioClip("c1", "c1", "f"))),
            StudioTrack("t2", "Empty"),
            StudioTrack("t3", "Bass", listOf(StudioClip("c3", "c3", "g"))),
        ),
    )

    @Test fun bounceableSkipsEmptyTracksAndSelectionKeepsArrangementOrder() {
        assertEquals(listOf("t1", "t3"), BounceSelection.bounceable(arr()).map { it.id })
        assertEquals(listOf("t1", "t3"), BounceSelection.resolve(arr(), setOf("t3", "t1", "t2")).map { it.id })
        assertTrue(BounceSelection.resolve(arr(), emptySet()).isEmpty())
        assertEquals("Bounce selected (2)", BounceSelection.confirmLabel(2))
    }

    @Test fun trimStartDragIsBeatSnappedAndNeverCrossesTheEnd() {
        // 120 bpm => beat 500 ms; 100 dp/s. Dragging +120 dp from 1000 => 2200 ms raw, snaps to 2000, capped below end.
        assertEquals(2000, TrimMath.dragStart(1000, 5000, 120f, 100f, 120.0))
        assertEquals(4999, TrimMath.dragStart(1000, 5000, 900f, 100f, 120.0))
        assertEquals(0, TrimMath.dragStart(1000, 5000, -900f, 100f, 120.0))
        // Sub-half-beat total drags still move once the accumulated distance crosses the snap threshold.
        assertEquals(1000, TrimMath.dragStart(1000, 5000, 20f, 100f, 120.0))
        assertEquals(1500, TrimMath.dragStart(1000, 5000, 30f, 100f, 120.0))
    }

    @Test fun trimEndDragIsClampedToTheTimelineAndAfterTheStart() {
        assertEquals(6000, TrimMath.dragEnd(1000, 5000, 100f, 100f, 120.0, lengthMs = 6000))      // +1 s
        assertEquals(6000, TrimMath.dragEnd(1000, 5000, 900f, 100f, 120.0, lengthMs = 6000))      // capped at the length
        assertEquals(1001, TrimMath.dragEnd(1000, 5000, -900f, 100f, 120.0, lengthMs = 6000))     // never inverted
    }

    @Test fun nonSelectedLanesAreDimmedOnlyWhileTrimming() {
        assertEquals(1f, trimLaneAlpha(false, false), 0f)
        assertEquals(1f, trimLaneAlpha(true, true), 0f)
        assertEquals(0.45f, trimLaneAlpha(true, false), 0f)
    }

    @Test fun recordModeLabels() {
        assertEquals("Clean", RecordModeText.label(false))
        assertEquals("Quantized (lo-fi)", RecordModeText.label(true))
    }
}
