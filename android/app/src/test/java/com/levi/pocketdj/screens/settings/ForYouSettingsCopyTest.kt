package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.recs.ForYouRefreshCadence
import com.levi.pocketdj.data.recs.ForYouScheduleSettings
import com.levi.pocketdj.screens.settings.sections.ForYouSettingsCopy
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouSettingsCopyTest {
    @Test fun everyCadenceHasItsOwnFooterSentence() {
        val all = ForYouRefreshCadence.entries.map { ForYouSettingsCopy.cadenceFooter(it) }
        assertEquals(all.size, all.toSet().size)
        assertTrue(ForYouSettingsCopy.cadenceFooter(ForYouRefreshCadence.MANUAL).contains("only refreshes when you ask"))
    }

    @Test fun recsOffFooterAppearsOnlyWhenSomethingIsOffAndPluralises() {
        assertEquals("", ForYouSettingsCopy.recsOffFooter(0))
        val one = ForYouSettingsCopy.recsOffFooter(1)
        assertTrue(one.contains("1 collection — it gets") && one.contains("for it."))
        val two = ForYouSettingsCopy.recsOffFooter(2)
        assertTrue(two.contains("2 collections — they get") && two.contains("for them."))
        assertFalse(ForYouSettingsCopy.footer(ForYouRefreshCadence.DAILY, 0).contains("Recommendations are off"))
        assertTrue(ForYouSettingsCopy.footer(ForYouRefreshCadence.DAILY, 2).contains("Recommendations are off"))
    }

    @Test fun timeRowLabelsFollowTheCadence() {
        assertEquals("At minute", ForYouSettingsCopy.timeLabel(ForYouRefreshCadence.HOURLY))
        assertEquals("At", ForYouSettingsCopy.timeLabel(ForYouRefreshCadence.WEEKLY))
        assertEquals(":20", ForYouSettingsCopy.minutesLabel(16 * 60 + 20, ForYouRefreshCadence.HOURLY))
        assertEquals("16:20", ForYouSettingsCopy.minutesLabel(16 * 60 + 20, ForYouRefreshCadence.WEEKLY))
    }

    @Test fun nextRefreshIsADashForManualAndAFutureInstantOtherwise() {
        val now = ZonedDateTime.of(2026, 10, 28, 9, 0, 0, 0, ZoneId.of("UTC"))
        assertEquals("—", ForYouSettingsCopy.nextRefreshLabel(ForYouScheduleSettings(cadence = ForYouRefreshCadence.MANUAL), now))
        val weekly = ForYouSettingsCopy.nextRefreshLabel(ForYouScheduleSettings(), now)
        assertTrue(weekly.isNotBlank() && weekly != "—")
    }
}
