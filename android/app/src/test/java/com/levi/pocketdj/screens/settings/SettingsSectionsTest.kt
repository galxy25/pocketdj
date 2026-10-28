package com.levi.pocketdj.screens.settings

import com.levi.pocketdj.shell.SettingsSection
import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsSectionsTest {
    @Test
    fun builtin_isTheShippedBlocksInShippedOrder() {
        val ids = SettingsSections.ordered(SettingsSections.builtin()).map { it.id }
        assertEquals(
            listOf(
                "dataSources", "catalog", "importServer", "appleMusic",
                "jukeboxBroker", "history", "storage", "about",
            ),
            ids,
        )
    }

    @Test
    fun ordered_interleavesContributedSections_stably() {
        val extra = listOf(
            SettingsSection("zeta", 250) { },
            SettingsSection("alpha", 250) { }, // tie: registration order kept
            SettingsSection("last", 900) { },
        )
        val ids = SettingsSections.ordered(extra + SettingsSections.builtin()).map { it.id }
        assertEquals(
            listOf(
                "dataSources", "catalog", "zeta", "alpha", "importServer", "appleMusic",
                "jukeboxBroker", "history", "storage", "about", "last",
            ),
            ids,
        )
    }

    @Test
    fun builtinIds_areUnique() {
        val ids = SettingsSections.builtin().map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }
}
