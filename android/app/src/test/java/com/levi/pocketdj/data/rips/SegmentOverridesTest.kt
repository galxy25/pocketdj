package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.AudioTrackEdit
import com.levi.pocketdj.data.catalog.CatalogEdits
import com.levi.pocketdj.data.catalog.IndexAlbum
import org.junit.Assert.assertEquals
import org.junit.Test

class SegmentOverridesTest {
    private val album = IndexAlbum(
        id = "alb", artist = "A", name = "N", trackList = listOf("s1", "s2", "s3"),
        audioTracks = listOf(
            AudioTrack(trackNumber = 1, startMs = 1_500, endMs = 199_000),
            AudioTrack(trackNumber = 2, startMs = 200_000, endMs = 409_000),
            AudioTrack(trackNumber = 3, startMs = 410_000, endMs = 590_000),
        ),
    )
    private val raw: (String) -> IndexAlbum? = { if (it == "alb") album else null }
    private val order: (String) -> List<String> = { if (it == "alb") album.trackList else emptyList() }

    @Test fun numberedDeltasMapOntoTrackOrder() {
        val edit = AlbumEdit(audioTracks = listOf(AudioTrackEdit(trackNumber = 2, startMs = 195_000), AudioTrackEdit(trackNumber = 3, endMs = 598_000)))
        val snap = SegmentOverrides.derive(mapOf("alb" to edit), raw, order)
        assertEquals(mapOf("s2" to 195_000L), snap.startMs)
        assertEquals(mapOf("s3" to 598_000L), snap.endMs)
    }

    @Test fun effectiveAlbumsContributeDetectedEndsAndMembership() {
        val snap = SegmentOverrides.derive(emptyMap(), { null }, { emptyList() }, listOf(album))
        assertEquals(mapOf("s1" to 199_000L, "s2" to 409_000L, "s3" to 590_000L), snap.detectedEndMs)
        assertEquals("alb", snap.albumOfSong["s2"])
        assertEquals(setOf("s1", "s2", "s3"), snap.albumTracks["alb"])
    }

    @Test fun positionalOnlyWhenDeltaHasNoTrackNumber() {
        // delta[0] has no number -> positional on segment 0; delta[1] is numbered 3 -> never leaks into segment 1.
        val edit = AlbumEdit(audioTracks = listOf(AudioTrackEdit(startMs = 2_000), AudioTrackEdit(trackNumber = 3, startMs = 405_000)))
        val snap = SegmentOverrides.derive(mapOf("alb" to edit), raw, order)
        assertEquals(mapOf("s1" to 2_000L, "s3" to 405_000L), snap.startMs)
    }

    @Test fun countMismatchIsNeverGuessed() {
        val edit = AlbumEdit(audioTracks = listOf(AudioTrackEdit(trackNumber = 2, startMs = 195_000)))
        assertEquals(SegmentOverrides.Snapshot(), SegmentOverrides.derive(mapOf("alb" to edit), raw) { listOf("s1", "s2") })
        val short = album.copy(trackList = listOf("s1", "s2"))
        assertEquals(SegmentOverrides.Snapshot(), SegmentOverrides.derive(emptyMap(), { null }, { emptyList() }, listOf(short)))
    }

    @Test fun derivesFromADecodedIosEditsDocument() {
        val json = """{"schemaVersion":2,"albums":{"alb":{"audioTracks":[{"trackNumber":2,"startMs":195000}]}},"songs":{}}"""
        val edits = CatalogEdits.decode(json.toByteArray())
        val snap = SegmentOverrides.derive(edits.albums, raw, order, listOf(album))
        assertEquals(195_000L, snap.startMs["s2"])
        assertEquals(4, snap.detectedEndMs.size + 1) // 3 detected ends + the sentinel, proving both inputs applied
    }
}
