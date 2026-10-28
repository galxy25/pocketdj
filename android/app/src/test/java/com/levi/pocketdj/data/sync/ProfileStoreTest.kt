package com.levi.pocketdj.data.sync

import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class ProfileStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private fun file() = File(tmp.root, ProfileStore.FILE_NAME)

    @Test fun mintsIdOnceAndKeepsItAcrossRestarts() {
        val a = ProfileStore(file()).also { it.setName("DJ A") }
        val b = ProfileStore(file())
        assertEquals(a.id, b.id)
        assertEquals("DJ A", b.name)
        assertEquals(a.createdAtMs, b.createdAtMs, 0.0)
        assertTrue(a.id.isNotBlank())
    }

    @Test fun migratesLegacyNameOnceAndMaterializesFile() {
        val s = ProfileStore(file())
        assertTrue(!file().exists())
        s.migrateIfNeeded("  Legacy DJ ")
        assertEquals("Legacy DJ", s.name)
        assertTrue(file().exists())
        s.migrateIfNeeded("Other")
        assertEquals("Legacy DJ", s.name) // no-op once named
        val blank = ProfileStore(File(tmp.root, "b.json"))
        blank.migrateIfNeeded("   ")
        assertEquals("", blank.name)
        assertTrue(!File(tmp.root, "b.json").exists())
    }

    @Test fun setNamePersistsAndMirrors() {
        val s = ProfileStore(file())
        val seen = mutableListOf<String>()
        s.onNameApplied = { seen += it }
        s.setName("Levi")
        assertEquals(listOf("Levi"), seen)
        assertEquals("Levi", ProfileStore(file()).name)
    }

    @Test fun reloadFollowsCloudDocIdentityAndRemirrors() {
        val s = ProfileStore(file())
        s.setName("Local")
        val seen = mutableListOf<String>()
        s.onNameApplied = { seen += it }
        // A pulled iOS-shaped document replaces the file.
        file().writeText("""{"schemaVersion":1,"id":"CLOUD-ID","name":"Cloud DJ","createdAtMs":1700000000000.0}""")
        s.reloadFromDisk()
        assertEquals("CLOUD-ID", s.id)
        assertEquals("Cloud DJ", s.name)
        assertEquals(1700000000000.0, s.createdAtMs, 0.0)
        assertEquals(listOf("Cloud DJ"), seen)
    }

    @Test fun reloadOfMissingOrGarbledFileKeepsState() {
        val s = ProfileStore(file())
        s.setName("Keep")
        file().writeText("{ nope")
        s.reloadFromDisk()
        assertEquals("Keep", s.name)
    }

    @Test fun resetMintsNewIdentityAndMirrorsEmptyName() {
        val s = ProfileStore(file())
        s.setName("Gone")
        val oldId = s.id
        val seen = mutableListOf<String>()
        s.onNameApplied = { seen += it }
        s.reset()
        assertNotEquals(oldId, s.id)
        assertEquals("", s.name)
        assertEquals(listOf(""), seen)
        val reread = ProfileStore(file())
        assertEquals(s.id, reread.id)
        assertEquals("", reread.name)
    }

    @Test fun writesIosShapedJsonKeys() {
        val s = ProfileStore(file())
        s.setName("Shape")
        val text = file().readText()
        for (k in listOf("\"schemaVersion\":1", "\"id\":", "\"name\":\"Shape\"", "\"createdAtMs\":")) {
            assertTrue("missing $k in $text", text.contains(k))
        }
    }

    @Test fun decodesDocumentMissingNameLeniently() {
        file().writeText("""{"id":"X","createdAtMs":5.0,"futureField":true}""")
        val s = ProfileStore(file())
        assertEquals("X", s.id)
        assertEquals("", s.name)
    }

    @Test fun adoptIdentity_storesUpperCaseId_andPersists() {
        val s = ProfileStore(file())
        s.adoptIdentity("3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        assertEquals("3F2504E0-4F89-41D3-9A0C-0305E82C3301", s.id)
        assertEquals(s.id, ProfileStore(file()).id)
    }
}
