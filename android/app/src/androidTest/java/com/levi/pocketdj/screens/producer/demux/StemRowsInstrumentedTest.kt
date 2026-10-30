package com.levi.pocketdj.screens.producer.demux

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.foundation.layout.Column
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.levi.pocketdj.studio.demux.StemPlayer
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** STU-14 emulator finding: mute/solo must redraw the stem rows (they used to stay on "Mute …" forever). */
@RunWith(AndroidJUnit4::class)
class StemRowsInstrumentedTest {
    @get:Rule val rule = createComposeRule()

    private class FakePlayer : StemPlayer {
        private val v = MutableStateFlow(0)
        override val version: StateFlow<Int> = v
        override var isPlaying = false
        override val currentTimeSec = 0.0
        override val durationSec = 30.0
        override var soloed: String? = null
        val muted = mutableSetOf<String>()
        override fun isAudible(name: String) = soloed?.let { it == name } ?: (name !in muted)
        override fun load(id: String, files: Map<String, File>) = true
        override fun togglePlayPause() { isPlaying = !isPlaying; v.value++ }
        override fun seek(sec: Double) {}
        override fun solo(name: String) { soloed = if (soloed == name) null else name; isPlaying = true; v.value++ }
        override fun toggleMute(name: String) { soloed = null; if (!muted.remove(name)) muted.add(name); v.value++ }
        override fun stop() {}
    }

    @Test fun muteAndSoloRedrawTheRows() {
        val p = FakePlayer()
        rule.setContent { Column { StemRows(p) } } // the app hosts the rows in a Column too
        rule.onNodeWithContentDescription("Mute vocals").performClick()
        rule.waitForIdle()
        rule.onNodeWithContentDescription("Unmute vocals").assertExists()
        rule.onNodeWithContentDescription("Solo drums").performClick()
        rule.waitForIdle()
        // Solo drums: every other stem reads as silent, vocals' mute is cleared by solo semantics.
        rule.onNodeWithContentDescription("Unmute bass").assertExists()
        rule.onNodeWithContentDescription("Mute drums").assertExists()
    }
}
