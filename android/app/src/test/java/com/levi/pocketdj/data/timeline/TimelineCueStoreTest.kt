package com.levi.pocketdj.data.timeline

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TimelineCueStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private fun file() = File(tmp.root, TimelineCueStore.FILE_NAME)

    @Test fun addTrimsRejectsBlankAndSorts() {
        val s = TimelineCueStore(file())
        assertNull(s.add("   ", 100.0))
        assertNull(s.add("x", 0.0))
        s.add("  late ", 300.0); s.add("early", 100.0)
        assertEquals(listOf("early", "late"), s.cues.map { it.name })
        assertEquals(60, s.add("n".repeat(100), 200.0)!!.name.length)
    }

    @Test fun persistsAndReloads() {
        val s = TimelineCueStore(file())
        val c = s.add("binge", 500.0, nowMs = 9.0)!!
        val again = TimelineCueStore(file())
        assertEquals(listOf(c), again.cues)
        assertTrue(file().readText().contains("\"schemaVersion\":1"))
    }

    @Test fun renameMoveRemove() {
        val s = TimelineCueStore(file())
        val c = s.add("a", 10.0)!!
        assertFalse(s.rename(c.id, " "))
        assertTrue(s.rename(c.id, "b"))
        assertFalse(s.rename(c.id, "b"))
        assertTrue(s.move(c.id, 50.0))
        assertEquals(50.0, s.cues[0].atMs, 0.0)
        assertTrue(s.remove(c.id)); assertFalse(s.remove(c.id))
        assertEquals("[]", TimelineCueStore.decodeDocument(file().readText())!!.toString())
    }

    @Test fun lenientDecodeDropsBadCueKeepsRest() {
        file().writeText("""{"schemaVersion":9,"extra":1,"cues":[{"id":"A","name":"ok","atMs":5},{"id":"B","name":"bad"},{"id":"C","name":"z","atMs":1,"note":"n"}]}""")
        val s = TimelineCueStore(file())
        assertEquals(listOf("C", "A"), s.cues.map { it.id })
        assertEquals("n", s.cues[0].note)
    }

    @Test fun missingCuesAndGarbage() {
        file().writeText("{}")
        assertTrue(TimelineCueStore(file()).cues.isEmpty())
        file().writeText("not json")
        assertTrue(TimelineCueStore(file()).cues.isEmpty())
    }

    @Test fun capDropsOldestCreated() {
        val s = TimelineCueStore(file())
        val cues = (1..501).map { TimelineCueStore.Cue("id$it", "c$it", it.toDouble(), createdAtMs = (502 - it).toDouble()) }
        s.replaceAll(cues)
        assertEquals(500, s.cues.size)
        assertTrue(s.cues.none { it.id == "id501" }) // smallest createdAt
    }

    @Test fun nearestWithinTolerance() {
        val s = TimelineCueStore(file())
        s.add("a", 100.0); s.add("b", 1000.0)
        assertEquals("a", s.nearest(120.0, 50.0)!!.name)
        assertNull(s.nearest(500.0, 50.0))
    }

    @Test fun clearDeletesFileAndReloadAdoptsDisk() {
        val s = TimelineCueStore(file())
        s.add("a", 1.0)
        val other = TimelineCueStore(file())
        other.add("b", 2.0)
        assertFalse(s.reloadFromDisk())
        assertEquals(2, s.cues.size)
        s.clear()
        assertFalse(file().exists())
        assertNotNull(s.state.value)
        assertTrue(s.cues.isEmpty())
    }
}
