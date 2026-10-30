package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.StudioSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.OutputStream

class StudioSampleRelocationTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun sample(id: String, name: String) = StudioSample(id, "S", name, wasUserFolder = false, durationMs = 500)

    @Test fun movesAppFileToTheUserFolderAndStampsWasUserFolder() {
        val env = TestEnv(tmp.newFolder()); env.configured += StudioFamily.SAMPLES
        val s = env.store()
        val n = env.write(StudioFamily.SAMPLES, "smp_a", bytes = 64)
        val filed = s.addSampleRelocating(sample("smp_a", n))
        assertTrue(filed.wasUserFolder)
        assertEquals(64L, env.userFile(StudioFamily.SAMPLES, n).length())
        assertFalse(env.appFile(StudioFamily.SAMPLES, n).exists())
        assertTrue(s.sample("smp_a")!!.wasUserFolder)
    }

    @Test fun refilingAfterTheMoveKeepsTheUserFlag() {
        val env = TestEnv(tmp.newFolder()); env.configured += StudioFamily.SAMPLES
        val s = env.store()
        val n = env.write(StudioFamily.SAMPLES, "smp_a")
        s.addSampleRelocating(sample("smp_a", n))
        // a crash-retry / double file passes wasUserFolder=false again: must not clobber the record
        val again = s.addSampleRelocating(sample("smp_a", n))
        assertTrue(again.wasUserFolder)
        assertEquals(1, s.samples.size)
    }

    @Test fun failedCopyKeepsAppStorageRemovesPartialAndRaisesNotice() {
        val env = TestEnv(tmp.newFolder())
        val deleted = mutableListOf<String>()
        val failing = object : StudioDir {
            override val key = "fail"
            override fun exists(name: String) = false
            override fun list() = emptyList<String>()
            override fun length(name: String) = 0L
            override fun delete(name: String): Boolean { deleted += name; return true }
            override fun isWritable() = true
            override fun resolve(name: String): StudioFileRef? = null
            override fun openOutput(name: String): OutputStream? = object : OutputStream() {
                override fun write(b: Int) = throw java.io.IOException("disk gone")
            }
        }
        val roots = DefaultStudioRoots(java.io.File(env.base, "app"), userConfigured = { true }) { failing }
        val s = StudioStore(env.docFile, roots)
        val n = env.write(StudioFamily.SAMPLES, "smp_a")
        val filed = s.addSampleRelocating(sample("smp_a", n))
        assertFalse(filed.wasUserFolder)
        assertTrue(env.appFile(StudioFamily.SAMPLES, n).isFile)
        assertEquals(listOf(n), deleted)
        assertNotNull(s.samplesFolderNotice.value)
    }

    @Test fun movedSamplesAreCountedDeletedAndReconciledThroughTheUserRoot() {
        val env = TestEnv(tmp.newFolder()); env.configured += StudioFamily.SAMPLES
        val s = env.store()
        val a = env.write(StudioFamily.SAMPLES, "smp_a", bytes = 100)
        val b = env.write(StudioFamily.SAMPLES, "smp_b", bytes = 50)
        s.addSampleRelocating(sample("smp_a", a)); s.addSampleRelocating(sample("smp_b", b))
        assertEquals(150L, s.usageBytes(StudioFamily.SAMPLES))
        // unreachable: reconcile can't check -> nothing dropped
        env.unreachable += StudioFamily.SAMPLES
        s.reconcileOnLaunch()
        assertEquals(2, s.samples.size)
        env.unreachable -= StudioFamily.SAMPLES
        env.userFile(StudioFamily.SAMPLES, b).delete()           // user removed one in their Files app
        s.reconcileOnLaunch()
        assertNotNull(s.sample("smp_a")); assertNull(s.sample("smp_b"))
        assertTrue(s.deleteSample("smp_a"))
        assertFalse(env.userFile(StudioFamily.SAMPLES, a).exists())
        assertEquals(0L, s.usageBytes(StudioFamily.SAMPLES))
    }

    @Test fun deleteIsRefusedWhileTheUserRootIsUnreachable() {
        val env = TestEnv(tmp.newFolder()); env.configured += StudioFamily.SAMPLES
        val s = env.store()
        val n = env.write(StudioFamily.SAMPLES, "smp_a")
        s.addSampleRelocating(sample("smp_a", n))
        env.unreachable += StudioFamily.SAMPLES
        assertFalse(s.deleteSample("smp_a"))
        assertNotNull(s.sample("smp_a"))
    }
}
