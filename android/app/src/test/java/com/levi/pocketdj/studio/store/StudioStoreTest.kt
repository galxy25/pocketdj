package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.Accidental
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioCueDoc
import com.levi.pocketdj.studio.model.StudioDocument
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.model.STUDIO_SCHEMA_VERSION
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StudioStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }

    private fun sample(id: String, name: String = id, user: Boolean = false, created: Double = 0.0) =
        StudioSample(id, name, StudioFolders.fileName(StudioFamily.SAMPLES, id), wasUserFolder = user, createdAt = created, durationMs = 2000)

    private fun loop(id: String, sampleId: String) =
        StudioLoop(id, id, sampleId, fileName = StudioFolders.fileName(StudioFamily.LOOPS, id), lengthMs = 2000)

    private fun ev(on: Int, off: Int, n: Int = 60) = StudioNoteEvent(on, off, n, 90)

    // ---------------- persistence ----------------

    @Test fun crudPerFamilyRoundTripsAcrossReload() {
        val s = env.store()
        s.addSample(sample("smp_a", "Kick"))
        s.addLoop(loop("lp_a", "smp_a"))
        s.addPattern(StudioPattern.of("ptn_a", "Beat", rows = listOf(StudioPatternRow.of("smp_a", steps = List(16) { it == 0 }))))
        s.addTake(StudioTake("tk_a", "Riff", fileName = "take-tk_a.m4a", events = listOf(ev(0, 100))))
        s.setCue("sng_1", 2, 5000, "Drop")
        s.setSlice("smp_a", 1, 700)
        s.createFolder(StudioFolderKind.SAMPLE, "Drums")
        s.setCamelot("8A", "smp_a")
        s.createArrangement("Song")

        val r = env.store()   // fresh instance reads the same file
        assertEquals("Kick", r.sample("smp_a")?.name)
        assertEquals("lp_a", r.loop("lp_a")?.id)
        assertEquals(16, r.pattern("ptn_a")?.rows?.single()?.steps?.size)
        assertEquals(listOf(0), r.take("tk_a")?.events?.map { it.onMs })
        assertEquals(5000, r.cue("sng_1", 2)?.positionMs)
        assertEquals(700, r.slice("smp_a", 1)?.startMs)
        assertEquals(listOf("Drums"), r.foldersOrdered(StudioFolderKind.SAMPLE).map { it.name })
        assertEquals("8A", r.camelot("smp_a"))
        assertEquals(listOf("Song"), r.arrangements.map { it.name })
        assertEquals(1, StudioDocument.decode(env.docFile.readText())!!.schemaVersion)
    }

    @Test fun addIsUpsertByIdAndOnSampleAddedFiresOnlyForNew() {
        val s = env.store()
        var fired = 0
        s.onSampleAdded = { fired++ }
        s.addSample(sample("smp_a", "one"))
        s.addSample(sample("smp_a", "two"))        // crash-retry re-file
        s.addLoop(loop("lp_a", "smp_a")); s.addLoop(loop("lp_a", "smp_a").copy(name = "renamed"))
        s.addTake(StudioTake("tk_a", "a", fileName = "f")); s.addTake(StudioTake("tk_a", "b", fileName = "f"))
        assertEquals(1, s.samples.size)
        assertEquals("two", s.sample("smp_a")?.name)
        assertEquals(1, s.loops.size)
        assertEquals(1, s.takes.size)
        assertEquals(1, fired)
    }

    @Test fun corruptDocumentIsQuarantinedNotSilentlyLost() {
        env.docFile.writeText("{ this is not json")
        val s = env.store()
        assertTrue(s.samples.isEmpty())
        assertEquals("{ this is not json", File(env.docFile.parentFile, "pocketdj-studio.json.bak").readText())
    }

    @Test fun versionMonotonicWriterDropsStaleStragglers() {
        val q = QueueExecutor()
        val s = env.store(executor = q)
        s.addSample(sample("smp_1", "v1"))
        s.renameSample("smp_1", "v2")
        s.renameSample("smp_1", "v3")
        q.runReversed()   // the OLDEST write is applied last by the executor
        val onDisk = StudioDocument.decode(env.docFile.readText())!!
        assertEquals("v3", onDisk.samples.single().name)
    }

    @Test fun flushIsSynchronousAndSupersedesQueuedWrites() {
        val q = QueueExecutor()
        val s = env.store(executor = q)
        s.addSample(sample("smp_1", "queued"))
        assertFalse(env.docFile.exists())          // nothing has run yet
        s.flush()
        assertEquals("queued", StudioDocument.decode(env.docFile.readText())!!.samples.single().name)
        q.runAll()                                  // stragglers must not clobber / re-write older bytes
        assertEquals("queued", StudioDocument.decode(env.docFile.readText())!!.samples.single().name)
        assertFalse(File(env.docFile.parentFile, "pocketdj-studio.json.tmp").exists())   // atomic temp renamed away
    }

    @Test fun slidersAreDebouncedAndFlushPersistsThePendingEdit() {
        val sch = ManualScheduler()
        val s = env.store(scheduler = sch)
        s.addSample(sample("smp_1"))
        val before = env.docFile.readText()
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -6.0))
        assertEquals(before, env.docFile.readText())        // streamed edit not on disk yet
        assertNotNull(sch.pending)
        s.flush()
        assertEquals(-6.0, StudioDocument.decode(env.docFile.readText())!!.samples.single().edit.gainDb, 0.0)
        assertNull(sch.pending)                              // flush cancelled the debounce
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -9.0))
        sch.fire()
        assertEquals(-9.0, StudioDocument.decode(env.docFile.readText())!!.samples.single().edit.gainDb, 0.0)
    }

    // ---------------- samples ----------------

    @Test fun renderRevisionBumpsOnlyOnARealClampedEditChange() {
        val s = env.store()
        s.addSample(sample("smp_1"))
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -3.0))
        assertEquals(1, s.sample("smp_1")!!.renderRevision)
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -3.0))          // identical
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -3.0, rate = 99.0))
        assertEquals(2, s.sample("smp_1")!!.renderRevision)
        assertEquals(10.0, s.sample("smp_1")!!.edit.rate, 0.0)               // clamped
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = -3.0, rate = 10.0))   // clamps to the same value
        assertEquals(2, s.sample("smp_1")!!.renderRevision)
        // Render cache: fresh only while revisions match; a grid change does not stale it.
        s.setRenderedSample("smp_1", "sample-smp_1-r2.m4a", false, 2)
        assertTrue(s.sample("smp_1")!!.isRenderFresh)
        s.setSampleGrid("smp_1", StudioGrid(128.0))
        assertTrue(s.sample("smp_1")!!.isRenderFresh)
        s.updateSampleEdit("smp_1", StudioSampleEdit(gainDb = 1.0))
        assertFalse(s.sample("smp_1")!!.isRenderFresh)
    }

    @Test fun renameTrimsAndRefusesBlank() {
        val s = env.store()
        s.addSample(sample("smp_1", "old"))
        s.renameSample("smp_1", "  new  ")
        assertEquals("new", s.sample("smp_1")!!.name)
        s.renameSample("smp_1", "   ")
        assertEquals("new", s.sample("smp_1")!!.name)
    }

    @Test fun deleteSampleReportsReferrersAndLoopsAndRowsSurvive() {
        val s = env.store()
        val sampleName = env.write(StudioFamily.SAMPLES, "smp_a")
        val rendered = StudioFolders.renderedSampleFileName("smp_a", 1)
        env.appFile(StudioFamily.SAMPLES, rendered).writeText("x")
        s.addSample(sample("smp_a").copy(renderedFileName = rendered, renderedRevision = 1, renderRevision = 1))
        s.setSlice("smp_a", 0, 0)
        s.addLoop(loop("lp_1", "smp_a")); s.addLoop(loop("lp_2", "smp_a"))
        s.addPattern(StudioPattern.of("ptn_1", "P", rows = listOf(StudioPatternRow.of("smp_a"), StudioPatternRow.of("lp_1"), StudioPatternRow.of("smp_a"))))
        s.addPattern(StudioPattern.of("ptn_2", "Q", rows = listOf(StudioPatternRow.of("smp_a"))))

        assertEquals(StudioReferrers(loopCount = 2, patternRowCount = 3), s.referrers("smp_a"))
        assertEquals(StudioReferrers(0, 1), s.referrers("lp_1"))

        assertTrue(s.deleteSample("smp_a"))
        assertFalse(env.appFile(StudioFamily.SAMPLES, sampleName).exists())
        assertFalse(env.appFile(StudioFamily.SAMPLES, rendered).exists())      // render cache goes too
        assertNull(s.sample("smp_a"))
        assertTrue(s.slices("smp_a").isEmpty())                                 // pads are markers on it
        assertEquals(2, s.loops.size)                                           // loops survive parent deletion
        assertFalse(s.sampleExists("smp_a"))
        assertEquals(3, s.pattern("ptn_1")!!.rows.size)                         // rows stay as muted "missing" rows
        assertFalse(s.targetExists("smp_a"))
        assertTrue(s.targetExists("lp_1"))
        assertFalse(s.deleteSample("smp_a"))                                    // already gone
    }

    @Test fun deleteRefusedWhenUserRootUnreachableThenSucceedsWhenBack() {
        env.configured += StudioFamily.SAMPLES
        val s = env.store()
        val n = env.write(StudioFamily.SAMPLES, "smp_u", user = true)
        s.addSample(sample("smp_u", user = true))
        env.unreachable += StudioFamily.SAMPLES
        assertFalse(s.deleteSample("smp_u"))                                    // would orphan the file
        assertNotNull(s.sample("smp_u"))
        assertTrue(env.userFile(StudioFamily.SAMPLES, n).exists())
        env.unreachable -= StudioFamily.SAMPLES
        assertTrue(s.deleteSample("smp_u"))
        assertFalse(env.userFile(StudioFamily.SAMPLES, n).exists())
    }

    @Test fun deleteLoopAndPatternRespectReachability() {
        env.configured += setOf(StudioFamily.LOOPS, StudioFamily.SEQUENCES)
        val s = env.store()
        env.write(StudioFamily.LOOPS, "lp_u", user = true)
        s.addLoop(loop("lp_u", "smp_x").copy(wasUserFolder = true))
        s.addPattern(StudioPattern.of("ptn_u", "P", fileName = StudioFolders.fileName(StudioFamily.SEQUENCES, "ptn_u"), wasUserFolder = true, bounceDirty = false))
        env.unreachable += setOf(StudioFamily.LOOPS, StudioFamily.SEQUENCES)
        assertFalse(s.deleteLoop("lp_u"))
        assertFalse(s.deletePattern("ptn_u"))
        env.unreachable.clear()
        assertTrue(s.deleteLoop("lp_u"))
        assertTrue(s.deletePattern("ptn_u"))
        // A never-bounced pattern has no file and deletes freely.
        s.addPattern(StudioPattern.of("ptn_n", "N"))
        assertTrue(s.deletePattern("ptn_n"))
    }

    // ---------------- folders ----------------

    @Test fun folderCrudRehomesMembersAndDanglingReadsAsUnfiledForEveryKind() {
        val s = env.store()
        s.addSample(sample("smp_1", created = 1.0)); s.addSample(sample("smp_2", created = 2.0))
        s.addLoop(loop("lp_1", "smp_1")); s.addPattern(StudioPattern.of("ptn_1", "P")); s.addTake(StudioTake("tk_1", "T", fileName = "f"))
        val a = s.createArrangement("A")

        val items = mapOf(
            StudioFolderKind.SAMPLE to "smp_1", StudioFolderKind.LOOP to "lp_1", StudioFolderKind.PATTERN to "ptn_1",
            StudioFolderKind.TAKE to "tk_1", StudioFolderKind.ARRANGEMENT to a.id,
        )
        val prefixes = mapOf(
            StudioFolderKind.SAMPLE to "sfld_", StudioFolderKind.LOOP to "lpfld_", StudioFolderKind.PATTERN to "ptnfld_",
            StudioFolderKind.TAKE to "tkfld_", StudioFolderKind.ARRANGEMENT to "arrfld_",
        )
        fun members(k: StudioFolderKind, f: String?): List<String> = when (k) {
            StudioFolderKind.SAMPLE -> s.samples(f).map { it.id }
            StudioFolderKind.LOOP -> s.loops(f).map { it.id }
            StudioFolderKind.PATTERN -> s.patterns(f).map { it.id }
            StudioFolderKind.TAKE -> s.takes(f).map { it.id }
            StudioFolderKind.ARRANGEMENT -> s.arrangements(f).map { it.id }
        }
        for ((kind, itemId) in items) {
            val f = s.createFolder(kind, "  Crate  ")
            assertTrue(kind.name, f.id.startsWith(prefixes[kind]!!))
            assertEquals("Crate", f.name)
            s.renameFolder(kind, f.id, "Crate B")
            s.renameFolder(kind, f.id, "  ")
            assertEquals("Crate B", s.folder(kind, f.id)!!.name)
            s.setItemFolder(kind, itemId, f.id)
            assertTrue(kind.name, itemId in members(kind, f.id))
            assertFalse(kind.name, itemId in members(kind, null))
            s.deleteFolder(kind, f.id)                                           // re-homes, never deletes
            assertNull(s.folder(kind, f.id))
            assertTrue(kind.name, itemId in members(kind, null))
            // A dangling id (folder gone) reads as Unfiled and is never a failure.
            s.setItemFolder(kind, itemId, "gone_folder")
            assertTrue(kind.name, itemId in members(kind, null))
        }
        assertEquals(2, s.samples(null).size)
        assertEquals(listOf("smp_2", "smp_1"), s.samples(null).map { it.id })    // newest first
    }

    @Test fun foldersAreNameSortedCaseInsensitively() {
        val s = env.store()
        listOf("beta", "Alpha", "gamma").forEach { s.createFolder(StudioFolderKind.LOOP, it) }
        assertEquals(listOf("Alpha", "beta", "gamma"), s.foldersOrdered(StudioFolderKind.LOOP).map { it.name })
        s.addSample(sample("smp_b", "zed")); s.addSample(sample("smp_a", "Ant"))
        assertEquals(listOf("Ant", "zed"), s.samplesByName.map { it.name })
    }

    // ---------------- patterns ----------------

    @Test fun patternEditsDirtyTheBounceAndRespectStepGuards() {
        val s = env.store()
        s.addPattern(StudioPattern.of("ptn_1", "P", stepCount = 32, rows = listOf(StudioPatternRow.of("smp_a").resized(32)), fileName = "pattern-ptn_1.m4a", bounceDirty = false))
        s.setPatternStep("ptn_1", 0, 31, true)                      // beyond 16: never truncated
        var p = s.pattern("ptn_1")!!
        assertTrue(p.rows[0].steps[31]); assertTrue(p.bounceDirty)
        s.setPatternBounced("ptn_1", "pattern-ptn_1.m4a", false)
        assertFalse(s.pattern("ptn_1")!!.bounceDirty)
        s.setPatternStep("ptn_1", 0, 32, true)                      // out of range => ignored, stays clean
        assertFalse(s.pattern("ptn_1")!!.bounceDirty)
        s.setPatternStepLoop("ptn_1", 0, 31, true)
        s.setPatternStepSpan("ptn_1", 0, 31, 999)
        p = s.pattern("ptn_1")!!
        assertTrue(p.rows[0].loopSteps[31]); assertEquals(32, p.rows[0].stepSpans[31])   // span clamped to stepCount
        s.setPatternStep("ptn_1", 0, 31, false)                      // cleared step sheds its modes
        p = s.pattern("ptn_1")!!
        assertFalse(p.rows[0].loopSteps[31]); assertEquals(0, p.rows[0].stepSpans[31])
        assertFalse(p.hasSoundingSteps)
    }

    @Test fun patternStepCountRowsLabelsGainAndTargets() {
        val s = env.store()
        s.addPattern(StudioPattern.of("ptn_1", "P"))
        s.addPatternRow("ptn_1", "smp_a")
        s.setPatternStepCount("ptn_1", 48)
        s.addPatternRow("ptn_1", "lp_b")                            // new row is sized to the long pattern
        var p = s.pattern("ptn_1")!!
        assertEquals(48, p.stepCount)
        assertTrue(p.rows.all { it.steps.size == 48 && it.loopSteps.size == 48 && it.stepSpans.size == 48 })
        s.setPatternStepCount("ptn_1", 0)                            // clamps to 1
        assertEquals(1, s.pattern("ptn_1")!!.stepCount)
        s.setPatternStepCount("ptn_1", 16)
        s.setPatternRowLabel("ptn_1", 0, "  Kick ")
        s.setPatternRowTarget("ptn_1", 0, "")                        // empty target refused
        s.setPatternRowTarget("ptn_1", 1, "smp_z")
        s.setPatternRowGain("ptn_1", 0, -4.5)
        s.setPatternBpm("ptn_1", -10.0)                               // refused
        s.setPatternBpm("ptn_1", 140.0)
        p = s.pattern("ptn_1")!!
        assertEquals("Kick", p.rows[0].label)
        assertEquals("smp_a", p.rows[0].targetId); assertEquals("smp_z", p.rows[1].targetId)
        assertEquals(-4.5, p.rows[0].gainDb, 0.0)
        assertEquals(140.0, p.bpm, 0.0)
        s.setPatternRowLabel("ptn_1", 0, " ")
        assertNull(s.pattern("ptn_1")!!.rows[0].label)
        s.removePatternRow("ptn_1", 5)                                // out of range => no-op
        s.removePatternRow("ptn_1", 0)
        assertEquals(listOf("smp_z"), s.pattern("ptn_1")!!.rows.map { it.targetId })
    }

    // ---------------- takes ----------------

    @Test fun takeScoreEditsInvalidateTheRenderAndBumpTheRevision() {
        val s = env.store()
        val rf = StudioFolders.renderedTakeFileName("tk_1", 0)
        env.appFile(StudioFamily.TAKES, rf).writeText("pcm")
        s.addTake(StudioTake("tk_1", "T", fileName = "take-tk_1.m4a", durationMs = 1000, events = listOf(ev(0, 500)), renderedFileName = rf, renderedRevision = 0))
        assertTrue(s.take("tk_1")!!.isRenderFresh)

        s.setTakeEvents("tk_1", listOf(ev(0, 4000)))
        var t = s.take("tk_1")!!
        assertEquals(4000, t.durationMs)                              // extended to the edited tail
        assertEquals(1, t.renderRevision); assertNull(t.renderedFileName)
        assertFalse(env.appFile(StudioFamily.TAKES, rf).exists())     // stale cache file deleted
        s.revertTakeEdits("tk_1")
        assertNull(s.take("tk_1")!!.editedEvents); assertEquals(2, s.take("tk_1")!!.renderRevision)
        s.revertTakeEdits("tk_1")                                      // nothing to revert => no bump
        assertEquals(2, s.take("tk_1")!!.renderRevision)
        s.setTakeInstrument("tk_1", InstrumentKey.PIANO)               // same instrument => no bump
        assertEquals(2, s.take("tk_1")!!.renderRevision)
        s.setTakeInstrument("tk_1", InstrumentKey.TRUMPET)
        assertEquals(3, s.take("tk_1")!!.renderRevision)
        s.setTakeDemuxMode("tk_1", "melody")
        assertEquals("melody", s.take("tk_1")!!.demuxMode)
    }

    @Test fun staleTakeRenderIsDroppedAndItsFileDeleted() {
        val s = env.store()
        s.addTake(StudioTake("tk_1", "T", fileName = "take-tk_1.m4a"))
        val rev = s.take("tk_1")!!.renderRevision
        s.setTakeInstrument("tk_1", InstrumentKey.HARP)                // edit lands mid-render
        val rf = StudioFolders.renderedTakeFileName("tk_1", rev)
        env.appFile(StudioFamily.TAKES, rf).writeText("stale")
        assertFalse(s.setTakeRendered("tk_1", rf, false, rev))
        assertFalse(env.appFile(StudioFamily.TAKES, rf).exists())
        assertNull(s.take("tk_1")!!.renderedFileName)
        val cur = s.take("tk_1")!!.renderRevision
        val rf2 = StudioFolders.renderedTakeFileName("tk_1", cur)
        env.appFile(StudioFamily.TAKES, rf2).writeText("fresh")
        assertTrue(s.setTakeRendered("tk_1", rf2, false, cur))
        assertTrue(s.take("tk_1")!!.isRenderFresh)
    }

    @Test fun takeTempoRescalesEveryStaffAndTheDuration() {
        val s = env.store()
        s.addTake(StudioTake("tk_1", "T", fileName = "f", bpm = 100.0, durationMs = 1000, events = listOf(ev(100, 200)), editedEvents = listOf(ev(300, 400))))
        val sid = s.addOverdubStaff("tk_1", InstrumentKey.VIOLIN, listOf(ev(500, 600)))!!
        s.setTakeTempo("tk_1", 200.0)                                  // twice as fast => half the ms
        val t = s.take("tk_1")!!
        assertEquals(200.0, t.bpm, 0.0)
        assertEquals(50, t.events[0].onMs); assertEquals(100, t.events[0].offMs)
        assertEquals(150, t.editedEvents!![0].onMs)
        assertEquals(250, t.extraStaffs!!.single { it.id == sid }.events[0].onMs)
        assertEquals(500, t.durationMs)
        s.setTakeTempo("tk_1", 200.0)                                  // no change => no-op
        assertEquals(500, s.take("tk_1")!!.durationMs)
        s.setTakeTempo("tk_1", 5000.0)                                 // clamps at 300
        assertEquals(300.0, s.take("tk_1")!!.bpm, 0.0)
    }

    @Test fun overdubStaffCapAndEditing() {
        val s = env.store()
        s.addTake(StudioTake("tk_1", "T", fileName = "f"))
        assertNull(s.addOverdubStaff("tk_1", InstrumentKey.PIANO, emptyList()))    // empty refused
        assertNull(s.addOverdubStaff("nope", InstrumentKey.PIANO, listOf(ev(0, 1))))
        val ids = (1..3).map { s.addOverdubStaff("tk_1", InstrumentKey.CLARINET, listOf(ev(0, 100 * it)))!! }
        assertEquals(4, s.take("tk_1")!!.staffCount)
        assertNull(s.addOverdubStaff("tk_1", InstrumentKey.PIANO, listOf(ev(0, 1))))   // 1 primary + 3 overdubs max
        assertEquals(300, s.take("tk_1")!!.durationMs)
        s.setStaffEvents("tk_1", ids[0], listOf(StudioNoteEvent(0, 900, 61, 80, Accidental.FLAT)))
        assertEquals(900, s.take("tk_1")!!.durationMs)
        s.setStaffInstrument("tk_1", ids[1], InstrumentKey.HARP)
        s.revertStaffEdits("tk_1", ids[0])
        assertNull(s.take("tk_1")!!.extraStaffs!![0].editedEvents)
        ids.forEach { s.deleteStaff("tk_1", it) }
        assertNull(s.take("tk_1")!!.extraStaffs)                        // empty list collapses to nil
        assertEquals(1, s.take("tk_1")!!.staffCount)
    }

    @Test fun deleteTakeRemovesRawAndRenderedFiles() {
        val s = env.store()
        val raw = env.write(StudioFamily.TAKES, "tk_1")
        val rf = StudioFolders.renderedTakeFileName("tk_1", 0)
        env.appFile(StudioFamily.TAKES, rf).writeText("r")
        s.addTake(StudioTake("tk_1", "T", fileName = raw, renderedFileName = rf))
        assertTrue(s.deleteTake("tk_1"))
        assertFalse(env.appFile(StudioFamily.TAKES, raw).exists()); assertFalse(env.appFile(StudioFamily.TAKES, rf).exists())
        assertFalse(s.deleteTake("tk_1"))
    }

    @Test fun addTakeRelocatingMovesToAReachableWritableUserFolderElseKeepsAppStorage() {
        val s = env.store()
        val n = env.write(StudioFamily.TAKES, "tk_a")
        val kept = s.addTakeRelocating(StudioTake("tk_a", "A", fileName = n))
        assertFalse(kept.wasUserFolder)
        assertTrue(env.appFile(StudioFamily.TAKES, n).exists())

        env.configured += StudioFamily.TAKES
        val n2 = env.write(StudioFamily.TAKES, "tk_b")
        val moved = s.addTakeRelocating(StudioTake("tk_b", "B", fileName = n2))
        assertTrue(moved.wasUserFolder)
        assertFalse(env.appFile(StudioFamily.TAKES, n2).exists())
        assertTrue(env.userFile(StudioFamily.TAKES, n2).exists())
        assertNotNull(s.localUrlForPlayback("tk_b"))
    }

    // ---------------- cues ----------------

    @Test fun cueCapEightSlotsReplaceAndValidation() {
        val s = env.store()
        assertNull(s.setCue("", 0, 10)); assertNull(s.setCue("sng_1", -1, 10)); assertNull(s.setCue("sng_1", 8, 10))
        (0..7).forEach { assertNotNull(s.setCue("sng_1", it, it * 1000)) }
        assertEquals(8, s.cues("sng_1").size)
        val firstId = s.cue("sng_1", 3)!!.id
        val replaced = s.setCue("sng_1", 3, 99, "Hook")!!
        assertEquals(firstId, replaced.id)                              // same slot => same cue, moved
        assertEquals(8, s.cues("sng_1").size)                           // never a ninth
        assertEquals(99, s.cue("sng_1", 3)!!.positionMs); assertEquals("Hook", s.cue("sng_1", 3)!!.name)
        s.setCue("sng_1", 3, 120)                                       // null name leaves the old name
        assertEquals("Hook", s.cue("sng_1", 3)!!.name)
        s.setCue("sng_2", 0, -50)                                       // negative clamps to 0
        assertEquals(0, s.cue("sng_2", 0)!!.positionMs)
        assertEquals((0..7).toList(), s.cues("sng_1").map { it.slot })  // slot-ordered
        s.renameCue("sng_1", 3, "  "); assertNull(s.cue("sng_1", 3)!!.name)
        s.removeCue("sng_1", 3); assertNull(s.cue("sng_1", 3))
        s.removeCue("sng_1", 3)                                         // idempotent
        assertEquals(7, s.cues("sng_1").size)
    }

    @Test fun cueMirrorIsWrittenOnCueChangesAndNotOnOtherSaves() {
        val s = env.store()
        val mirror = s.cueSyncFile
        assertEquals("pocketdj-studio.cues.json", mirror.name)
        s.addSample(sample("smp_1"))                                    // a non-cue save
        assertFalse(mirror.exists())
        s.setCue("sng_1", 0, 1500, "A")
        val doc = StudioCueDoc.decode(mirror.readText())!!
        assertEquals(listOf(1500), doc.cues.map { it.positionMs })
        assertEquals(1, doc.schemaVersion)
        val stamp = mirror.readText()
        s.renameSample("smp_1", "x")                                    // non-cue save leaves the mirror alone
        assertEquals(stamp, mirror.readText())
    }

    @Test fun nudgeIsDebouncedAndFlushPersistsAPendingMirror() {
        val sch = ManualScheduler()
        val s = env.store(scheduler = sch)
        s.setCue("sng_1", 0, 1000)
        s.nudgeCue("sng_1", 0, 250)
        assertEquals(1250, s.cue("sng_1", 0)!!.positionMs)
        assertEquals(1000, StudioCueDoc.decode(s.cueSyncFile.readText())!!.cues.single().positionMs)   // mirror not yet
        s.flush()
        assertEquals(1250, StudioCueDoc.decode(s.cueSyncFile.readText())!!.cues.single().positionMs)
        assertEquals(1250, StudioDocument.decode(env.docFile.readText())!!.cues.single().positionMs)
        s.nudgeCue("sng_1", 0, -5000)
        assertEquals(0, s.cue("sng_1", 0)!!.positionMs)                  // floors at 0
        sch.fire()
        assertEquals(0, StudioCueDoc.decode(s.cueSyncFile.readText())!!.cues.single().positionMs)
    }

    @Test fun reloadCuesAdoptsThePulledMirrorDurablyWithoutRewritingIt() {
        val s = env.store()
        s.setCue("sng_1", 0, 1)
        val pulled = StudioCueDoc(cues = listOf(com.levi.pocketdj.studio.model.StudioCue("cue_remote", "sng_9", 4, 777)))
        s.cueSyncFile.writeText(pulled.encode())
        val written = s.cueSyncFile.readText()
        assertTrue(s.reloadCuesFromDisk())
        assertEquals(listOf("cue_remote"), s.cues.map { it.id })
        assertEquals(written, s.cueSyncFile.readText())                  // no push-back loop
        // Durable in the studio doc even with no flush() (hard-kill safety).
        assertEquals(listOf("cue_remote"), StudioDocument.decode(env.docFile.readText())!!.cues.map { it.id })
        s.cueSyncFile.writeText("garbage")
        assertFalse(s.reloadCuesFromDisk())                              // corrupt pull is ignored
        assertEquals(1, s.cues.size)
    }

    @Test fun pullInvalidatesAQueuedCueMirrorWrite() {
        val ex = QueueExecutor()
        val s = env.store(executor = ex)
        s.setCue("sng_1", 0, 1)                                          // queues a v-N mirror write
        val pulled = StudioCueDoc(cues = listOf(com.levi.pocketdj.studio.model.StudioCue("cue_remote", "sng_9", 4, 777)))
        s.cueSyncFile.writeText(pulled.encode())
        val written = s.cueSyncFile.readText()
        assertTrue(s.reloadCuesFromDisk())
        ex.runAll()                                                      // the stale queued write runs late
        assertEquals(written, s.cueSyncFile.readText())                  // ...and must NOT clobber the pulled mirror
    }

    @Test fun saveStampsCurrentSchemaVersion() {
        val s = env.store()
        s.addSample(StudioSample("smp_v", "v", "sample-smp_v.m4a"))
        s.flush()
        assertEquals(STUDIO_SCHEMA_VERSION, StudioDocument.decode(env.docFile.readText())!!.schemaVersion)
    }

    @Test fun clearCuesWipesDocAndMirror() {
        val s = env.store()
        s.setCue("sng_1", 0, 1)
        assertTrue(s.cueSyncFile.exists())
        s.clearCues()
        assertTrue(s.cues.isEmpty()); assertFalse(s.cueSyncFile.exists())
        assertTrue(StudioDocument.decode(env.docFile.readText())!!.cues.isEmpty())
    }

    // ---------------- slices ----------------

    @Test fun sliceSlotsCapWindowsAndBulkChop() {
        val s = env.store()
        s.addSample(sample("smp_1"))                                    // durationMs 2000
        assertNull(s.setSlice("smp_1", 8, 0)); assertNull(s.setSlice("", 0, 0))
        s.setSlice("smp_1", 0, 0); s.setSlice("smp_1", 2, 1200); s.setSlice("smp_1", 1, 600)   // out of time order is fine
        assertEquals(0 to 600, s.sliceWindow("smp_1", 0))
        assertEquals(600 to 1200, s.sliceWindow("smp_1", 1))
        assertEquals(1200 to 2000, s.sliceWindow("smp_1", 2))            // last pad ends at the RAW end
        assertNull(s.sliceWindow("smp_1", 5))
        s.nudgeSlice("smp_1", 2, 5000)
        assertNull(s.sliceWindow("smp_1", 2))                            // start past the end => no window
        s.setSlices("smp_1", listOf(900, 100, 100, -5) + (1000..1010 step 1))   // dedupe, clamp, sort, cap 8
        val starts = s.slices("smp_1").map { it.startMs }
        assertEquals(8, starts.size); assertEquals(starts.sorted(), starts); assertEquals(0, starts.first())
        assertEquals((0..7).toList(), s.slices("smp_1").map { it.slot })
        s.renameSlice("smp_1", 0, " Kick "); assertEquals("Kick", s.slice("smp_1", 0)!!.name)
        s.removeSlice("smp_1", 0); assertNull(s.slice("smp_1", 0))
        s.clearSlices("smp_1"); assertTrue(s.slices("smp_1").isEmpty())
    }

    // ---------------- playback resolution ----------------

    @Test fun localUrlForPlaybackPrefersFreshRenderElseRawAndGatesPatternsOnTheBounce() {
        val s = env.store()
        val raw = env.write(StudioFamily.SAMPLES, "smp_1")
        val rendered = StudioFolders.renderedSampleFileName("smp_1", 2)
        env.appFile(StudioFamily.SAMPLES, rendered).writeText("r")
        s.addSample(sample("smp_1", "Kick").copy(renderedFileName = rendered, renderedRevision = 2, renderRevision = 2,
            edit = StudioSampleEdit(trimStartMs = 500, trimEndMs = 1500)))
        var p = s.localUrlForPlayback("smp_1")!!
        assertEquals(rendered, p.ref.file!!.name); assertEquals(1000, p.lengthMs); assertEquals("Kick", p.title)
        s.updateSampleEdit("smp_1", StudioSampleEdit(trimStartMs = 500, trimEndMs = 1600))   // stale cache => raw
        assertEquals(raw, s.localUrlForPlayback("smp_1")!!.ref.file!!.name)

        env.write(StudioFamily.LOOPS, "lp_1")
        s.addLoop(loop("lp_1", "smp_gone"))
        assertEquals(2000, s.localUrlForPlayback("lp_1")!!.lengthMs)      // loop plays without its parent

        val pn = env.write(StudioFamily.SEQUENCES, "ptn_1")
        s.addPattern(StudioPattern.of("ptn_1", "P", fileName = pn, bounceDirty = true))
        assertNull(s.localUrlForPlayback("ptn_1"))                         // dirty bounce never plays
        s.setPatternBounced("ptn_1", pn, false)
        assertNotNull(s.localUrlForPlayback("ptn_1"))

        assertNull(s.localUrlForPlayback("smp_missing")); assertNull(s.localUrlForPlayback("sng_1")); assertNull(s.localUrlForPlayback("cue_1"))
        assertNull(s.localUrlForPlayback("tk_nope"))
    }

    @Test fun mixAndDisplayInfo() {
        val s = env.store()
        s.addSample(sample("smp_1", "S").copy(grid = StudioGrid(130.0, 250, listOf(250, 700))))
        s.addLoop(loop("lp_1", "smp_1").copy(bpm = 100.0))
        s.addTake(StudioTake("tk_1", "T", fileName = "f", bpm = 90.0, durationMs = 5000))
        s.setCamelot("9B", "smp_1")
        assertEquals(StudioMixInfo(130.0, 250, listOf(250, 700), "9B"), s.mixInfo("smp_1"))
        assertEquals(100.0, s.mixInfo("lp_1")!!.bpm!!, 0.0)
        assertNull(s.mixInfo("sng_1"))
        assertEquals("Instrumental", s.displayInfo("tk_1")!!.kindLabel)
        assertEquals("Loop", s.displayInfo("lp_1")!!.kindLabel)
        s.setCamelot(null, "smp_1"); assertNull(s.camelot("smp_1"))
    }

    // ---------------- storage manager ----------------

    @Test fun usageBytesCountsOnlyStrictShapesAndKnownIdsInUserRoots() {
        env.configured += StudioFamily.SAMPLES
        val s = env.store()
        env.write(StudioFamily.SAMPLES, "smp_known", bytes = 100)
        env.write(StudioFamily.SAMPLES, "smp_known", user = true, bytes = 40)
        env.write(StudioFamily.SAMPLES, "smp_unknown", user = true, bytes = 1000)        // not in the doc => not ours
        env.userFile(StudioFamily.SAMPLES, "sample-of-my-mix.m4a").writeBytes(ByteArray(500))   // user's own file
        env.appFile(StudioFamily.SAMPLES, "sample-smp_bad.mp3").writeBytes(ByteArray(500))     // wrong extension
        env.appFile(StudioFamily.SAMPLES, "sample-smp_known-r3.m4a").writeBytes(ByteArray(7))  // render cache counts
        s.addSample(sample("smp_known"))
        assertEquals(100L + 40 + 7, s.usageBytes(StudioFamily.SAMPLES))
        env.unreachable += StudioFamily.SAMPLES                                          // unreachable root contributes nothing
        assertEquals(107L, s.usageBytes(StudioFamily.SAMPLES))
    }

    @Test fun strictFileIdShapes() {
        val f = StudioFamily.SAMPLES
        assertEquals("smp_ab12", StudioFolders.fileId(f, "sample-smp_ab12.m4a"))
        assertEquals("smp_ab12", StudioFolders.fileId(f, "sample-smp_ab12-r7.m4a"))
        assertEquals("smp_ab12-rx", StudioFolders.fileId(f, "sample-smp_ab12-rx.m4a"))   // non-digit stamp is NOT stripped (iOS parity); never a known id
        assertNull(StudioFolders.fileId(f, "sample-smp_.m4a"))
        assertNull(StudioFolders.fileId(f, "sample-ab12.m4a"))
        assertNull(StudioFolders.fileId(f, "sample-smp_ab12.wav"))
        assertNull(StudioFolders.fileId(f, "sample-smp_a/b.m4a"))
        assertNull(StudioFolders.fileId(f, "sample-.m4a"))
        assertNull(StudioFolders.fileId(f, "sample.m4a"))
        assertEquals("lp_1", StudioFolders.fileId(StudioFamily.LOOPS, "loop-lp_1.wav"))
        assertEquals("lp_1-r1", StudioFolders.fileId(StudioFamily.LOOPS, "loop-lp_1-r1.wav"))   // only samples/takes strip -r (never a known id)
        assertEquals("tk_9", StudioFolders.fileId(StudioFamily.TAKES, "take-tk_9-r12.m4a"))
        assertEquals("generaluser-gs", StudioFolders.fileId(StudioFamily.INSTRUMENTS, "instrument-generaluser-gs.sf2"))
        assertNull(StudioFolders.fileId(StudioFamily.INSTRUMENTS, "instrument-.sf2"))
        assertEquals("sample-smp_x.m4a", StudioFolders.fileName(f, "smp_x"))
        assertEquals("loop-lp_x.wav", StudioFolders.fileName(StudioFamily.LOOPS, "lp_x"))
    }

    @Test fun deleteAllSkipsActiveTakeKeepsUnreachableRecordsAndNeverTouchesUserFiles() {
        env.configured += StudioFamily.TAKES
        val s = env.store()
        val a = env.write(StudioFamily.TAKES, "tk_active")
        val b = env.write(StudioFamily.TAKES, "tk_old")
        val u = env.write(StudioFamily.TAKES, "tk_user", user = true)
        env.userFile(StudioFamily.TAKES, "take-notes.m4a").writeText("mine")             // coincidental user file
        env.write(StudioFamily.TAKES, "tk_foreign", user = true)                          // right shape, not in the doc
        s.addTake(StudioTake("tk_active", "A", fileName = a)); s.addTake(StudioTake("tk_old", "B", fileName = b))
        s.addTake(StudioTake("tk_user", "U", fileName = u, wasUserFolder = true))
        s.activeTakeFileName = { a }
        s.deleteAll(StudioFamily.TAKES)
        assertEquals(listOf("tk_active"), s.takes.map { it.id })                           // active kept (file survived)
        assertTrue(env.appFile(StudioFamily.TAKES, a).exists()); assertFalse(env.appFile(StudioFamily.TAKES, b).exists())
        assertFalse(env.userFile(StudioFamily.TAKES, u).exists())
        assertTrue(env.userFile(StudioFamily.TAKES, "take-notes.m4a").exists())
        assertTrue(env.userFile(StudioFamily.TAKES, StudioFolders.fileName(StudioFamily.TAKES, "tk_foreign")).exists())

        // Unreachable user root: its records are KEPT (nothing provably deleted).
        s.addTake(StudioTake("tk_away", "Away", fileName = StudioFolders.fileName(StudioFamily.TAKES, "tk_away"), wasUserFolder = true))
        env.unreachable += StudioFamily.TAKES
        s.activeTakeFileName = null
        s.deleteAll(StudioFamily.TAKES)
        assertEquals(listOf("tk_away"), s.takes.map { it.id })
    }

    // ---------------- arrangements ----------------

    @Test fun arrangementTrackClipCrudAndFiles() {
        val s = env.store()
        val arr = s.createArrangement("  Set  ")
        assertEquals("Set", arr.name)
        val t1 = s.addTrack(arr.id)!!; val t2 = s.addTrack(arr.id, "Bass")!!
        assertEquals("Track 1", t1.name); assertEquals("Bass", t2.name)
        s.setTrackPan(arr.id, t1.id, 5.0); s.setTrackColor(arr.id, t1.id, -1); s.setTrackGain(arr.id, t1.id, -3.0)
        s.setTrackMuted(arr.id, t1.id, true)
        var a = s.arrangement(arr.id)!!
        assertEquals(1.0, a.tracks[0].pan, 0.0); assertEquals(7, a.tracks[0].colorIndex); assertTrue(a.tracks[0].muted)

        // BPM seeds from the FIRST clip while untouched, then stays put.
        s.addSample(sample("smp_1").copy(grid = StudioGrid(140.0)))
        val dir = env.roots.arrangementsDir()
        File(dir, "clip-c1.m4a").writeText("audio")
        s.addClip(arr.id, t1.id, StudioClip("clip_c1", "K", "clip-c1.m4a", durationMs = 1000, source = StudioClipSource.SAMPLE, sourceId = "smp_1"))
        assertEquals(140.0, s.arrangement(arr.id)!!.bpm, 0.0)
        s.addSample(sample("smp_2").copy(grid = StudioGrid(90.0)))
        s.addClip(arr.id, t2.id, StudioClip("clip_c2", "K2", "clip-c2.m4a", source = StudioClipSource.SAMPLE, sourceId = "smp_2"))
        assertEquals(140.0, s.arrangement(arr.id)!!.bpm, 0.0)
        s.moveClip(arr.id, t1.id, "clip_c1", -50)
        assertEquals(0, s.arrangement(arr.id)!!.tracks[0].clips[0].startMs)
        assertNotNull(s.clipFile("clip-c1.m4a")); assertNull(s.clipFile("../escape")); assertNull(s.clipFile("nope.m4a"))

        // Duplicate copies clip files and clears solo.
        s.setTrackSoloed(arr.id, t1.id, true)
        val dup = s.duplicateTrack(arr.id, t1.id)!!
        assertEquals("Track 1 copy", dup.name); assertFalse(dup.soloed)
        assertEquals(listOf(t1.id, dup.id, t2.id), s.arrangement(arr.id)!!.tracks.map { it.id })
        assertTrue(File(dir, dup.clips[0].fileName).exists()); assertTrue(dup.clips[0].id != "clip_c1")

        assertTrue(s.removeClip(arr.id, t1.id, "clip_c1")); assertFalse(File(dir, "clip-c1.m4a").exists())
        assertTrue(File(dir, dup.clips[0].fileName).exists())             // the copy is independent
        assertTrue(s.deleteArrangement(arr.id))
        assertFalse(File(dir, dup.clips[0].fileName).exists())            // arrangement delete removes clip audio
        assertNull(s.arrangement(arr.id))
        assertFalse(s.deleteArrangement(arr.id))
    }

    @Test fun arrangementSettersClampAndArtifactsCrud() {
        val s = env.store()
        val a = s.createArrangement("A")
        s.setArrangementBpm(a.id, 9999.0); assertEquals(300.0, s.arrangement(a.id)!!.bpm, 0.0)
        s.setArrangementBpm(a.id, Double.NaN); assertEquals(120.0, s.arrangement(a.id)!!.bpm, 0.0)
        s.setArrangementLoop(a.id, enabled = true, startMs = 5000, endMs = 100)
        assertEquals(5000, s.arrangement(a.id)!!.loopEndMs)               // end never before start
        s.setArrangementBeatMatch(a.id, true); assertTrue(s.arrangement(a.id)!!.beatMatchEnabled)

        val dir = env.roots.arrangementsDir()
        File(dir, "bounce-1.m4a").writeText("b")
        s.addArrangementArtifact(com.levi.pocketdj.studio.model.StudioArrangementArtifact("art_1", a.id, com.levi.pocketdj.studio.model.StudioArrangementArtifact.Kind.BOUNCE, "bounce-1", "bounce-1.m4a", createdAt = 1.0))
        s.addArrangementArtifact(com.levi.pocketdj.studio.model.StudioArrangementArtifact("art_2", a.id, com.levi.pocketdj.studio.model.StudioArrangementArtifact.Kind.RECORDING, "live", "live.m4a", createdAt = 2.0))
        assertEquals(listOf("art_1"), s.artifacts(a.id, com.levi.pocketdj.studio.model.StudioArrangementArtifact.Kind.BOUNCE).map { it.id })
        s.deleteArrangementArtifact("art_1")
        assertFalse(File(dir, "bounce-1.m4a").exists()); assertEquals(1, s.arrangementArtifacts.size)
    }

    @Test fun trimGapAllCases() {
        fun c(id: String, start: Int, dur: Int, fs: Int = 0, file: String = "f") =
            StudioClip(id, id, file, startMs = start, durationMs = dur, fileStartMs = fs)
        var n = 0
        val mint = { "new${n++}" }
        // Disjoint clips are kept whole; an empty/inverted cut is a no-op.
        assertEquals(listOf(c("a", 0, 100), c("b", 500, 100)), StudioStore.trimGap(listOf(c("a", 0, 100), c("b", 500, 100)), 200, 400, mint))
        assertEquals(listOf(c("a", 0, 100)), StudioStore.trimGap(listOf(c("a", 0, 100)), 50, 50, mint))
        // Cut fully inside a clip => head + tail with a NEW tail id and a slid in-file window.
        val mid = StudioStore.trimGap(listOf(c("a", 0, 1000, fs = 10)), 300, 600, mint)
        assertEquals(listOf("a", "new0"), mid.map { it.id })
        assertEquals(300, mid[0].durationMs)
        assertEquals(600, mid[1].startMs); assertEquals(10 + 600, mid[1].fileStartMs); assertEquals(400, mid[1].durationMs)
        // Head-trim only (cut covers the start) => the SOLE survivor keeps its identity.
        val tailOnly = StudioStore.trimGap(listOf(c("a", 100, 900)), 0, 400, mint)
        assertEquals(listOf("a"), tailOnly.map { it.id }); assertEquals(400, tailOnly[0].startMs); assertEquals(300, tailOnly[0].fileStartMs)
        // Tail-trim only.
        val headOnly = StudioStore.trimGap(listOf(c("a", 0, 1000)), 700, 2000, mint)
        assertEquals(1, headOnly.size); assertEquals(700, headOnly[0].durationMs)
        // Fully covered => dropped.
        assertTrue(StudioStore.trimGap(listOf(c("a", 100, 100)), 0, 1000, mint).isEmpty())
    }

    @Test fun commitTrimmedTrackDedupesSharedFilesAndCleansOrphans() {
        val s = env.store()
        val a = s.createArrangement("A"); val t = s.addTrack(a.id)!!
        val dir = env.roots.arrangementsDir()
        File(dir, "clip-x.m4a").writeText("x"); File(dir, "clip-gone.m4a").writeText("g")
        s.addClip(a.id, t.id, StudioClip("clip_x", "X", "clip-x.m4a", durationMs = 1000))
        s.addClip(a.id, t.id, StudioClip("clip_g", "G", "clip-gone.m4a", startMs = 2000, durationMs = 500))
        val trimmed = StudioStore.trimGap(s.arrangement(a.id)!!.tracks[0].clips.filter { it.id == "clip_x" }, 300, 600)
        s.commitTrimmedTrack(a.id, t.id, trimmed)
        val clips = s.arrangement(a.id)!!.tracks[0].clips
        assertEquals(2, clips.size)
        assertTrue(clips[0].fileName != clips[1].fileName)                  // split tail got its own full copy
        clips.forEach { assertTrue(File(dir, it.fileName).exists()) }
        assertFalse(File(dir, "clip-gone.m4a").exists())                     // dropped + unreferenced => deleted
    }

    @Test fun idMintingFenceMatchesTheStore() {
        val s = env.store()
        assertTrue(s.createFolder(StudioFolderKind.SAMPLE, "x").id.startsWith("sfld_"))
        assertFalse(StudioFactory.isStudioId(s.createFolder(StudioFolderKind.SAMPLE, "y").id))
        assertTrue(s.setCue("sng", 0, 0)!!.id.startsWith("cue_"))
    }
}
