package com.levi.pocketdj.mix.recording

import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class SessionFoldersTest {
    private fun tmp() = kotlin.io.path.createTempDirectory("mixrec").toFile()

    @Test fun nextTakeNameBumpsPastOnDiskFiles() {
        assertEquals("recording-1.aac", SessionFolders.nextTakeName(0, emptyList()))
        assertEquals("recording-3.aac", SessionFolders.nextTakeName(1, listOf("recording-2.aac")))
        assertEquals("recording-4.aac", SessionFolders.nextTakeName(0, listOf("recording-1.aac", "recording-2.aac", "recording-3.aac")))
    }

    @Test fun sessionFolderRejectsUnsafeIds() {
        val root = tmp()
        assertNull(SessionFolders.sessionFolder(root, ""))
        assertNull(SessionFolders.sessionFolder(root, "../x"))
        assertTrue(SessionFolders.sessionFolder(root, "abc")!!.isDirectory)
    }

    @Test fun deleteAllSkipsLiveTakeAndPrunesEmptyDirs() {
        val root = tmp()
        val a = SessionFolders.sessionFolder(root, "s1")!!
        val b = SessionFolders.sessionFolder(root, "s2")!!
        val live = File(a, "recording-2.aac").apply { writeBytes(ByteArray(10)) }
        File(a, "recording-1.aac").writeBytes(ByteArray(10))
        File(b, "recording-1.aac").writeBytes(ByteArray(10))
        assertEquals(30L, SessionFolders.usageBytes(root))
        SessionFolders.deleteAll(root, keep = live)
        assertEquals(10L, SessionFolders.usageBytes(root))
        assertTrue(live.exists())
        assertFalse(b.exists())
        assertNotNull(SessionFolders.allTakes(root).singleOrNull())
    }
}
