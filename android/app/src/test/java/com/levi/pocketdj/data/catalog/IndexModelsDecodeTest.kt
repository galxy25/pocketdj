package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.config.Endpoints
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.decodeFromStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Decode contract for the index documents (specs/catalog.md §2–§4), exercised
 * against a synthesized fixture that mirrors the live shape: unknown keys at
 * every level, explicit-null optionals, and absent optionals.
 */
@OptIn(ExperimentalSerializationApi::class)
class IndexModelsDecodeTest {

    private fun fixture(): IndexJson =
        javaClass.classLoader!!.getResourceAsStream("fixtures/vinyl-index-small.json")!!
            .buffered()
            .use { PdjJson.lenient.decodeFromStream(it) }

    @Test
    fun fixture_streamDecodes_withExpectedCounts() {
        val index = fixture()
        assertEquals(2, index.albums.size)
        assertEquals(4, index.songs.size)
        assertEquals(1, index.playlists?.size)
        assertEquals("My Vinyl", index.manifest.sourceName)
        assertEquals(2, index.manifest.counts?.albums)
    }

    @Test
    fun unknownKeys_areIgnoredEverywhere() {
        // manifest.schemaVersion, album.pointer/enrichment/indexing,
        // song.lyrics/lyricsSource/cloudReindex all exist in the fixture and
        // must not break the decode.
        val index = fixture()
        val album = index.albums.first()
        assertEquals("alb_aaa111bbb222", album.id)
        assertEquals("The Synth Owls", album.artist)
        val song = index.songs.first()
        assertEquals("Neon Runway", song.name)
        assertEquals("found", song.lyricsStatus)
    }

    @Test
    fun explicitNullOptionals_decodeAsKotlinNull() {
        val index = fixture()
        val song = index.songs.first { it.id == "sng_000000000002" }
        assertNull(song.bpm) // "bpm": null — "not analyzed yet"
        assertNull(song.key)
        assertNull(song.camelot)
        val album = index.albums.first { it.id == "alb_ccc333ddd444" }
        assertNull(album.coverArt)
        assertNull(album.genre)
        assertNull(album.year)
    }

    @Test
    fun absentOptionals_fallToDefaults() {
        val index = fixture()
        val song = index.songs.first { it.id == "sng_000000000003" }
        assertNull(song.length)
        assertNull(song.explicit)
        assertNull(song.lyricsStatus)
        assertNull(song.trackNumber)
        val album = index.albums.first { it.id == "alb_ccc333ddd444" }
        assertNull(album.coverArtSources)
        assertNull(album.audioTracks)
        assertNull(album.country)
    }

    @Test
    fun minimalDocument_decodes_playlistsAbsent() {
        val index = PdjJson.lenient.decodeFromString<IndexJson>(
            """{"manifest":{},"albums":[],"songs":[]}""",
        )
        assertNull(index.playlists)
        assertTrue(index.albums.isEmpty())
        assertEquals(IndexManifest.FALLBACK_SOURCE_NAME, index.manifest.displayName)
    }

    @Test
    fun artCandidates_cdnFirst_rootRelativeResolvedAgainstCatalogBase() {
        val album = fixture().albums.first()
        val candidates = album.artCandidates()
        assertEquals(3, candidates.size)
        assertEquals("${Endpoints.CATALOG_BASE}/art/alb_aaa111bbb222.jpg", candidates[0])
        assertEquals("https://images.example.com/night-circuit.jpg", candidates[1])
        assertEquals("https://images.example.com/night-circuit.jpg", candidates[2]) // coverArt fallback
        assertFalse(candidates[0].startsWith("/"))
    }

    @Test
    fun songLength_isMilliseconds() {
        val song = fixture().songs.first()
        assertEquals(215_000L, song.length)
        assertNotNull(song.bpm)
        assertEquals(118.2, song.bpm!!, 0.0001)
    }
}
