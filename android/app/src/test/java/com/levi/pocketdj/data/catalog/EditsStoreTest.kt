package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.backup.BackupEditsStore
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class EditsStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Rig(val file: File, val reader: CatalogEditsFile, val writer: VersionedJsonWriter, val store: EditsStore) {
        var changes = 0
    }

    private fun rig(): Rig {
        val file = File(tmp.root, CatalogEditsFile.FILE_NAME)
        val reader = CatalogEditsFile(file)
        val writer = VersionedJsonWriter(file)
        lateinit var r: Rig
        val store = EditsStore(reader, writer) { r.changes++ }
        r = Rig(file, reader, writer, store)
        return r
    }

    private val iosDoc = """{"schemaVersion":2,"albums":{"alb_1":{"name":"Renamed","audioTracks":[{"trackNumber":2,"startMs":1000,"endMs":9000}]}},
        |"songs":{"sng_1":{"name":"New Title","bpm":120.5}},"meta":{"platform":"iOS"}}""".trimMargin()

    @Test fun fileNameIsTheIosOne() = assertEquals("pocketdj-edits.json", CatalogEditsFile.FILE_NAME)

    @Test fun iosFixtureReadsThroughTheStore() {
        val r = rig()
        r.file.writeText(iosDoc)
        assertEquals("Renamed", r.store.albumEdit("alb_1")?.name)
        assertEquals(9000L, r.store.albumEdit("alb_1")?.audioTracks?.single()?.endMs)
        assertEquals("New Title", r.store.songEdit("sng_1")?.name)
        assertEquals(2, r.store.count)
        assertNull(r.store.songEdit("missing"))
    }

    @Test fun writesOnlyDeltasInIosShape() {
        val r = rig()
        r.store.setSongEdit("sng_9", SongEdit(name = "Only Name"))
        val root = Json.parseToJsonElement(r.file.readText()).jsonObject
        assertEquals(2, root["schemaVersion"].toString().toInt())
        assertEquals("""{"name":"Only Name"}""", root["songs"]!!.jsonObject["sng_9"].toString())
        assertEquals(JsonObject(emptyMap()), root["albums"])
        assertEquals(1, r.changes)
    }

    @Test fun writeThenReadRoundTripsAndPreservesOtherEntries() {
        val r = rig()
        r.file.writeText(iosDoc)
        r.store.setAlbumEdit("alb_2", AlbumEdit(artist = "Zed", audioTracks = listOf(AudioTrackEdit(trackNumber = 1, startMs = 5))))
        assertEquals("Renamed", r.store.albumEdit("alb_1")?.name)
        assertEquals("Zed", r.store.albumEdit("alb_2")?.artist)
        assertEquals(5L, r.store.albumEdit("alb_2")?.audioTracks?.single()?.startMs)
        assertEquals("New Title", r.store.songEdit("sng_1")?.name)
        // Re-encode is stable: a fresh reader decodes the same overlay.
        val again = CatalogEdits.decode(r.file.readBytes())
        assertEquals(r.reader.current().albums, again.albums)
        assertEquals(r.reader.current().songs, again.songs)
    }

    @Test fun emptyEditRemovesTheEntry() {
        val r = rig()
        r.store.setSongEdit("s", SongEdit(name = "x"))
        assertEquals(1, r.store.count)
        r.store.setSongEdit("s", SongEdit())
        assertNull(r.store.songEdit("s"))
        assertEquals(0, r.store.count)
        r.store.setAlbumEdit("a", AlbumEdit(name = "n"))
        r.store.setAlbumEdit("a", AlbumEdit(audioTracks = listOf(AudioTrackEdit(trackNumber = 3))))
        assertNull(r.store.albumEdit("a")) // a numbered-only track edit overrides nothing
    }

    @Test fun removeApisAndNoOpWritesDoNotChurn() {
        val r = rig()
        r.store.setAlbumEdit("a", AlbumEdit(name = "n"))
        r.store.setSongEdit("s", SongEdit(name = "m"))
        val writes = r.writer.writeCount
        r.store.setSongEdit("s", SongEdit(name = "m")) // identical -> no write, no callback
        assertEquals(writes, r.writer.writeCount)
        r.store.removeAlbumEdit("a"); r.store.removeSongEdit("s")
        assertEquals(0, r.store.count)
        r.store.removeSongEdit("s") // already gone
        assertEquals(writes + 2, r.writer.writeCount)
    }

    @Test fun migratesLegacyBackupEditsOnce() {
        val legacy = File(tmp.root, CatalogEditsFile.LEGACY_FILE_NAME).apply { writeText(iosDoc) }
        val r = rig()
        assertFalse(legacy.exists())
        assertEquals(iosDoc, r.file.readText())
        assertEquals("Renamed", r.store.albumEdit("alb_1")?.name)
    }

    @Test fun migrationNeverClobbersAnExistingNewFile() {
        File(tmp.root, CatalogEditsFile.FILE_NAME).writeText("""{"songs":{"x":{"name":"new"}}}""")
        val legacy = File(tmp.root, CatalogEditsFile.LEGACY_FILE_NAME).apply { writeText(iosDoc) }
        val r = rig()
        assertFalse(legacy.exists())
        assertEquals("new", r.store.songEdit("x")?.name)
        assertNull(r.store.songEdit("sng_1"))
    }

    @Test fun pullWritesBytesVerbatimAndNeverPushesBack() {
        val r = rig()
        r.store.setSongEdit("old", SongEdit(name = "local"))
        val before = r.writer.writeCount
        r.changes = 0
        r.store.writePulled(iosDoc.toByteArray())
        assertEquals(iosDoc, r.file.readText()) // byte-for-byte, meta included, not re-encoded
        assertEquals(before + 1, r.writer.writeCount)
        val stamp = r.file.lastModified() to r.file.length()
        assertFalse(r.store.reloadFromDisk()) // false = nothing re-saved, so the sync engine has nothing to push
        assertEquals(before + 1, r.writer.writeCount)
        assertEquals(stamp, r.file.lastModified() to r.file.length())
        assertEquals(1, r.changes) // the overlay is re-applied exactly once
        assertNull(r.store.songEdit("old")) // whole-document LWW: the cloud copy replaced the local one
        assertEquals("New Title", r.store.songEdit("sng_1")?.name)
    }

    @Test fun backupRestoreWritesThroughTheStore() {
        val r = rig()
        r.store.setSongEdit("keep", SongEdit(name = "mine"))
        val backup = BackupEditsStore(r.file, write = r.store::replaceRaw)
        val n = backup.importMerging(iosDoc.toByteArray())
        assertEquals(2, n)
        assertEquals("mine", r.store.songEdit("keep")?.name)
        assertEquals("New Title", r.store.songEdit("sng_1")?.name)
        assertTrue(r.changes >= 2)
        assertEquals(0, backup.importMerging(iosDoc.toByteArray())) // idempotent
    }

    @Test fun clearAllDropsTheDocumentAndLegacyFile() {
        val r = rig()
        r.store.setSongEdit("s", SongEdit(name = "x"))
        File(tmp.root, CatalogEditsFile.LEGACY_FILE_NAME).writeText("{}")
        r.store.clearAll()
        assertFalse(r.file.exists())
        assertFalse(File(tmp.root, CatalogEditsFile.LEGACY_FILE_NAME).exists())
        assertEquals(0, r.store.count)
        // A later write still lands (the delete did not poison the version floor).
        r.store.setSongEdit("t", SongEdit(name = "y"))
        assertEquals("y", r.store.songEdit("t")?.name)
    }

    @Test fun malformedPulledDocumentDegradesToNoOverrides() {
        val r = rig()
        r.store.writePulled("not json".toByteArray())
        r.store.reloadFromDisk()
        assertEquals(0, r.store.count)
    }
}
