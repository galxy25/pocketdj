package com.levi.pocketdj.data.credentials

import com.levi.pocketdj.diag.DiagCredentialStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiagKeySyncTest {
    @get:Rule val tmp = TemporaryFolder()
    private val secrets = InMemorySecretStore()
    private val store = DiagCredentialStore(secrets)
    private fun file() = File(tmp.root, "diag-key.json")
    private fun sync() = DiagKeySync(file(), store)

    @Test fun keylessDevice_neverCreatesDoc() {
        assertFalse(sync().materialize())
        assertFalse(file().exists())
    }

    @Test fun materialize_writesOnlyWhenChanged() {
        store.save("AKIA1", "sec1")
        val s = sync()
        assertTrue(s.materialize())
        val mtime = file().lastModified()
        assertFalse(s.materialize())
        assertEquals(mtime, file().lastModified())
        store.save("AKIA1", "sec2")
        assertTrue(s.materialize())
        assertEquals(
            """{"accessKeyID":"AKIA1","schemaVersion":1,"secret":"sec2"}""",
            file().readText(),
        )
    }

    @Test fun pulledKey_isAdopted_thenUnchanged() {
        file().writeText("""{"accessKeyID":" AKIA9 ","schemaVersion":1,"secret":"s9\n"}""")
        assertEquals(DiagKeySync.PullResult.ADOPTED, sync().applyPulled())
        assertEquals(DiagCredentialStore.Credentials("AKIA9", "s9"), store.load())
        assertEquals(DiagKeySync.PullResult.UNCHANGED, sync().applyPulled())
    }

    @Test fun emptyOrUndecodablePull_neverClearsLocalKey() {
        store.save("AKIA1", "sec1")
        for (body in listOf(
            """{"accessKeyID":"","schemaVersion":1,"secret":""}""",
            """{"accessKeyID":"AKIA2","schemaVersion":1,"secret":""}""",
            "nope",
        )) {
            file().writeText(body)
            assertEquals(DiagKeySync.PullResult.IGNORED_EMPTY, sync().applyPulled())
            assertEquals(DiagCredentialStore.Credentials("AKIA1", "sec1"), store.load())
        }
    }

    @Test fun missingFile_isIgnored() {
        assertEquals(DiagKeySync.PullResult.IGNORED_EMPTY, DiagKeySync(File(tmp.root, "missing.json"), store).applyPulled())
        assertNull(store.load())
    }
}
