package com.levi.pocketdj.data.activity

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** COL-1: activity schema parity (new kinds, additive fields, per-element skip). */
class ActivityModelsCodecTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val json = PdjJson.lenient

    private val doc = """{"schemaVersion":1,"installId":"inst-1","events":[
      {"id":"1","at":1750000000000,"kind":"add","itemId":"s1","itemTitle":"T","itemArtist":"A",
       "collectionId":"pkt_1","collectionKind":"pocket","collectionName":"C","originInstallId":"inst-9"},
      {"id":"2","at":1750000000001,"kind":"catalogAdd","itemId":"s2","libraryWrite":"confirmed"},
      {"id":"3","at":1750000000002,"kind":"zzz","itemId":"s3"},
      {"id":"4","at":1750000000003,"kind":"catalogRemove","itemId":"s4"},
      {"at":5,"kind":"add"}
    ]}"""

    @Test
    fun unknownKindSkipsThatEventOnly() {
        val d = json.decodeFromString<ActivityDocument>(doc)
        assertEquals(listOf("1", "2", "4"), d.events.map { it.id })
        assertEquals(ActivityKind.CATALOG_ADD, d.events[1].kind)
        assertEquals(ActivityKind.CATALOG_REMOVE, d.events[2].kind)
        assertEquals("A", d.events[0].itemArtist)
        assertEquals("inst-9", d.events[0].originInstallId)
        assertEquals("confirmed", d.events[1].libraryWrite)
    }

    @Test
    fun roundTripKeepsKeysAndLeniency() {
        val d = json.decodeFromString<ActivityDocument>(doc)
        val out = Json.parseToJsonElement(json.encodeToString(ActivityDocument.serializer(), d)).jsonObject
        assertEquals("inst-1", out["installId"]!!.toString().trim('"'))
        val first = out["events"]!!.jsonArray[0].jsonObject
        assertEquals(
            setOf("id", "at", "kind", "itemId", "itemTitle", "itemArtist", "collectionId", "collectionKind", "collectionName", "originInstallId"),
            first.keys,
        )
        assertEquals("catalogAdd", out["events"]!!.jsonArray[1].jsonObject["kind"]!!.toString().trim('"'))
        // missing everything still loads degraded, not thrown
        val empty = json.decodeFromString<ActivityDocument>("{}")
        assertEquals(0, empty.events.size)
        assertEquals("", empty.installId)
    }

    @Test
    fun recordStampsOriginInstallIdAndArtist() {
        val file = File(tmp.root, CollectionActivityStore.FILE_NAME)
        file.writeText(doc)
        val store = CollectionActivityStore(file = file, json = json)
        assertEquals("inst-1", store.installId)
        assertEquals(3, store.events.size)
        val e = store.record(ActivityKind.CATALOG_ADD, "s9", itemTitle = "T", itemArtist = "Art", libraryWrite = "confirmed")
        assertNotNull(e)
        assertEquals("inst-1", e!!.originInstallId)
        assertEquals("Art", e.itemArtist)
        assertNull(e.collectionId)
        val reloaded = CollectionActivityStore(file = file, json = json)
        assertEquals(e, reloaded.events.last())
    }
}
