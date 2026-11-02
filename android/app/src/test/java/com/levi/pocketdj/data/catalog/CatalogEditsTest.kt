package com.levi.pocketdj.data.catalog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Q115 / COL-14: the catalog edits overlay - a port of iOS EditSchema `applying` + `buildEffective`. */
class CatalogEditsTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun b(s: String) = s.toByteArray(Charsets.UTF_8)

    private val doc = IndexJson(
        manifest = IndexManifest(sourceName = "Vinyl"),
        albums = listOf(
            IndexAlbum(
                id = "alb_b", artist = "Beta", name = "Second", genre = "Rock", year = 1990, country = "US",
                trackList = listOf("sng_1", "sng_2"),
                audioTracks = listOf(
                    AudioTrack(trackNumber = 1, startMs = 0, endMs = 1000, bpm = 100.0, key = "C major", camelot = "8B"),
                    AudioTrack(trackNumber = 2, startMs = 1000, endMs = 2000, bpm = 110.0),
                ),
            ),
            IndexAlbum(id = "alb_c", artist = "Gamma", name = "Third"),
        ),
        songs = listOf(
            IndexSong(id = "sng_1", albumId = "alb_b", artist = "Beta", name = "One", bpm = 100.0, explicit = false,
                appleMusicId = "111", length = 1000),
            IndexSong(id = "sng_2", albumId = "alb_b", artist = "Beta", name = "Two", key = "A minor"),
        ),
    )

    private val catalog = MergedCatalog.merge(listOf(doc))

    @Test fun setFieldsOverrideAndUnsetFieldsKeepTheIndexValue() {
        val e = CatalogEdits.decode(b("""{"schemaVersion":2,"songs":{"sng_1":{"name":"Uno","bpm":128,"explicit":true,
            "sentimentKeywords":["happy"],"trackNumber":3,"year":2001,"key":"8A","camelot":"8A","artist":"Beta & Co"}}}"""))
        val s = e.apply(catalog).songsById["sng_1"]!!
        assertEquals("Uno", s.name); assertEquals("Beta & Co", s.artist); assertEquals(128.0, s.bpm!!, 0.0)
        assertEquals(true, s.explicit); assertEquals(listOf("happy"), s.sentimentKeywords); assertEquals(3, s.trackNumber)
        assertEquals(2001, s.year); assertEquals("8A", s.key); assertEquals("8A", s.camelot)
        // never-editable fields untouched
        assertEquals("sng_1", s.id); assertEquals("alb_b", s.albumId); assertEquals("111", s.appleMusicId); assertEquals(1000L, s.length)
        val two = e.apply(catalog).songsById["sng_2"]!!
        assertEquals("unedited song is the original row", catalog.songsById["sng_2"], two)
    }

    @Test fun albumEditRenamesAndReSortsBrowseOrder() {
        val e = CatalogEdits.decode(b("""{"albums":{"alb_b":{"artist":"Zeta","name":"Renamed","genre":"Jazz","year":1971,"country":"UK"}}}"""))
        val c = e.apply(catalog)
        assertEquals(listOf("alb_b", "alb_c"), catalog.albums.map { it.id })
        assertEquals("re-sorted by the EDITED artist", listOf("alb_c", "alb_b"), c.albums.map { it.id })
        val a = c.albumsById["alb_b"]!!
        assertEquals("Zeta", a.artist); assertEquals("Renamed", a.name); assertEquals("Jazz", a.genre)
        assertEquals(1971, a.year); assertEquals("UK", a.country)
        assertEquals("track list kept", listOf("sng_1", "sng_2"), a.trackList)
        assertEquals("albums list and by-id map agree", a, c.albums.last())
    }

    @Test fun audioTrackEditsMatchByTrackNumberElsePosition() {
        // numbered edit -> segment 2; un-numbered edit at index 0 -> segment 1 by position
        val e = CatalogEdits.decode(b("""{"albums":{"alb_b":{"audioTracks":[{"bpm":99.5},{"trackNumber":2,"camelot":"5A","endMs":2500}]}}}"""))
        val segs = e.apply(catalog).albumsById["alb_b"]!!.audioTracks!!
        assertEquals(99.5, segs[0].bpm!!, 0.0); assertEquals("8B", segs[0].camelot); assertEquals("C major", segs[0].key)
        assertEquals("5A", segs[1].camelot); assertEquals(2500L, segs[1].endMs); assertEquals(110.0, segs[1].bpm!!, 0.0)
    }

    @Test fun numberedAudioEditNeverLeaksIntoAPositionalMatch() {
        // index 1 carries trackNumber 9 (no such segment): segment 2 must stay untouched
        val segs = overlayAudio(
            listOf(AudioTrack(trackNumber = 1, bpm = 1.0), AudioTrack(trackNumber = 2, bpm = 2.0)),
            listOf(AudioTrackEdit(bpm = 10.0), AudioTrackEdit(trackNumber = 9, bpm = 90.0)),
        )!!
        assertEquals(10.0, segs[0].bpm!!, 0.0); assertEquals(2.0, segs[1].bpm!!, 0.0)
        assertNull(overlayAudio(null, listOf(AudioTrackEdit(bpm = 1.0))))
    }

    @Test fun noEditsOrNoMatchingIdsReturnTheSameInstance() {
        assertSame(catalog, CatalogEdits.EMPTY.apply(catalog))
        assertSame(catalog, CatalogEdits.decode(b("""{"songs":{"sng_other":{"name":"x"}}}""")).apply(catalog))
    }

    @Test fun lenientDecodeSkipsJunkEntriesKeepsTheRestAndIgnoresUnknownKeys() {
        val e = CatalogEdits.decode(b("""{"schemaVersion":9,"futureTop":{},"albums":{"alb_b":{"name":"N","futureField":[1,2]},
            "alb_bad":{"year":"not a year"}},"songs":{"sng_1":{"bpm":120},"sng_empty":{},"sng_null":{"name":null}},"meta":{"platform":"iOS"}}"""))
        assertEquals(setOf("alb_b"), e.albums.keys)
        assertEquals("an edit that overrides nothing is dropped", setOf("sng_1"), e.songs.keys)
        assertTrue(CatalogEdits.decode(b("not json")).isEmpty)
        assertTrue(CatalogEdits.decode(null).isEmpty)
        assertTrue(CatalogEdits.decode(b("[]")).isEmpty)
        assertTrue(CatalogEdits.decode(b("""{"albums":{},"songs":{}}""")).isEmpty)
    }

    @Test fun fileOverlayCachesUntilTheFileChanges() {
        val f = tmp.root.resolve(CatalogEditsFile.FILE_NAME)
        val src = CatalogEditsFile(f)
        assertSame("missing file => EMPTY", CatalogEdits.EMPTY, src.current())
        f.writeText("""{"songs":{"sng_1":{"name":"A"}}}""")
        val first = src.current()
        assertEquals("A", first.songs["sng_1"]!!.name)
        assertSame("unchanged file => same instance (the repository compares identity)", first, src.current())
        f.writeText("""{"songs":{"sng_1":{"name":"Bee"}}}""")
        src.invalidate()
        assertEquals("Bee", src.current().songs["sng_1"]!!.name)
        f.delete()
        assertSame(CatalogEdits.EMPTY, src.current())
    }
}
