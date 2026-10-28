package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioTake
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StudioReconcileTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }

    private fun sample(id: String, user: Boolean = false) =
        StudioSample(id, id, StudioFolders.fileName(StudioFamily.SAMPLES, id), wasUserFolder = user)

    private fun loop(id: String) =
        StudioLoop(id, id, "smp_kept", fileName = StudioFolders.fileName(StudioFamily.LOOPS, id))

    @Test fun keepsUnreachableAndDropsProvablyGone() {
        env.configured += setOf(StudioFamily.SAMPLES, StudioFamily.TAKES)
        env.unreachable += setOf(StudioFamily.SAMPLES, StudioFamily.TAKES)   // SAF tree revoked / drive unplugged
        val s = env.store()
        env.write(StudioFamily.SAMPLES, "smp_kept")
        s.addSample(sample("smp_kept"))                    // app root, file present -> kept
        s.addSample(sample("smp_gone"))                    // app root, file vanished -> dropped
        s.addSample(sample("smp_user", user = true))       // unreachable user root -> SKIP, kept
        env.write(StudioFamily.LOOPS, "lp_kept")
        s.addLoop(loop("lp_kept")); s.addLoop(loop("lp_gone"))
        s.addPattern(StudioPattern.of("ptn_b", "P", rows = listOf(StudioPatternRow.of("lp_kept")),
            fileName = StudioFolders.fileName(StudioFamily.SEQUENCES, "ptn_b"), bounceDirty = false))
        s.addTake(StudioTake("tk_gone", "T", fileName = StudioFolders.fileName(StudioFamily.TAKES, "tk_gone")))
        s.addTake(StudioTake("tk_user", "T", fileName = StudioFolders.fileName(StudioFamily.TAKES, "tk_user"), wasUserFolder = true))

        val r = s.reconcileOnLaunch()

        assertTrue(r.changed)
        assertNotNull(s.sample("smp_kept")); assertNull(s.sample("smp_gone"))
        assertNotNull(s.sample("smp_user"))                // unreachable root => never pruned
        assertNotNull(s.loop("lp_kept")); assertNull(s.loop("lp_gone"))
        val p = s.pattern("ptn_b")!!                       // bounce lost: the pattern (its steps) survives
        assertNull(p.fileName); assertTrue(p.bounceDirty)
        assertEquals(1, p.rows.size)
        assertNull(s.take("tk_gone")); assertNotNull(s.take("tk_user"))
        assertEquals(1, r.prunedSamples); assertEquals(1, r.prunedLoops); assertEquals(1, r.prunedTakes)

        // The prune was persisted.
        val again = env.store()
        assertNull(again.sample("smp_gone")); assertNotNull(again.sample("smp_user"))
    }

    @Test fun userRootRecordsArePrunedOnlyOnceTheRootIsReachableAndTheFileIsMissing() {
        env.configured += StudioFamily.SAMPLES
        val s = env.store()
        env.write(StudioFamily.SAMPLES, "smp_present", user = true)
        s.addSample(sample("smp_present", user = true)); s.addSample(sample("smp_lost", user = true))
        env.unreachable += StudioFamily.SAMPLES
        assertFalse(s.reconcileOnLaunch().changed)          // can't check => nothing happens at all
        assertEquals(2, s.samples.size)
        env.unreachable -= StudioFamily.SAMPLES
        s.reconcileOnLaunch()                                // reachable: lost file is provably gone
        assertNotNull(s.sample("smp_present")); assertNull(s.sample("smp_lost"))
    }

    @Test fun danglingRenderAndBounceReferencesAreNulledNotDeletedRecords() {
        val s = env.store()
        env.write(StudioFamily.SAMPLES, "smp_a")
        s.addSample(sample("smp_a").copy(renderedFileName = StudioFolders.renderedSampleFileName("smp_a", 1),
            renderedRevision = 1, renderRevision = 1, renderedWasUserFolder = false))
        env.write(StudioFamily.TAKES, "tk_a")
        s.addTake(StudioTake("tk_a", "T", fileName = StudioFolders.fileName(StudioFamily.TAKES, "tk_a"),
            renderedFileName = StudioFolders.renderedTakeFileName("tk_a", 0), renderedWasUserFolder = false))
        s.addPattern(StudioPattern.of("ptn_a", "P", fileName = "pattern-ptn_a.m4a", bounceDirty = false))

        s.reconcileOnLaunch()

        val smp = s.sample("smp_a")!!
        assertNull(smp.renderedFileName); assertNull(smp.renderedRevision); assertNull(smp.renderedWasUserFolder)
        assertFalse(smp.isRenderFresh)
        assertNull(s.take("tk_a")!!.renderedFileName)
        val p = s.pattern("ptn_a")!!
        assertNull(p.fileName); assertTrue(p.bounceDirty)            // bounceDirty=true: stale bounce never plays
    }

    @Test fun danglingCrossRefsAreFlaggedNeverDeleted() {
        val s = env.store()
        env.write(StudioFamily.LOOPS, "lp_orphan")
        s.addLoop(loop("lp_orphan").copy(sampleId = "smp_deleted"))
        s.addPattern(StudioPattern.of("ptn_x", "P", rows = listOf(StudioPatternRow.of("smp_deleted"))))
        val r = s.reconcileOnLaunch()
        assertFalse(r.changed)                                        // nothing touched
        assertNotNull(s.loop("lp_orphan")); assertEquals(1, s.pattern("ptn_x")!!.rows.size)
        assertFalse(s.sampleExists("smp_deleted"))
    }

    @Test fun traversalFileNamesAreTreatedAsGone() {
        val s = env.store()
        s.addSample(StudioSample("smp_h", "h", "../../etc/passwd"))
        s.reconcileOnLaunch()
        assertNull(s.sample("smp_h"))                                  // a path separator never resolves to a file
    }

    @Test fun noChangeMeansNoRewrite() {
        val s = env.store()
        env.write(StudioFamily.SAMPLES, "smp_a")
        s.addSample(sample("smp_a"))
        val before = env.docFile.lastModified()
        val bytes = env.docFile.readText()
        assertFalse(s.reconcileOnLaunch().changed)
        assertEquals(bytes, env.docFile.readText()); assertEquals(before, env.docFile.lastModified())
    }

    /** A user root that opens fine but whose listing (and point queries) then FAIL, like a flaky SAF provider. */
    private class FlakyUserDir(val inner: StudioDir) : StudioDir by inner {
        override fun list(): List<String> = throw StudioDirUnavailableException("provider offline")
        override fun resolve(name: String): StudioFileRef? = null
        override fun exists(name: String) = false
    }

    private fun flakyRoots(opens: IntArray) = object : StudioRoots by env.roots {
        override fun userDir(family: StudioFamily): StudioDir? {
            opens[0]++
            return FlakyUserDir(FileStudioDir(env.userFile(family, "x").parentFile!!))
        }
    }

    @Test fun listingFailureAfterSuccessfulOpenNeverPrunes() {
        val s = env.store()
        s.addSample(sample("smp_user", user = true)); s.addLoop(loop("lp_u").copy(wasUserFolder = true))
        val r = StudioReconcile.reconcile(s.doc, flakyRoots(IntArray(1)))
        assertFalse(r.changed)
        assertEquals(1, r.doc.samples.size); assertEquals(1, r.doc.loops.size)
    }

    @Test fun reconcileOpensEachUserRootOncePerFamily() {
        val s = env.store()
        (1..5).forEach { s.addSample(sample("smp_$it", user = true)) }
        val opens = IntArray(1)
        StudioReconcile.reconcile(s.doc, flakyRoots(opens))
        assertEquals(1, opens[0])
    }

    @Test fun deleteAllKeepsRecordsWhenUserListingFails() {
        val s = env.store()
        s.addSample(sample("smp_user", user = true))
        val out = StudioReconcile.deleteAll(s.doc, flakyRoots(IntArray(1)), StudioFamily.SAMPLES)
        assertEquals(1, out.samples.size)
    }
}
