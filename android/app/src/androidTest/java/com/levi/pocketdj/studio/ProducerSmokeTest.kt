package com.levi.pocketdj.studio

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.levi.pocketdj.MainActivity
import com.levi.pocketdj.screens.producer.StudioSubTab
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * STU-16 emulator smoke (run by the integrator on the 'pocketdj' AVD; NOT part of the JVM suite).
 *
 * Launches MainActivity with the debug seed extras (`PDJ_SEED_STUDIO`, `PDJ_SEED_DEMUX`), opens Producer, walks all
 * seven sub-tabs, asserts the seeded rows render where the tab lists them, and writes one PNG per sub-tab to
 * `<externalFilesDir>/producer-smoke/<tab>.png` (pull with `adb pull /sdcard/Android/data/com.levi.pocketdj/files/producer-smoke`).
 * Review `adb logcat | grep -E "audio\\.(play|stop)"` afterwards for the StudioDiag reason lines.
 */
@RunWith(AndroidJUnit4::class)
class ProducerSmokeTest {
    @get:Rule val compose = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null

    @After fun tearDown() { scenario?.close() }

    private fun shot(tab: StudioSubTab) {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(ctx.getExternalFilesDir(null), "producer-smoke").apply { mkdirs() }
        File(dir, "${tab.raw}.png").outputStream().use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private fun hasText(t: String) = compose.onAllNodesWithText(t).fetchSemanticsNodes().isNotEmpty()

    @Test fun walksAllSevenSubTabsWithSeed() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = Intent(ctx, MainActivity::class.java)
            .putExtra(StudioSeed.STUDIO_EXTRA, true)
            .putExtra(StudioSeed.DEMUX_EXTRA, true)
        scenario = ActivityScenario.launch(intent)

        compose.waitUntil(15_000) { compose.onAllNodesWithText("Producer").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText("Producer").onFirst().performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("producer-screen").fetchSemanticsNodes().isNotEmpty() }

        // Seeded rows each tab is expected to list (null = the tab has no seeded row; selection + render only).
        val expected = mapOf(
            StudioSubTab.Samples to "Seed Tone",
            StudioSubTab.Loops to "Seed Loop",
            StudioSubTab.Sequencer to "Seed Pattern",
        )
        for (tab in StudioSubTab.entries) {
            compose.onNodeWithTag("studio-tab-${tab.raw}").performClick()
            compose.onNodeWithTag("studio-tab-${tab.raw}").assertIsSelected()
            expected[tab]?.let { row ->
                compose.waitUntil(10_000) { hasText(row) }
                assertTrue("${tab.label}: seeded row '$row' renders", hasText(row))
            }
            compose.waitForIdle()
            shot(tab)
        }
    }
}
