package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.burns.BeatGridSidecar
import com.levi.pocketdj.studio.model.StudioGrid
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DemuxAnalysisTest {
    @get:Rule val tmp = TemporaryFolder()
    private val song = DemuxSource.Song("sng_1", "Title", "Artist")

    // ---- grid resolver: keyed by source ----------------------------------------------------------

    @Test fun measuredSidecarWinsAndDrivesBarsAndTheInstrumentalGrid() {
        val sc = BeatGridSidecar(beatGridBpm = 100.0, firstDownbeatMs = 400, beatsMs = listOf(400, 1_000), downbeatsMs = listOf(400, 2_800, 5_200))
        var estimated = 0
        val r = DemuxGridResolver.resolve("sng_1", 8_000, sc) { estimated++; null }!!
        assertTrue(r.measured); assertEquals(0, estimated)
        assertEquals(DemuxInstrumental.Grid(100.0, 400, listOf(400, 1_000)), r.grid)
        assertEquals(400, r.bars[0].startMs); assertEquals(2_800, r.bars[0].endMs)
        assertEquals("sng_1", r.sourceKey)
    }

    @Test fun withoutASidecarTheGridIsEstimatedFromTheAudio() {
        val r = DemuxGridResolver.resolve("dmx_1", 8_000, null) { StudioGrid(120.0, 250) }!!
        assertFalse(r.measured)
        assertEquals(250, r.grid.firstDownbeatMs)
        assertEquals(2_000, r.bars[0].endMs - r.bars[0].startMs)
        assertNull(DemuxGridResolver.resolve("dmx_1", 8_000, null) { null })
        assertNull(DemuxGridResolver.resolve("dmx_1", 8_000, BeatGridSidecar()) { StudioGrid(0.0) })
    }

    @Test fun aResultForAnotherSourceIsNeverApplied() {
        val a = DemuxGridResolver.resolve("sng_A", 8_000, null) { StudioGrid(120.0) }!!
        assertNotNull(a.forSource("sng_A"))
        assertNull(a.forSource("sng_B"))      // the stale cross-source export guard
    }

    @Test fun melodyStemPrefersVocalsThenOther() {
        fun m(vararg n: String) = n.associateWith { File("/$it.mp3") }
        assertEquals("/vocals.mp3", melodyStem(m("vocals", "other", "drums"))!!.path)
        assertEquals("/other.mp3", melodyStem(m("other", "drums"))!!.path)
        assertNull(melodyStem(m("drums", "bass"))); assertNull(melodyStem(null))
    }

    // ---- analyzers ------------------------------------------------------------------------------

    private fun analyzers(store: DemuxStore, drums: (String, String?) -> List<DemuxDrumHit> = { _, _ -> emptyList() }, melody: (String) -> List<DemuxMelodyNote> = { emptyList() }) =
        DemuxAnalyzers(CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), store, Dispatchers.Unconfined, drums, melody)

    @Test fun drumAnalysisPersistsHitsAndStatusAndIsDedupedUntilForced() {
        val store = DemuxStore(tmp.newFolder())
        var runs = 0
        val a = analyzers(store, drums = { _, _ -> runs++; listOf(DemuxDrumHit(10, DemuxDrumKind.KICK, 1.0)) })
        a.analyzeDrums(song, "/d.mp3", "/b.mp3", 4_000)?.let { runBlocking { it.join() } }
        val doc = store.document("sng_1")!!
        assertEquals(DemuxArtifactStatus.DONE, doc.drumStatus); assertEquals(1, doc.drumHits!!.size); assertEquals(4_000, doc.durationMs)
        assertNull(a.analyzeDrums(song, "/d.mp3", null, 4_000))      // DONE -> no-op
        a.analyzeDrums(song, "/d.mp3", null, 4_000, force = true)?.let { runBlocking { it.join() } }
        assertEquals(2, runs)
        assertTrue(a.drumRuns.value.isEmpty())
    }

    @Test fun anEmptyOrThrowingDetectorMarksFailedAndKeepsOtherFields() {
        val store = DemuxStore(tmp.newFolder())
        store.update(song) { it.copy(chords = listOf(DemuxChordSegment(0, false, 0, 1000, 0.9)), chordStatus = DemuxArtifactStatus.DONE) }
        val a = analyzers(store, drums = { _, _ -> throw IllegalStateException("boom") })
        a.analyzeDrums(song, "/d.mp3", null, 1_000)?.let { runBlocking { it.join() } }
        val doc = store.document("sng_1")!!
        assertEquals(DemuxArtifactStatus.FAILED, doc.drumStatus)
        assertEquals(1, doc.chords.size)                              // a concurrent chord result is never clobbered
        assertTrue(a.drumRuns.value.isEmpty())
    }

    @Test fun melodyIsTrackedOnceAndCachedOnTheDocument() {
        val store = DemuxStore(tmp.newFolder())
        var runs = 0
        val a = analyzers(store, melody = { runs++; listOf(DemuxMelodyNote(60, 0, 400)) })
        a.analyzeMelody(song, "/v.mp3")?.let { runBlocking { it.join() } }
        assertEquals(DemuxArtifactStatus.DONE, store.document("sng_1")!!.melodyStatus)
        assertNull(a.analyzeMelody(song, "/v.mp3"))
        assertEquals(1, runs)
        a.cacheMelody("sng_1", listOf(DemuxMelodyNote(62, 0, 400)))
        assertEquals(62, store.document("sng_1")!!.melodyNotes!!.single().midi)
        a.cacheMelody("never-seen", emptyList())                      // unknown key: no document is invented
        assertNull(store.document("never-seen"))
    }

    @Test fun concurrentRunsForTheSameKeyAreRejected() {
        val store = DemuxStore(tmp.newFolder())
        val gate = CompletableDeferred<Unit>()
        val a = DemuxAnalyzers(CoroutineScope(SupervisorJob() + Dispatchers.Default), store, Dispatchers.Default,
            { _, _ -> runBlocking { gate.await() }; listOf(DemuxDrumHit(1, DemuxDrumKind.KICK, 1.0)) })
        val first = a.analyzeDrums(song, "/d", null, 1_000)
        assertNotNull(first)
        assertTrue(song.key in a.drumRuns.value)
        assertNull(a.analyzeDrums(song, "/d", null, 1_000, force = true))
        gate.complete(Unit)
        runBlocking { first!!.join() }
        assertTrue(a.drumRuns.value.isEmpty())
    }

    // ---- cloud lyrics ---------------------------------------------------------------------------

    @Test fun cloudLyricsLandWholesaleAndAreFetchedOnce() {
        val store = DemuxStore(tmp.newFolder())
        val a = analyzers(store)
        var downloads = 0
        val body = """{"model":"w","words":[{"text":"hi","startMs":0,"endMs":100}]}"""
        assertTrue(runBlocking { a.fetchCloudLyrics(song, false) { downloads++; body } })
        assertTrue(runBlocking { a.fetchCloudLyrics(song, false) { downloads++; body } })   // deduped
        assertEquals(1, downloads)
        assertTrue(runBlocking { a.fetchCloudLyrics(song, true) { downloads++; body } })    // Refresh forces
        assertEquals(2, downloads)
        assertEquals("cloud", store.document("sng_1")!!.transcriptEngine)
        assertTrue(a.lyricsFetching.value.isEmpty())
    }

    @Test fun aFailedOrCorruptFetchLeavesTheDocumentUntouchedSoItRetries() {
        val store = DemuxStore(tmp.newFolder())
        val a = analyzers(store)
        assertFalse(runBlocking { a.fetchCloudLyrics(song, false) { null } })
        assertFalse(runBlocking { a.fetchCloudLyrics(song, false) { "<html>oops</html>" } })
        assertNull(store.document("sng_1")?.transcriptEngine)
        assertEquals(DemuxArtifactStatus.NONE, store.documentCreating(song).transcriptStatus)
        assertTrue(a.lyricsFetching.value.isEmpty())
        assertTrue(runBlocking { a.fetchCloudLyrics(song, false) { """{"words":[]}""" } })  // next open succeeds -> instrumental
        assertEquals(DemuxArtifactStatus.DONE, store.document("sng_1")!!.transcriptStatus)
    }
}
