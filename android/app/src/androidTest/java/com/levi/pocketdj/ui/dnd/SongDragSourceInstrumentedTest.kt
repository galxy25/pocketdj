package com.levi.pocketdj.ui.dnd

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.levi.pocketdj.data.collections.SongTransfer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * COL-6 emulator finding: long-press opens the row's Add-to menu (a Dialog window) at the same timeout the drag
 * arms; left open, that window swallowed the drop. The source must call [songDragSource]'s onDragStart as the item
 * lifts so the host can dismiss the menu, and must NOT call it for a stationary long-press (menu stays).
 */
@RunWith(AndroidJUnit4::class)
class SongDragSourceInstrumentedTest {
    @get:Rule val rule = createComposeRule()

    private var lifts = 0

    private fun compose() {
        rule.setContent {
            Box(
                Modifier.size(200.dp).testTag("row")
                    .songDragSource(enabled = true, onDragStart = { lifts++ }) { SongTransfer(listOf("sng_a"), null) },
            )
        }
    }

    @Test fun longPressThenMoveCallsOnDragStart() {
        compose()
        rule.onNodeWithTag("row").performTouchInput {
            down(center)
            advanceEventTime(viewConfiguration.longPressTimeoutMillis + 150)
            moveBy(androidx.compose.ui.geometry.Offset(0f, 60f))
            moveBy(androidx.compose.ui.geometry.Offset(0f, 60f))
            up()
        }
        rule.waitForIdle()
        assertTrue("drag lift must notify the host", lifts >= 1)
    }

    @Test fun stationaryLongPressDoesNotCallOnDragStart() {
        compose()
        rule.onNodeWithTag("row").performTouchInput {
            down(center)
            advanceEventTime(viewConfiguration.longPressTimeoutMillis + 150)
            up()
        }
        rule.waitForIdle()
        assertEquals(0, lifts)
    }
}
