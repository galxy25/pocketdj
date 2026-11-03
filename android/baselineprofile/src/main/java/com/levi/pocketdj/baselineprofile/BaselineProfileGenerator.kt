package com.levi.pocketdj.baselineprofile

import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private const val PACKAGE = "com.levi.pocketdj"
private const val WAIT_MS = 5_000L

/**
 * Generates PocketDJ's Baseline Profile (AOT-compiled hot paths) and Startup Profile (R8 DEX
 * layout: startup classes packed into the primary dex).
 *
 * Run: `./gradlew :app:generateReleaseBaselineProfile` with the pocketdj AVD (or a phone, API 33+)
 * connected. Journeys are UI-text driven (UiAutomator By.text / By.desc) and tolerant: a surface
 * that isn't reachable on the device (no network, no Apple Music sign-in) is skipped, never failed,
 * so the profile still covers everything that did render.
 */
@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {

    @get:Rule
    val rule = BaselineProfileRule()

    /** Cold start into the main shell: the only journey that feeds the Startup Profile. */
    @Test
    fun startup() = rule.collect(packageName = PACKAGE, includeInStartupProfile = true) {
        pressHome()
        startActivityAndWait()
        completeOnboardingIfShown()
        device.wait(Until.hasObject(By.desc("Browse")), WAIT_MS)
    }

    /** The main tabs and the folded "More" sections, plus Settings. */
    @Test
    fun mainJourneys() = rule.collect(packageName = PACKAGE, includeInStartupProfile = false) {
        pressHome()
        startActivityAndWait()
        completeOnboardingIfShown()

        tab("Browse")
        scrollFirstScrollable()
        tab("History")
        scrollFirstScrollable()
        tab("Collections")
        scrollFirstScrollable()

        for (section in listOf("Mix", "Producer", "Jukebox", "Games")) {
            tab("More")
            clickIfPresent(By.text(section))
            device.waitForIdle()
            scrollFirstScrollable()
        }

        tab("Browse")
        if (clickIfPresent(By.desc("Settings"))) {
            device.waitForIdle()
            scrollFirstScrollable()
            device.pressBack()
        }
    }

    // --- helpers -------------------------------------------------------------------------------

    /** First-run onboarding: "just this device", no Apple Music, then into the app. */
    private fun MacrobenchmarkScope.completeOnboardingIfShown() {
        if (!clickIfPresent(By.text("Use on this device"), 2_000)) return
        // Stage 1 (DJ name) -> stage 2 (Apple Music, skipped) -> stage 3 ("Start DJing").
        for (label in listOf("Continue", "Continue without Apple Music", "Start DJing")) {
            clickIfPresent(By.text(label))
        }
        device.waitForIdle()
    }

    private fun MacrobenchmarkScope.tab(label: String) {
        clickIfPresent(By.desc(label))
        device.waitForIdle()
    }

    private fun MacrobenchmarkScope.clickIfPresent(selector: BySelector, timeoutMs: Long = WAIT_MS): Boolean {
        val obj: UiObject2 = device.wait(Until.findObject(selector), timeoutMs) ?: return false
        return runCatching { obj.click(); true }.getOrDefault(false)
    }

    private fun MacrobenchmarkScope.scrollFirstScrollable() {
        val list = device.wait(Until.findObject(By.scrollable(true)), 2_000) ?: return
        runCatching {
            list.setGestureMargin(device.displayWidth / 5)
            list.fling(Direction.DOWN)
            device.waitForIdle()
            list.fling(Direction.UP)
        }
        device.waitForIdle()
    }
}
