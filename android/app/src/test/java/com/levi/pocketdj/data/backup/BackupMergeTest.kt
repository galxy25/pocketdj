package com.levi.pocketdj.data.backup

import com.levi.pocketdj.data.collections.io.IoTestSupport
import com.levi.pocketdj.data.collections.io.PortableItems
import com.levi.pocketdj.data.settings.SourceConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupMergeTest {
    private fun b(s: String) = s.toByteArray(Charsets.UTF_8)
    private fun obj(d: ByteArray) = Json.parseToJsonElement(String(d, Charsets.UTF_8)).jsonObject

    @Test
    fun editsImportedValueWinsPerIdAndLocalOnlyIdsKept() {
        val local = b("""{"schemaVersion":2,"albums":{"alb_1":{"name":"Old"}},"songs":{"sng_1":{"bpm":100},"sng_local":{"bpm":90}},"meta":{"platform":"Android"}}""")
        val inc = b("""{"schemaVersion":1,"albums":{"alb_1":{"name":"New","futureField":7},"alb_2":{"genre":"Jazz"}},"songs":{"sng_1":{"bpm":120}}}""")
        val merged = obj(BackupEdits.merge(local, inc)!!)
        assertEquals(2, merged["schemaVersion"]!!.jsonPrimitive.content.toInt())
        assertEquals("New", merged["albums"]!!.jsonObject["alb_1"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals("7", merged["albums"]!!.jsonObject["alb_1"]!!.jsonObject["futureField"]!!.jsonPrimitive.content)
        assertTrue(merged["albums"]!!.jsonObject.containsKey("alb_2"))
        assertEquals("120", merged["songs"]!!.jsonObject["sng_1"]!!.jsonObject["bpm"]!!.jsonPrimitive.content)
        assertTrue(merged["songs"]!!.jsonObject.containsKey("sng_local"))
        assertEquals("Android", merged["meta"]!!.jsonObject["platform"]!!.jsonPrimitive.content)
    }

    @Test
    fun editsMergeIsIdempotentAndJunkIsNoOp() {
        val inc = b("""{"albums":{"a":{"name":"x"}},"songs":{"s":{"bpm":1}}}""")
        val once = BackupEdits.merge(null, inc)!!
        assertEquals(obj(once), obj(BackupEdits.merge(once, inc)!!))
        assertEquals(2, BackupEdits.count(inc))
        assertNull(BackupEdits.merge(once, b("not json")))
        assertNull(BackupEdits.merge(once, b("""{"albums":{},"songs":{}}""")))
        assertNull(BackupEdits.merge(once, null))
        assertEquals(0, BackupEdits.count(null))
    }

    @Test
    fun editsStorePersistsAndRoundTripsThroughBackupZip() {
        val dir = java.nio.file.Files.createTempDirectory("edits").toFile()
        val store = BackupEditsStore(java.io.File(dir, "e.json"))
        assertNull(store.exportData())
        val inc = b("""{"schemaVersion":2,"albums":{},"songs":{"sng_1":{"name":"Fixed"}}}""")
        assertEquals(1, store.importMerging(inc))
        val zip = BackupZip.export(BackupPayload(editsData = store.exportData()))
        val (payload, _) = BackupZip.import(zip)
        val restored = BackupEditsStore(java.io.File(dir, "e2.json"))
        assertEquals(1, restored.importMerging(payload.editsData))
        assertEquals("Fixed", obj(restored.exportData()!!)["songs"]!!.jsonObject["sng_1"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        dir.deleteRecursively()
    }

    @Test
    fun iosFixtureCarriesEditsAndFavoritesForMerge() {
        val (p, _) = BackupZip.import(IoTestSupport.resource("backup/ios-backup.pocketdj.zip"))
        assertTrue(p.favoritesData != null)
        assertTrue(p.editsData != null)
    }

    @Test
    fun sourcesMergeKeepsLocalAndAppendsOnlyUnmatched() {
        val local = listOf(SourceConfig("vinyl", "Vinyl", "https://a/index.json", true))
        val inc = listOf(
            SourceConfig(BackupSources.wireId("vinyl"), "Renamed", "https://other", true), // wire-id match
            SourceConfig("x", "Dup", "HTTPS://A/INDEX.JSON ", true), // url match
            SourceConfig("y", "Fresh", "https://fresh", false),
        )
        val merged = BackupSources.merge(local, inc)
        assertEquals(listOf("Vinyl", "Fresh"), merged.map { it.name })
        assertFalse(merged.last().enabled)
    }

    @Test
    fun profileSongIdsNeverTravelInItems() {
        assertTrue(PortableItems.isProfileSongId("pdj_abc"))
        assertFalse(PortableItems.isPortable("pdj_abc"))
        assertTrue(PortableItems.isPortable("sng_abc"))
        val pocket = com.levi.pocketdj.data.collections.Pocket(name = "P", songIds = listOf("sng_1", "pdj_2"))
        assertEquals(setOf("sng_1"), PortableItems.referencedIds(pocket, emptyList()).songs)
    }

    private val iosEdits = """{"schemaVersion":1,"meta":{"platform":"iOS","exportedAt":"2020-01-01T00:00:00Z"},
        "albums":{"alb_1":{"name":"Renamed Album"}},"songs":{"sng_1":{"name":"Fixed","bpm":128},"sng_2":{"key":"8A"}}}"""

    @Test
    fun realIosShapeCountsMergesAndIsIdempotent() {
        val dir = java.nio.file.Files.createTempDirectory("edits").toFile()
        val store = BackupEditsStore(java.io.File(dir, "e.json"))
        assertEquals(3, BackupEdits.count(b(iosEdits)))
        assertEquals(3, store.importMerging(b(iosEdits)))
        assertEquals("second restore of same backup changes nothing", 0, store.importMerging(b(iosEdits)))
        val changed = iosEdits.replace("\"Fixed\"", "\"Fixed2\"")
        assertEquals(1, store.importMerging(b(changed)))
        val o = obj(store.exportData()!!)
        assertEquals("Fixed2", o["songs"]!!.jsonObject["sng_1"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals("8A", o["songs"]!!.jsonObject["sng_2"]!!.jsonObject["key"]!!.jsonPrimitive.content)
        assertEquals("Renamed Album", o["albums"]!!.jsonObject["alb_1"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        dir.deleteRecursively()
    }

    @Test
    fun exportRestampsSchemaAndMeta() {
        val dir = java.nio.file.Files.createTempDirectory("edits").toFile()
        val store = BackupEditsStore(java.io.File(dir, "e.json"))
        store.importMerging(b(iosEdits))
        val o = obj(store.exportData()!!)
        assertEquals(2, o["schemaVersion"]!!.jsonPrimitive.content.toInt())
        assertEquals("Android", o["meta"]!!.jsonObject["platform"]!!.jsonPrimitive.content)
        assertTrue(o["meta"]!!.jsonObject["exportedAt"]!!.jsonPrimitive.content != "2020-01-01T00:00:00Z")
        dir.deleteRecursively()
    }

    @Test
    fun restoreMessageNeverClaimsEditsWereApplied() {
        val none = com.levi.pocketdj.data.collections.io.ImportSummary(com.levi.pocketdj.data.collections.io.ImportKind.BACKUP)
        val m = CollectionShare.restoreMessage(none, 0, 0, 0, 3)
        assertFalse(m, m.contains("Restored"))
        assertTrue(m, m.contains("not yet applied"))
        assertEquals("Already up to date - nothing new to import", CollectionShare.restoreMessage(none, 0, 0, 0, 0))
    }
}
