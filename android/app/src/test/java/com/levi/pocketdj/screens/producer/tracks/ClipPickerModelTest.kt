package com.levi.pocketdj.screens.producer.tracks

import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioDocument
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.store.ArrangerMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipPickerModelTest {
    private fun doc() = StudioDocument(
        samples = listOf(StudioSample("smp_1", "Kick", "k.m4a", false), StudioSample("smp_2", "", "n.m4a", false)),
        loops = listOf(StudioLoop("lp_1", "Kick Loop", "smp_1", fileName = "l.wav")),
        patterns = listOf(StudioPattern("ptn_1", "Groove")),
        takes = listOf(StudioTake("tk_1", "Keys", fileName = "t.m4a")),
        arrangementArtifacts = listOf(
            StudioArrangementArtifact("art_1", "arr_1", StudioArrangementArtifact.Kind.BOUNCE, "Bounce A", "a.m4a", createdAt = 1.0),
            StudioArrangementArtifact("art_2", "arr_1", StudioArrangementArtifact.Kind.RECORDING, "Live B", "b.m4a", createdAt = 2.0),
        ),
    )

    @Test fun sectionsCoverEverySourceKindInPickerOrder() {
        val stems = listOf(PickItem("song1", "Artist - Song"))
        val s = ClipPickerModel.sections(doc(), stems, "")
        assertEquals(listOf("samples", "loops", "sequences", "takes", "stems", "artifacts"), s.map { it.key })
        assertEquals(listOf(StudioClipSource.SAMPLE, StudioClipSource.LOOP, StudioClipSource.PATTERN, StudioClipSource.TAKE, null, null), s.map { it.kind })
        assertEquals("Untitled", s[0].items[1].name)                          // blank names read as Untitled
        assertEquals("4 stems", s[4].items.single().detail)
        assertEquals(listOf("art_2", "art_1"), s[5].items.map { it.id })       // artifacts newest first
    }

    @Test fun searchFiltersCaseInsensitivelyAndDropsEmptySections() {
        val s = ClipPickerModel.sections(doc(), emptyList(), "kick")
        assertEquals(listOf("samples", "loops"), s.map { it.key })
        assertEquals(listOf("smp_1"), s[0].items.map { it.id })
        assertTrue(ClipPickerModel.sections(doc(), emptyList(), "zzz").isEmpty())
    }

    @Test fun emptyDocumentHasNoSources() {
        assertTrue(ClipPickerModel.isEmpty(StudioDocument(), emptyList()))
        // A stem song alone is enough to show the picker.
        assertEquals(false, ClipPickerModel.isEmpty(StudioDocument(), listOf(PickItem("s", "S"))))
    }

    @Test fun panDialMapsAngleToPanWithCenterDetentAndClamp() {
        assertNull(ArrangerMath.panForPoint(0.2f, 0.2f))                         // on the hub: no direction
        assertEquals(0.0, ArrangerMath.panForPoint(0f, -50f)!!, 0.0)            // straight up = centre
        assertEquals(0.0, ArrangerMath.panForPoint(2f, -50f)!!, 0.0)            // inside the 6% detent
        assertEquals(90.0 / 135.0, ArrangerMath.panForPoint(50f, 0f)!!, 0.001)  // 90 deg right
        assertEquals(-90.0 / 135.0, ArrangerMath.panForPoint(-50f, 0f)!!, 0.001)
        assertEquals(1.0, ArrangerMath.panForPoint(1f, 50f)!!, 0.0)              // straight down clamps to hard right
        assertEquals(-1.0, ArrangerMath.panForPoint(-1f, 50f)!!, 0.0)
        assertEquals("Center", ArrangerMath.panText(0.01)); assertEquals("Left 40%", ArrangerMath.panText(-0.4)); assertEquals("Right 100%", ArrangerMath.panText(1.0))
    }
}
