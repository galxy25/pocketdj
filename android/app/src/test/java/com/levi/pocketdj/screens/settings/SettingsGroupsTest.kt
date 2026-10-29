package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.screens.settings.sections.SyncUi
import com.levi.pocketdj.shell.SettingsSection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsGroupsTest {
    private fun s(id: String, order: Int) = SettingsSection(id, order) { }

    @Test fun ordersBucketIntoIosStyleGroupsInOrder() {
        val grouped = SettingsGroups.group(
            listOf(s("debug", 900), s("profile", 50), s("data", 100), s("am", 400), s("mix", 520),
                s("history", 600), s("storage", 700), s("about", 800), s("reset", 950), s("link", 51)),
        )
        assertEquals(
            listOf(SettingsGroup.ACCOUNT, SettingsGroup.LIBRARY, SettingsGroup.APPLE_MUSIC, SettingsGroup.PLAYBACK,
                SettingsGroup.LISTENING, SettingsGroup.STORAGE, SettingsGroup.ABOUT, SettingsGroup.ADVANCED),
            grouped.map { it.first },
        )
        assertEquals(listOf("profile", "link"), grouped.first().second.map { it.id })
        assertEquals(listOf("debug", "reset"), grouped.last().second.map { it.id })
    }

    @Test fun syncSwitchIsNeverOnWithoutAnAccount() {
        assertFalse(SyncUi.switchOn(pref = true, accountAvailable = false))
        assertFalse(SyncUi.switchEnabled(false))
        assertTrue(SyncUi.switchOn(pref = true, accountAvailable = true))
        assertTrue(SyncUi.switchOn(pref = true, accountAvailable = null)) // unknown yet: show the preference
        assertEquals(SyncUi.NO_ACCOUNT, SyncUi.caption(false, null, "Account unavailable"))
        assertEquals("Sync failed: boom", SyncUi.caption(true, "boom", null))
    }
}
