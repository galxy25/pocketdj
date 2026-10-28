package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DemuxStoreTest {
    private lateinit var dir: File
    private val scope = CoroutineScope(Dispatchers.Unconfined)

    @Before fun setUp() { dir = Files.createTempDirectory("demux-test").toFile() }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun store(
        fetch: suspend (String, File) -> Boolean = { _, dest -> dest.parentFile?.mkdirs(); dest.writeText("x"); true },
        detect: (String) -> List<DemuxChordSegment> = { emptyList() },
    ) = DemuxStore(dir, fetch = fetch, detectChords = detect)

    // iOS (Swift JSONEncoder) shape: optional drum/melody/transcript keys ABSENT in a pre-existing cache doc.
    private val iosDoc = """
        {"schemaVersion":1,"sourceKey":"sng_42","displayName":"Artist — Title","durationMs":183000,
         "transcriptStatus":"none","words":[],"chordStatus":"done",
         "chords":[{"rootPC":0,"minor":false,"startMs":0,"endMs":2000,"confidence":0.91},
                   {"rootPC":9,"minor":true,"startMs":2000,"endMs":4500,"confidence":0.72}]}
    """.trimIndent()

    @Test fun decodesAnIosCachedDocWithoutOptionalFields() {
        val doc = PdjJson.lenient.decodeFromString<DemuxDocument>(iosDoc)
        assertEquals("sng_42", doc.sourceKey)
        assertEquals(DemuxArtifactStatus.DONE, doc.chordStatus)
        assertEquals(listOf("C", "Am"), doc.chords.map { it.name })
        assertNull(doc.drumStatus); assertNull(doc.drumHits); assertNull(doc.melodyNotes); assertNull(doc.transcriptCoveredMs); assertNull(doc.importedFileName)
    }

    @Test fun decodesDocWithDrumMelodyAndTranscriptFields() {
        val full = """
            {"schemaVersion":1,"sourceKey":"dmx_a1","displayName":"Riff","durationMs":5000,
             "transcriptStatus":"running","words":[{"text":"hey","startMs":10,"endMs":400}],"transcriptCoveredMs":2000,
             "transcriptDiag":"1 of 3 sections","transcriptEngine":"cloud","chordStatus":"failed","chords":[],
             "drumStatus":"done","drumHits":[{"ms":120,"kind":"kick","strength":0.8},{"ms":500,"kind":"percussive","strength":0.2}],
             "melodyStatus":"done","melodyNotes":[{"midi":60,"startMs":0,"endMs":300}],"importedFileName":"dmx_a1.m4a","futureKey":{"x":1}}
        """.trimIndent()
        val doc = PdjJson.lenient.decodeFromString<DemuxDocument>(full)
        assertEquals(DemuxArtifactStatus.RUNNING, doc.transcriptStatus)
        assertEquals(DemuxDrumKind.PERCUSSIVE, doc.drumHits!![1].kind)
        assertEquals(60, doc.melodyNotes!!.single().midi)
        assertEquals("dmx_a1.m4a", doc.importedFileName)
        assertEquals("hey", doc.words.single().text)
    }

    @Test fun encodeUsesIosKeysAndOmitsNullOptionals() {
        val text = PdjJson.lenient.encodeToString(DemuxDocument(sourceKey = "k", displayName = "n", chords = listOf(DemuxChordSegment(7, false, 0, 10, 0.5))))
        assertTrue(text.contains("\"rootPC\":7") && text.contains("\"chordStatus\":\"none\"") && text.contains("\"sourceKey\":\"k\""))
        assertFalse("nil optionals must not be written", text.contains("drumStatus") || text.contains("melodyNotes") || text.contains("importedFileName"))
    }

    @Test fun documentRoundTripsThroughDiskAndAFreshStore() {
        val src = DemuxSource.Song("sng_42", "Title", "Artist")
        val a = store()
        val doc = a.documentCreating(src)
        assertEquals("Artist — Title", doc.displayName)
        a.save(doc.copy(chords = listOf(DemuxChordSegment(2, true, 100, 900, 0.8)), chordStatus = DemuxArtifactStatus.DONE, durationMs = 1234))
        assertTrue(File(dir, "sng_42.json").isFile)
        val b = store()   // new memory tier -> must come from disk
        val back = b.document("sng_42")!!
        assertEquals(1234, back.durationMs); assertEquals("Dm", back.chords.single().name)
        assertNull(b.document("nope"))
    }

    @Test fun keyWithColonOrSlashIsFilesystemSafe() {
        val s = store()
        s.save(DemuxDocument(sourceKey = "am:1/2", displayName = "x"))
        assertTrue(File(dir, "am_1_2.json").isFile)
        assertNotNull(store().document("am:1/2"))
    }

    @Test fun corruptDocumentReadsAsMissingNotACrash() {
        File(dir, "bad.json").writeText("{not json")
        assertNull(store().document("bad"))
    }

    @Test fun importCopiesAudioAndSurvivesRestart() {
        val s = store()
        val src = s.importStream("My Riff.WAV", "RIFFxxxx".byteInputStream())!!
        assertTrue(src.id.startsWith("dmx_"))
        assertEquals("My Riff", src.name)
        val f = s.importedAudioFile(src.id)!!
        assertEquals("wav", f.extension); assertEquals("RIFFxxxx", f.readText())
        assertEquals(listOf(src.id to "My Riff"), store().importedSources())
        f.delete()
        assertTrue("an import whose audio is gone is not offered", store().importedSources().isEmpty())
    }

    @Test fun importedSourcesAreNameSortedCaseInsensitively() {
        val s = store()
        s.importStream("b.mp3", "1".byteInputStream()); s.importStream("A.mp3", "2".byteInputStream())
        assertEquals(listOf("A", "b"), s.importedSources().map { it.second })
    }

    @Test fun carvedSongPathIsStableAndOnlyExistsOnceWritten() {
        val s = store()
        val dest = s.carvedSongDestination("sng:9")!!
        assertEquals("sng_9.m4a", dest.name)
        assertEquals("audio", dest.parentFile.name)
        assertNull(s.carvedSongFile("sng:9"))
        dest.writeText("carved")
        assertEquals(dest, s.carvedSongFile("sng:9"))
        dest.writeText("")      // a zero-byte leftover is not a carve
        assertNull(s.carvedSongFile("sng:9"))
    }

    private val urls = mapOf("vocals" to "https://x/rips/stems/a_vocals.mp3", "drums" to "https://x/d.mp3", "bass" to "https://x/b.mp3?sig=1", "other" to "https://x/o.m4a")

    @Test fun stemsDownloadAllOrNothing() = runBlocking {
        val s = store()
        val ok = s.downloadStems("dmx_a", urls)!!
        assertEquals(listOf("vocals", "drums", "bass", "other"), ok.keys.toList())
        assertEquals(listOf("mp3", "mp3", "mp3", "m4a"), ok.values.map { it.extension })
        assertTrue(ok.values.all { it.isFile })
        assertEquals(ok.mapValues { it.value.name }, s.localStemFiles("dmx_a")!!.mapValues { it.value.name })
    }

    @Test fun aFailedStemRemovesTheWholeFolderSoNoHalfSetIsReady() = runBlocking {
        val calls = AtomicInteger()
        val s = store(fetch = { _, dest -> if (calls.incrementAndGet() == 3) false else { dest.writeText("x"); true } })
        assertNull(s.downloadStems("dmx_b", urls))
        assertNull(s.localStemFiles("dmx_b"))
        assertFalse(File(File(dir, "stems"), "dmx_b").exists())
    }

    @Test fun aMissingOrEmptyStemUrlFailsTheSet() = runBlocking {
        assertNull(store().downloadStems("dmx_c", urls - "other"))
        val empty = store(fetch = { _, dest -> dest.writeText(""); true })
        assertNull(empty.downloadStems("dmx_d", urls))
        assertNull(empty.localStemFiles("dmx_d"))
    }

    @Test fun threeOfFourStemsOnDiskIsNotReady() = runBlocking {
        val s = store()
        s.downloadStems("dmx_e", urls)
        File(File(File(dir, "stems"), "dmx_e"), "bass.mp3").delete()
        assertNull(s.localStemFiles("dmx_e"))
    }

    @Test fun chordAnalysisLandsOnTheDocumentAndDedupes() = runBlocking {
        val calls = AtomicInteger()
        val seg = listOf(DemuxChordSegment(0, false, 0, 2000, 0.9))
        val s = store(detect = { calls.incrementAndGet(); seg })
        val src = DemuxSource.ImportedFile("dmx_z", "z")
        s.analyzeChords(scope, src, "/x", 5000, dispatcher = Dispatchers.Unconfined)!!.join()
        val doc = s.document("dmx_z")!!
        assertEquals(DemuxArtifactStatus.DONE, doc.chordStatus); assertEquals(seg, doc.chords); assertEquals(5000, doc.durationMs)
        assertNull("done result is not re-run", s.analyzeChords(scope, src, "/x", 5000, dispatcher = Dispatchers.Unconfined))
        s.analyzeChords(scope, src, "/x", 5000, force = true, dispatcher = Dispatchers.Unconfined)!!.join()
        assertEquals(2, calls.get())
        assertTrue(s.chordRuns.value.isEmpty())
    }

    @Test fun emptyDetectionMarksFailedAndInFlightRunBlocksASecond() = runBlocking {
        val gate = CountDownLatch(1)
        val s = store(detect = { gate.await(5, TimeUnit.SECONDS); emptyList() })
        val src = DemuxSource.Studio("smp_1", "s")
        val job = s.analyzeChords(CoroutineScope(Dispatchers.Default), src, "/x", 100)!!
        assertTrue("running flag set", "smp_1" in s.chordRuns.value)
        assertNull("second kickoff is a no-op while in flight", s.analyzeChords(scope, src, "/x", 100, force = true))
        gate.countDown(); job.join()
        assertEquals(DemuxArtifactStatus.FAILED, s.document("smp_1")!!.chordStatus)
        assertFalse("smp_1" in s.chordRuns.value)
    }

    @Test fun sourceIdentityHelpers() {
        assertEquals("Title", DemuxSource.Song("i", "Title", "").displayName)
        assertEquals("i", DemuxSource.Song("i", "T", "A").songId)
        assertNull(DemuxSource.Studio("smp_1", "n").songId)
        assertTrue(DemuxSource.isSongKey("sng_1")); assertFalse(DemuxSource.isSongKey("dmx_ab")); assertFalse(DemuxSource.isSongKey("smp_ab"))
    }
}
