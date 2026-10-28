package com.levi.pocketdj.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import kotlinx.coroutines.runBlocking
import org.junit.Test

class FeatureModuleRegistryTest {
    private class Fake(
        override val area: String,
        override val navEntries: List<NavEntry> = emptyList(),
        override val settingsSections: List<SettingsSection> = emptyList(),
        override val flushables: List<Flushable> = emptyList(),
        override val resetHooks: List<ResetHook> = emptyList(),
        override val rowResolvers: List<RowResolver> = emptyList(),
        override val syncEntries: List<SyncEntry> = emptyList(),
        override val periodicWork: List<PeriodicWorkSpec> = emptyList(),
    ) : FeatureModule

    private fun nav(id: String) = NavEntry(id) { }
    private fun section(id: String, order: Int) = SettingsSection(id, order) { }

    @Test
    fun fakeModule_surfacesInEveryAggregatedList() = runBlocking {
        var flushed = 0
        var reset = 0
        val navEntry = nav("studio/x")
        val sec = section("studio", 900)
        val fake = Fake(
            "studio",
            navEntries = listOf(navEntry),
            settingsSections = listOf(sec),
            flushables = listOf(Flushable { flushed++ }),
            resetHooks = listOf(ResetHook { reset++ }),
            rowResolvers = listOf(RowResolver("perf:") { "row:$it" }),
            syncEntries = listOf(SyncEntry("studio", "pocketdj-studio.json")),
            periodicWork = listOf(PeriodicWorkSpec("studio-prune", 1440)),
        )
        val reg = FeatureModuleRegistry(listOf(Fake("playback"), fake))
        assertSame(navEntry, reg.navEntries.single())
        assertSame(sec, reg.settingsSections.single())
        reg.flushAll()
        reg.resetAll()
        assertEquals(1, flushed)
        assertEquals(1, reset)
        assertEquals("row:perf:1", reg.resolveRow("perf:1"))
        assertNull(reg.resolveRow("other:1"))
        assertEquals("pocketdj-studio.json", reg.syncEntries.single().fileName)
        assertEquals("studio-prune", reg.periodicWork.single().id)
    }

    @Test
    fun aggregationOrder_isModuleOrder_andStable() {
        val reg = FeatureModuleRegistry(
            listOf(
                Fake("a", navEntries = listOf(nav("a1"), nav("a2"))),
                Fake("b", navEntries = listOf(nav("b1"))),
                Fake("c", navEntries = listOf(nav("c1"))),
            ),
        )
        assertEquals(listOf("a1", "a2", "b1", "c1"), reg.navEntries.map { it.routeId })
    }

    @Test
    fun duplicateRouteIds_failFast() {
        try {
            FeatureModuleRegistry(
                listOf(Fake("a", navEntries = listOf(nav("dup"))), Fake("b", navEntries = listOf(nav("dup")))),
            )
            fail("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("dup"))
        }
    }

    @Test
    fun duplicateSettingsSectionIds_failFast() {
        try {
            FeatureModuleRegistry(
                listOf(
                    Fake("a", settingsSections = listOf(section("s", 1))),
                    Fake("b", settingsSections = listOf(section("s", 2))),
                ),
            )
            fail("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("s"))
        }
    }

    @Test
    fun throwingFlushable_doesNotStopTheRest() = runBlocking {
        var ran = false
        val reg = FeatureModuleRegistry(
            listOf(Fake("a", flushables = listOf(Flushable { error("boom") }, Flushable { ran = true }))),
        )
        reg.flushAll()
        assertTrue(ran)
    }
}
