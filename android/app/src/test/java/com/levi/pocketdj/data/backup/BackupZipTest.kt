package com.levi.pocketdj.data.backup

import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.io.IoTestSupport
import com.levi.pocketdj.data.collections.io.ZipIo
import com.levi.pocketdj.data.settings.SourceConfig
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BackupZipTest {
    private val iosEntries = listOf("edits.json", "favorites.json", "folders.json", "manifest.json", "playlists.json", "pockets.json", "setlists.json", "sources.json")

    @Test
    fun iosBackupFixtureDecodes() {
        val (p, skipped) = BackupZip.import(IoTestSupport.resource("backup/ios-backup.pocketdj.zip"))
        assertEquals(listOf("pkt_ios_a", "pkt_ios_b"), p.pockets.map { it.id })
        assertEquals(true, p.pockets[0].cleanOnly)
        assertEquals("pls_ios_1", p.playlists.single().id)
        assertEquals(2, p.setlists.size)
        assertEquals("Gigs", p.folders.single().name)
        assertEquals(1, p.sourcesJson.size)
        assertEquals("Vinyl", BackupSources.fromWire(p.sourcesJson).single().name)
        assertEquals("https://example.com/index.json", BackupSources.fromWire(p.sourcesJson).single().url)
        assertTrue(String(p.favoritesData!!, Charsets.UTF_8).contains("sng_1"))
        assertEquals(SkippedCatalog(0, 0), skipped)
    }

    @Test
    fun roundTripKeepsIosEntryNamesAndManifestShape() {
        val (payload, _) = BackupZip.import(IoTestSupport.resource("backup/ios-backup.pocketdj.zip"))
        val out = BackupZip.export(payload, nowMs = 1_790_000_000_000)
        val entries = ZipIo.read(out)!!
        assertEquals(iosEntries, entries.keys.sorted())
        val man = IoTestSupport.json(entries["manifest.json"]!!) as JsonObject
        assertEquals(listOf("app", "counts", "exportedAt", "kind", "portable", "schemaVersion"), man.keys.toList())   // sorted keys
        assertEquals("backup", (man["kind"] as JsonPrimitive).content)
        assertEquals("2", (man["schemaVersion"] as JsonPrimitive).content)
        assertEquals("false", (man["portable"] as JsonPrimitive).content)
        val c = man["counts"] as JsonObject
        assertEquals(listOf("art", "items", "pockets", "playlists", "setlists", "sources").sorted(), c.keys.toList())
        assertEquals("2", (c["pockets"] as JsonPrimitive).content)
        assertEquals("1", (c["playlists"] as JsonPrimitive).content)
        assertEquals("2", (c["setlists"] as JsonPrimitive).content)
        assertEquals("1", (c["sources"] as JsonPrimitive).content)
        assertEquals("0", (c["items"] as JsonPrimitive).content)

        val (again, _) = BackupZip.import(out)
        assertEquals(payload.pockets, again.pockets)
        assertEquals(payload.playlists, again.playlists)
        assertEquals(payload.setlists, again.setlists)
        assertEquals(payload.folders, again.folders)
        assertEquals(payload.sourcesJson, again.sourcesJson)
        assertArrayEquals(payload.editsData, again.editsData)
        assertArrayEquals(payload.favoritesData, again.favoritesData)
    }

    @Test
    fun favoritesEntryOmittedWhenAbsent_editsAlwaysPresent() {
        val entries = ZipIo.read(BackupZip.export(BackupPayload()))!!
        assertFalse(entries.containsKey("favorites.json"))
        assertTrue(entries.containsKey("edits.json"))
        val (p, _) = BackupZip.import(BackupZip.export(BackupPayload()))
        assertNull(p.favoritesData)
    }

    @Test
    fun pwaBackupToleratedMissingKindItemsAndArtCounted() {
        val zip = ZipIo.write(mapOf(
            "manifest.json" to """{"app":"pocketdj","schemaVersion":1,"portable":true,"exportedAt":"x","counts":{"items":2}}""".toByteArray(),
            "sources.json" to """[{"id":"src_1","name":"PWA Source","type":"url"}]""".toByteArray(),   // DataSource[] shape
            "items.json" to """[{"id":"a"},{"id":"b"}]""".toByteArray(),
            "art/k1.webp" to byteArrayOf(1), "art/k2.webp" to byteArrayOf(2), "art/readme.txt" to byteArrayOf(3),
            "pockets.json" to """[{"id":"pkt_1","name":"P","songIds":["s"],"createdAt":1,"updatedAt":1},"junk"]""".toByteArray(),
        ))
        val (p, skipped) = BackupZip.import(zip)
        assertEquals(SkippedCatalog(items = 2, art = 2), skipped)
        assertEquals(listOf("pkt_1"), p.pockets.map { it.id })          // junk row drops only itself
        assertTrue(BackupSources.fromWire(p.sourcesJson).isEmpty())      // PWA DataSource[] skipped, not fatal
        assertTrue(p.playlists.isEmpty() && p.folders.isEmpty())
        val man = BackupZip.parseManifest(ZipIo.read(zip)!!["manifest.json"])!!
        assertNull(man.kind); assertEquals(1, man.schemaVersion); assertEquals(2, man.counts.items); assertEquals(true, man.portable)
    }

    @Test
    fun refusesForeignAppAndGarbage() {
        val foreign = ZipIo.write(mapOf("manifest.json" to """{"app":"other"}""".toByteArray()))
        try { BackupZip.import(foreign); fail() } catch (e: BackupZipException) { assertTrue(e.notABackup) }
        try { BackupZip.import("garbage".toByteArray()); fail() } catch (e: BackupZipException) { assertFalse(e.notABackup) }
    }

    @Test
    fun sourcesWireShapeMatchesIos() {
        val wire = BackupSources.toWire(listOf(SourceConfig(id = "A-1", name = "N", url = "https://u", enabled = false)))
        val o = wire.single() as JsonObject
        assertEquals(setOf("id", "name", "urlString", "enabled"), o.keys)
        val back = BackupSources.fromWire(wire).single()
        assertEquals(BackupSources.wireId("A-1"), back.id)
        assertEquals(listOf("N", "https://u", false), listOf(back.name, back.url, back.enabled))
    }

    @Test
    fun androidDefaultSourcesExportAsUuids_andMergeWithoutDuplicates() {
        val local = com.levi.pocketdj.data.settings.AppSettings.defaultSources()
        assertTrue(local.isNotEmpty())
        val wire = BackupSources.toWire(local)
        for (el in wire) {
            val id = ((el as JsonObject)["id"] as kotlinx.serialization.json.JsonPrimitive).content
            java.util.UUID.fromString(id) // throws if iOS' strict UUID decode would fail
        }
        // restoring our own export (or an iOS one with the same url) adds nothing
        assertEquals(local, BackupSources.merge(local, BackupSources.fromWire(wire)))
        val iosSameUrl = SourceConfig("6D7E4A44-0000-4000-8000-000000000001", "Other name", local.first().url, true)
        assertEquals(local, BackupSources.merge(local, listOf(iosSameUrl)))
        val fresh = SourceConfig("6D7E4A44-0000-4000-8000-000000000002", "New", "https://new.example/i.json", true)
        assertEquals(local + fresh, BackupSources.merge(local, listOf(fresh)))
        // a real UUID passes through (uppercased)
        assertEquals(fresh.id, BackupSources.wireId(fresh.id.lowercase()))
    }

    @Test
    fun emptyCollectionsRoundTrip() {
        val payload = BackupPayload(
            pockets = listOf(Pocket(id = "pkt_a", name = "A", createdAt = 1.0, updatedAt = 1.0)),
            playlists = listOf(CollectionsFactory.makePlaylist("PL", 1.0)),
            setlists = listOf(Setlist(id = "set_1", playlistId = "x")),
            folders = listOf(PlaylistFolder(id = "fld_1", name = "F")),
        )
        val (back, _) = BackupZip.import(BackupZip.export(payload))
        assertEquals(payload.pockets, back.pockets)
        assertEquals(payload.playlists.single().sequences.single().name, back.playlists.single().sequences.single().name)
        assertEquals(payload.setlists, back.setlists)
        assertEquals(payload.folders, back.folders)
    }
}
