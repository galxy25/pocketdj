package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.data.settings.ShellSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellSettingsRowsTest {
    @Test fun defaults_matchIos() {
        assertEquals(3650, ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT.default)
        assertFalse(ShellSettings.RIP_FROM_CLOUD.default)
    }

    @Test fun persistedKeyNames_frozen() {
        assertEquals("defaultRecentlyAddedCount", ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT.name)
        assertEquals("ripFromCloud", ShellSettings.RIP_FROM_CLOUD.name)
    }

    @Test fun clamp_lowAndHigh() {
        assertEquals(1, ShellSettings.clampRecentlyAdded(0))
        assertEquals(1, ShellSettings.clampRecentlyAdded(-50))
        assertEquals(500, ShellSettings.clampRecentlyAdded(500))
        assertEquals(100_000, ShellSettings.clampRecentlyAdded(100_999))
        assertEquals(3650, ShellSettings.clampRecentlyAdded(3650))
    }

    @Test fun parse_digitsClampBlankAndGarbage() {
        assertEquals(50, ShellSettings.parseRecentlyAdded(" 50 "))
        assertEquals(1, ShellSettings.parseRecentlyAdded("0"))
        assertEquals(100_000, ShellSettings.parseRecentlyAdded("99999999999999999999"))
        assertNull(ShellSettings.parseRecentlyAdded(""))
        assertNull(ShellSettings.parseRecentlyAdded("12a"))
        assertNull(ShellSettings.parseRecentlyAdded("-5"))
    }

    @Test fun profileName_trimmed() {
        assertEquals("DJ Levi", ShellSettings.normalizeProfileName("  DJ Levi \n"))
        assertEquals("", ShellSettings.normalizeProfileName("   "))
    }

    @Test fun sectionOrder_profileFirst_ripToggleAfterImportServer() {
        val ids = listOf(
            com.levi.pocketdj.screens.settings.sections.profileSection(),
            com.levi.pocketdj.screens.settings.sections.collectionsSection(),
            com.levi.pocketdj.screens.settings.sections.ripFromCloudSection(),
        ).associate { it.id to it.order }
        val builtin = SettingsSections.builtin().associate { it.id to it.order }
        assertTrue(ids.getValue("profile") < builtin.values.min())
        assertEquals(305, ids["importServerRipFromCloud"])
        assertTrue(ids.getValue("importServerRipFromCloud") > builtin.getValue(SettingsSections.IMPORT_SERVER))
        assertTrue(ids.getValue("importServerRipFromCloud") < builtin.getValue(SettingsSections.APPLE_MUSIC))
        assertTrue(PrefKey.int("x", 1).default == 1)
    }
}
