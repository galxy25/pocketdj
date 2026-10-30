package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.pockets.PocketsSettings
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.screens.settings.sections.RecommendationsSettingsCopy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecommendationsSectionTest {
    @Test fun toggleOnWritesAnsweredThenEnabled() = runTest {
        val writes = mutableListOf<Pair<PrefKey<Boolean>, Boolean>>()
        RecommendationsSettingsCopy.applyPocketsToggle(true) { k, v -> writes += k to v }
        assertEquals(
            listOf(PocketsSettings.LISTENING_POCKETS_ANSWERED to true, PocketsSettings.LISTENING_POCKETS_ENABLED to true),
            writes,
        )
    }

    @Test fun toggleOffStillMarksAnswered() = runTest {
        val writes = mutableListOf<Pair<PrefKey<Boolean>, Boolean>>()
        RecommendationsSettingsCopy.applyPocketsToggle(false) { k, v -> writes += k to v }
        assertEquals(PocketsSettings.LISTENING_POCKETS_ANSWERED to true, writes[0])
        assertEquals(PocketsSettings.LISTENING_POCKETS_ENABLED to false, writes[1])
    }

    @Test fun consentShowsOnlyWhileOff() {
        assertTrue(RecommendationsSettingsCopy.showConsent(false))
        assertFalse(RecommendationsSettingsCopy.showConsent(true))
        assertTrue(PocketsSettings.CONSENT_TEXT.startsWith("Turning this on sends"))
    }

    @Test fun syncErrorOnlyWhilePocketsOn() {
        assertEquals("boom", RecommendationsSettingsCopy.pocketsError("boom", true))
        assertNull(RecommendationsSettingsCopy.pocketsError("boom", false))
        assertNull(RecommendationsSettingsCopy.pocketsError(null, true))
    }
}
