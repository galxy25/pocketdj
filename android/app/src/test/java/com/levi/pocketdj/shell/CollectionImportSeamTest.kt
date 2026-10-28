package com.levi.pocketdj.shell

import com.levi.pocketdj.data.collections.io.ImportKind
import com.levi.pocketdj.data.collections.io.ImportSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CollectionImportSeamTest {
    private fun seam(
        msgs: MutableList<String>,
        read: (String) -> ByteArray? = { ByteArray(1) },
        import: (ByteArray) -> ImportSummary = { ImportSummary(ImportKind.POCKET, pockets = 1, added = 1) },
        scope: kotlinx.coroutines.CoroutineScope,
    ) = CollectionImportSeam(scope, read, import, msgs::add, UnconfinedTestDispatcher())

    @Test fun installClaimsSeamAndPostsCounts() = runTest {
        val msgs = mutableListOf<String>()
        val seams = DeepLinkSeams()
        assertNull(seams.importCollection)
        val s = seam(msgs, scope = TestScope(UnconfinedTestDispatcher(testScheduler)))
        s.install(seams)
        assertNotNull(seams.importCollection)
        seams.importCollection!!.invoke("content://x/1")
        assertEquals(listOf("Imported 1 pocket"), msgs)
    }

    @Test fun unreadableAndForeignFilesAreReportedNotThrown() {
        val msgs = mutableListOf<String>()
        val scope = kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined)
        assertEquals("Couldn't open that file", seam(msgs, read = { null }, scope = scope).importNow("u"))
        assertEquals("Couldn't open that file", seam(msgs, read = { error("boom") }, scope = scope).importNow("u"))
        val bad = seam(msgs, import = { throw IllegalStateException("bad zip") }, scope = scope).importNow("u")
        assertEquals("Couldn't import: bad zip", bad)
    }

    @Test fun repeatImportReportsAlreadyUpToDate() {
        val scope = kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined)
        val s = seam(mutableListOf(), import = { ImportSummary(ImportKind.POCKET, pockets = 1, unchanged = 1) }, scope = scope)
        assertEquals("Already up to date - nothing new to import", s.importNow("u"))
    }
}
