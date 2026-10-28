package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.levi.pocketdj.studio.store.ArrangerMath
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Anchors the follow-scroll wiring: a cursor past the first screenful ends up centred in the viewport. */
@RunWith(AndroidJUnit4::class)
class FollowTimelineInstrumentedTest {
    @get:Rule val rule = createComposeRule()

    @Test fun cursorPastFirstScreenfulIsCentredInViewport() {
        val pxPerSec = 40f
        val cursorMs = 60_000
        val contentDp = ArrangerMath.timelineWidth(120_000, pxPerSec)
        rule.setContent {
            FollowTimeline(cursorMs, pxPerSec, contentDp, follow = true, centerNonce = 0, onViewportDp = {}, modifier = Modifier.fillMaxWidth().height(100.dp)) {
                Box(Modifier.width(contentDp.dp).height(100.dp)) { CursorOverlay(cursorMs, pxPerSec, 2) }
            }
        }
        rule.waitForIdle()
        rule.onNodeWithTag("tracks-cursor-anchor").assertIsDisplayed()
        val viewport = rule.onNodeWithTag("tracks-timeline").getBoundsInRoot()
        val cursor = rule.onNodeWithTag("tracks-cursor-anchor").getBoundsInRoot()
        val viewportCentre = (viewport.left + viewport.right).value / 2f
        assertEquals(viewportCentre, cursor.left.value + 1f, 2f) // anchor is 2dp wide: centre = left + 1
    }

    @Test fun cursorInFirstHalfScreenfulDoesNotScroll() {
        rule.setContent {
            FollowTimeline(500, 40f, 2000f, follow = true, centerNonce = 0, onViewportDp = {}, modifier = Modifier.fillMaxWidth().height(100.dp)) {
                Box(Modifier.width(2000.dp).height(100.dp)) { CursorOverlay(500, 40f, 2) }
            }
        }
        rule.waitForIdle()
        val cursor = rule.onNodeWithTag("tracks-cursor-anchor").getBoundsInRoot()
        assertEquals(20f, cursor.left.value, 1f)
    }
}
