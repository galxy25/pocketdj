package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.backup.BackupEdits
import com.levi.pocketdj.data.backup.BackupEditsStore
import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.AudioTrackEdit
import com.levi.pocketdj.data.catalog.CatalogEdits
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.applying
import com.levi.pocketdj.screens.settings.sections.EditsTransfer
import java.io.File
import java.time.Instant
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class EditDeltaTest {
    private val rawAlbum = IndexAlbum(
        id = "a1", artist = "Artist", name = "Title", genre = "Rock", year = 1999, country = null,
        audioTracks = listOf(
            AudioTrack(trackNumber = 1, startMs = 0, endMs = 1000, bpm = 120.0, key = "Am", camelot = "8A"),
            AudioTrack(trackNumber = 2, startMs = 1000, endMs = 2000, bpm = 128.5, key = null, camelot = null),
        ),
    )
    private val rawSong = IndexSong(
        id = "s1", artist = "Artist", name = "Song", trackNumber = 3, year = 1999, bpm = 124.0,
        key = "C", camelot = "8B", explicit = null, sentimentKeywords = listOf("happy"),
    )

    @Test fun unchangedFieldsStoreNothing() {
        val e = EditDelta.albumEdit(null, rawAlbum, "Title", "Artist", "Rock", "1999", "")
        assertTrue(e.isEmpty)
        assertEquals(AlbumEdit(), e)
    }

    @Test fun onlyTheChangedFieldIsStored() {
        val e = EditDelta.albumEdit(null, rawAlbum, " Title ", "Artist", "Rock", "2001", "")
        assertEquals(AlbumEdit(year = 2001), e)
    }

    @Test fun clearingAnOptionalFieldIsNotAnOverride_andBlankTitleIsEmptyString() {
        // iOS parity: optional() maps blank to nil == "no override" only when raw is nil; a raw value cleared
        // to blank yields null here too (no way to override-to-nil), while a blank title is stored as "".
        assertNull(EditDelta.optional("", "Rock").let { it })
        assertEquals("", EditDelta.string("  ", "Title"))
        assertNull(EditDelta.string("  ", null))
        assertEquals("Pop", EditDelta.optional(" Pop ", null))
        assertNull(EditDelta.optional("Rock", "Rock"))
    }

    @Test fun numericDeltas() {
        assertNull(EditDelta.int("1999", 1999))
        assertEquals(2000, EditDelta.int(" 2000 ", 1999))
        assertNull(EditDelta.int("abc", 1999))
        assertNull(EditDelta.double("124", 124.0))
        assertEquals(125.5, EditDelta.double("125.5", 124.0))
        assertEquals("124", EditDelta.trim(124.0))
        assertEquals("124.5", EditDelta.trim(124.5))
    }

    @Test fun boolAndTags() {
        assertNull(EditDelta.bool(false, null))
        assertEquals(true, EditDelta.bool(true, null))
        assertNull(EditDelta.bool(true, true))
        assertNull(EditDelta.tags("happy", listOf("happy")))
        assertEquals(listOf("a", "b"), EditDelta.tags(" a , ,b", listOf("happy")))
        assertNull(EditDelta.tags(" , ", null))
    }

    @Test fun songEditIsDeltaOnly() {
        val none = EditDelta.songEdit(rawSong, "Song", "Artist", "1999", "3", "124", "C", "8B", false, "happy")
        assertTrue(none.isEmpty)
        val e = EditDelta.songEdit(rawSong, "Song 2", "Artist", "1999", "3", "126", "C", "8B", true, "happy")
        assertEquals("Song 2", e.name)
        assertEquals(126.0, e.bpm)
        assertEquals(true, e.explicit)
        assertNull(e.artist); assertNull(e.year); assertNull(e.key); assertNull(e.sentimentKeywords)
        assertEquals("Song 2", rawSong.applying(e).name)
    }

    @Test fun albumSaveCarriesAudioOverrides() {
        val existing = AlbumEdit(year = 1, audioTracks = listOf(AudioTrackEdit(trackNumber = 1, bpm = 99.0)))
        val e = EditDelta.albumEdit(existing, rawAlbum, "New", "Artist", "Rock", "1999", "")
        assertEquals("New", e.name)
        assertNull(e.year)
        assertEquals(existing.audioTracks, e.audioTracks)
    }

    @Test fun audioEditDeltasAgainstRawAndMatchesByTrackNumber() {
        val rows = EditDelta.audioRows(rawAlbum.audioTracks)
        assertEquals("120", rows[0].bpm)
        assertEquals("128.5", rows[1].bpm)
        // untouched: no override at all
        assertNull(EditDelta.audioEdit(null, rawAlbum, rows).audioTracks)
        val changed = rows.toMutableList().also { it[1] = it[1].copy(bpm = "130", camelot = "9A") }
        val e = EditDelta.audioEdit(AlbumEdit(year = 2000), rawAlbum, changed)
        assertEquals(2000, e.year) // other album edits are kept
        val d = e.audioTracks!!
        assertEquals(2, d.size)
        assertTrue(d[0].isEmpty)
        assertEquals(2, d[1].trackNumber)
        assertEquals(130.0, d[1].bpm)
        assertEquals("9A", d[1].camelot)
        assertNull(d[1].startMs)
        val overlaid = rawAlbum.applying(e)
        assertEquals(130.0, overlaid.audioTracks!![1].bpm)
        assertEquals(120.0, overlaid.audioTracks!![0].bpm)
    }

    @Test fun revertingAudioToRawDropsTheOverride() {
        val existing = AlbumEdit(audioTracks = listOf(AudioTrackEdit(trackNumber = 2, bpm = 130.0)))
        // sheet seeded from the overlaid album, user sets it back to the raw 128.5
        val rows = EditDelta.audioRows(rawAlbum.applying(existing).audioTracks).toMutableList()
        rows[1] = rows[1].copy(bpm = "128.5")
        val e = EditDelta.audioEdit(existing, rawAlbum, rows)
        assertNull(e.audioTracks)
        assertTrue(e.isEmpty) // -> the store removes the entry
    }

    @Test fun exportStampsAndroidMetaAndKeepsEntries() {
        val raw = """{"schemaVersion":1,"albums":{"a1":{"year":2001}},"songs":{}}""".toByteArray()
        val out = Json.parseToJsonElement(String(EditsTransfer.exportBytes(raw, "1.2.3", Instant.parse("2026-01-02T03:04:05Z"))!!)).jsonObject
        assertEquals("2", out["schemaVersion"]!!.jsonPrimitive.content)
        assertEquals("android", out["meta"]!!.jsonObject["platform"]!!.jsonPrimitive.content)
        assertEquals("1.2.3", out["meta"]!!.jsonObject["appVersion"]!!.jsonPrimitive.content)
        assertEquals(1, BackupEdits.count(out.toString().toByteArray()))
        assertFalse(EditsTransfer.canExport(0))
        assertTrue(EditsTransfer.canExport(1))
        assertTrue(EditsTransfer.footer(1).startsWith("1 local metadata edit."))
        assertTrue(EditsTransfer.footer(2).startsWith("2 local metadata edits."))
    }

    @Test fun importMergeImportedWinsPerIdAndKeepsOthers() {
        val dir = File.createTempFile("edits", "d").also { it.delete(); it.mkdirs() }
        try {
            val f = File(dir, "pocketdj-edits.json")
            f.writeText("""{"schemaVersion":2,"albums":{"a1":{"year":1990},"a2":{"name":"Keep"}},"songs":{"s1":{"bpm":100.0}}}""")
            val incoming = """{"schemaVersion":1,"albums":{"a1":{"year":2005}},"songs":{"s9":{"name":"New"}},"meta":{"platform":"iOS"}}""".toByteArray()
            val changed = BackupEditsStore(f).importMerging(incoming)
            assertEquals(2, changed)
            val merged = CatalogEdits.decode(f.readBytes())
            assertEquals(2005, merged.albums["a1"]!!.year)
            assertEquals("Keep", merged.albums["a2"]!!.name)
            assertEquals(100.0, merged.songs["s1"]!!.bpm)
            assertEquals("New", merged.songs["s9"]!!.name)
            // re-importing the same file is a no-op
            assertEquals(0, BackupEditsStore(f).importMerging(incoming))
            assertEquals("No edits found in that file", EditsTransfer.importMessage(0, 0))
            assertEquals("Edits already up to date", EditsTransfer.importMessage(2, 0))
            assertEquals("Imported 1 edit", EditsTransfer.importMessage(2, 1))
        } finally { dir.deleteRecursively() }
    }

    @Test fun iosShapedJsonWithoutNewFieldsRoundTripsThroughDecode() {
        val doc = """{"schemaVersion":2,"albums":{"a1":{"name":"X"}},"songs":{"s1":{"explicit":true}}}"""
        val e = CatalogEdits.decode(doc.toByteArray())
        assertEquals("X", e.albums["a1"]!!.name)
        assertEquals(true, e.songs["s1"]!!.explicit)
        val re = Json.parseToJsonElement(com.levi.pocketdj.data.catalog.EditsStore.encode(e)).jsonObject
        assertEquals(JsonObject::class, re["albums"]!!.jsonObject["a1"]!!::class)
        assertEquals("X", re["albums"]!!.jsonObject["a1"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertFalse(re["albums"]!!.jsonObject["a1"]!!.jsonObject.containsKey("year"))
    }
}
