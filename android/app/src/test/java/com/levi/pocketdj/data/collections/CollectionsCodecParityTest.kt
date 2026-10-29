package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** COL-1: iOS fixture round-trip + additive fields + store idioms. */
class CollectionsCodecParityTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private var clock = 1_760_000_000_000.0
    private val json = PdjJson.lenient

    private val fixtureText: String by lazy {
        val url = javaClass.classLoader!!.getResource("fixtures/ios-collections-v7.json")!!
        File(url.toURI()).readText()
    }

    private fun roundTrip(): Pair<JsonObject, JsonObject> {
        val doc = CollectionsCodec.decode(json, fixtureText)
        val out = Json.parseToJsonElement(CollectionsCodec.encode(json, doc)).jsonObject
        return Json.parseToJsonElement(fixtureText).jsonObject to out
    }

    private fun keysById(root: JsonObject, list: String): Map<String, Set<String>> =
        root[list]!!.jsonArray.associate {
            val o = it.jsonObject
            o["id"]!!.toString() to o.keys
        }

    private fun newStore(): CollectionsStore =
        CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { clock })

    @Test
    fun iosFixtureRoundTripKeepsAdditiveKeys() {
        val (input, output) = roundTrip()
        assertEquals(keysById(input, "pockets"), keysById(output, "pockets"))
        assertEquals(keysById(input, "playlists"), keysById(output, "playlists"))
        // node key sets (recursive)
        fun nodeKeys(a: JsonArray): List<Set<String>> =
            a.flatMap { n ->
                val o = n.jsonObject
                listOf(o.keys) + (o["children"]?.jsonArray?.let(::nodeKeys) ?: emptyList())
            }
        for (i in 0..1) {
            assertEquals(
                nodeKeys(input["playlists"]!!.jsonArray[i].jsonObject["sequences"]!!.jsonArray),
                nodeKeys(output["playlists"]!!.jsonArray[i].jsonObject["sequences"]!!.jsonArray),
            )
        }
        val doc = CollectionsCodec.decode(json, fixtureText)
        assertEquals("push", doc.pockets[0].amSyncDirection)
        assertEquals(true, doc.pockets[0].cleanOnly)
        assertEquals(false, doc.pockets[0].recsEnabled)
        assertFalse(doc.playlists[0].wantsRecommendations)
        assertEquals(CollectionSyncDirection.PULL, doc.playlists[0].amSyncDir)
    }

    @Test
    fun amPlaylistIdPersistsOnPocketAndPlaylist() {
        val store = newStore()
        val p = store.createPocket("P")
        val pl = store.createPlaylist("L")
        store.linkPocketToAppleMusic(p.id, "p.AM1")
        store.linkToAppleMusic(pl.id, "p.AM2")
        val text = File(tmp.root, CollectionsStore.FILE_NAME).readText()
        assertTrue(text.contains("\"amPlaylistId\":\"p.AM1\"") || text.contains("\"amPlaylistId\": \"p.AM1\""))
        assertTrue(text.contains("p.AM2"))
        val back = CollectionsCodec.decode(json, text)
        assertEquals("p.AM1", back.pockets.single().amPlaylistId)
        assertEquals("p.AM2", back.playlists.single().amPlaylistId)
    }

    @Test
    fun unlinkedCollectionsNeverWriteTheKey() {
        val store = newStore()
        store.createPocket("P"); store.createPlaylist("L")
        val text = File(tmp.root, CollectionsStore.FILE_NAME).readText()
        assertFalse(text.contains("amPlaylistId"))
    }

    @Test
    fun iosWrittenAmPlaylistIdDecodesAndGarbledIsNull() {
        val ios = """{"schemaVersion":7,"pockets":[{"id":"pkt_a","name":"P","amPlaylistId":"p.IOS1"},{"id":"pkt_b","name":"Q","amPlaylistId":42}],
            "playlists":[{"id":"pls_a","name":"L","sequences":[],"amPlaylistId":"p.IOS2","createdAt":0,"updatedAt":0},
            {"id":"pls_b","name":"M","sequences":[],"amPlaylistId":{"x":1},"createdAt":0,"updatedAt":0}]}"""
        val doc = CollectionsCodec.decode(json, ios)
        assertEquals(listOf("p.IOS1", null), doc.pockets.map { it.amPlaylistId })
        assertEquals(listOf("p.IOS2", null), doc.playlists.map { it.amPlaylistId })
        val again = Json.parseToJsonElement(CollectionsCodec.encode(json, doc)).jsonObject
        assertEquals("p.IOS1", again["pockets"]!!.jsonArray[0].jsonObject["amPlaylistId"].toString().trim('"'))
        assertEquals("p.IOS2", again["playlists"]!!.jsonArray[0].jsonObject["amPlaylistId"].toString().trim('"'))
    }

    @Test
    fun envelopeExportStripsAmPlaylistId() {
        val pk = Pocket(id = "pkt_a", name = "P", amPlaylistId = "p.X", createdAt = 1.0, updatedAt = 1.0)
        val pl = Playlist(id = "pls_a", name = "L", sequences = emptyList(), amPlaylistId = "p.Y", createdAt = 1.0, updatedAt = 1.0)
        val a = String(com.levi.pocketdj.data.collections.io.CollectionFile.pocketEnvelope(pk, json))
        val b = String(com.levi.pocketdj.data.collections.io.CollectionFile.playlistEnvelope(pl, json))
        assertFalse(a.contains("amPlaylistId")); assertFalse(a.contains("p.X"))
        assertFalse(b.contains("amPlaylistId")); assertFalse(b.contains("p.Y"))
    }

    @Test
    fun unknownSyncDirectionReadsAsBoth() {
        val doc = CollectionsCodec.decode(json, fixtureText)
        assertEquals("sideways", doc.pockets[1].amSyncDirection)
        assertEquals(CollectionSyncDirection.BOTH, doc.pockets[1].amSyncDir)
        assertEquals(CollectionSyncDirection.BOTH, CollectionSyncDirection.fromRaw(null))
        assertTrue(CollectionSyncDirection.PUSH.allowsPush)
        assertFalse(CollectionSyncDirection.PUSH.allowsPull)
        assertFalse(CollectionSyncDirection.OFF.allowsPush)
    }

    @Test
    fun garbledPlaylistFlagsStayLenient() {
        val text = """{"schemaVersion":7,"playlists":[{"id":"pls_x","name":"X","cleanOnly":"yes","recsEnabled":5,
            "sequences":[],"createdAt":1,"updatedAt":2}]}"""
        val doc = CollectionsCodec.decode(json, text)
        assertEquals(1, doc.playlists.size)
        assertNull(doc.playlists[0].cleanOnly)
        assertNull(doc.playlists[0].recsEnabled)
    }

    @Test
    fun garbledPocketFlagsKeepThePocket() {
        val text = """{"schemaVersion":7,"pockets":[
            {"id":"pk_a","name":"A","amSyncDirection":5,"cleanOnly":1,"recsEnabled":"true","createdAt":1,"updatedAt":2},
            {"id":"pk_b","name":"B","cleanOnly":"true","createdAt":1,"updatedAt":2}],
            "playlists":[{"id":"pls_x","name":"X","amSyncDirection":7,"cleanOnly":"true","sequences":[],"createdAt":1,"updatedAt":2}]}"""
        val doc = CollectionsCodec.decode(json, text)
        assertEquals(2, doc.pockets.size)
        assertNull(doc.pockets[0].amSyncDirection)
        assertNull(doc.pockets[0].cleanOnly)
        assertNull(doc.pockets[0].recsEnabled)
        assertNull(doc.pockets[1].cleanOnly)
        assertEquals(1, doc.playlists.size)
        assertNull(doc.playlists[0].amSyncDirection)
        assertNull(doc.playlists[0].cleanOnly)
    }

    @Test
    fun cleanOnlyOffLeavesBytesUnchanged() {
        val store = newStore()
        val p = store.createPocket("P")
        val pl = store.createPlaylist("L")
        val file = File(tmp.root, CollectionsStore.FILE_NAME)
        val before = file.readText()
        store.setCleanOnlyForPocket(false, p.id)
        store.setCleanOnlyForPlaylist(false, pl.id)
        // updatedAt is bumped by mutate; compare with timestamps neutralised
        fun norm(s: String) = s.replace(Regex("\"updatedAt\":\\d+"), "")
        assertEquals(norm(before), norm(file.readText()))
        store.setCleanOnlyForPocket(true, p.id)
        assertTrue(file.readText().contains("\"cleanOnly\":true"))
        store.setCleanOnlyForPocket(false, p.id)
        assertFalse(file.readText().contains("cleanOnly"))
    }

    @Test
    fun recsEnabledOnLeavesBytesUnchanged() {
        val store = newStore()
        val p = store.createPocket("P")
        val file = File(tmp.root, CollectionsStore.FILE_NAME)
        fun norm(s: String) = s.replace(Regex("\"updatedAt\":\\d+"), "")
        val before = norm(file.readText())
        store.setRecommendationsEnabledForPocket(true, p.id)
        assertEquals(before, norm(file.readText()))
        store.setRecommendationsEnabledForPocket(false, p.id)
        assertEquals(false, store.pocket(p.id)!!.recsEnabled)
        assertFalse(store.pocket(p.id)!!.wantsRecommendations)
        assertTrue(file.readText().contains("\"recsEnabled\":false"))
        store.setRecommendationsEnabledForPocket(true, p.id)
        assertNull(store.pocket(p.id)!!.recsEnabled)
    }

    @Test
    fun linkToAppleMusicDoesNotTouchUpdatedAt() {
        val store = newStore()
        val pl = store.createPlaylist("L")
        val stamped = store.playlist(pl.id)!!.updatedAt
        clock += 10_000
        store.linkToAppleMusic(pl.id, "p.X")
        assertEquals(stamped, store.playlist(pl.id)!!.updatedAt, 0.0)
        assertEquals("p.X", store.playlist(pl.id)!!.amPlaylistId)
        val rev = store.state.value.revision
        store.linkToAppleMusic(pl.id, "p.X") // idempotent: no write
        assertEquals(rev, store.state.value.revision)
    }

    @Test
    fun convertPlaylistCarriesProvenance() {
        val store = newStore()
        val pl = store.createPlaylist("L")
        // stamp provenance directly through the codec path: reload from a doc with it
        val text = CollectionsCodec.encode(
            json,
            CollectionsDocument(
                playlists = listOf(
                    store.playlist(pl.id)!!.copy(
                        sourcePlaylistId = "pl_9",
                        sourceName = "Apple Music (Local)",
                        sourceSongIds = listOf("a", "b"),
                        sourceSyncEnabled = false,
                    ),
                ),
            ),
        )
        val f = File(tmp.root, "seeded.json").also { it.writeText(text) }
        val s2 = CollectionsStore(file = f, now = { clock })
        val pocket = s2.convertPlaylistToPocket(pl.id)!!
        assertEquals("pl_9", pocket.sourcePlaylistId)
        assertEquals("Apple Music (Local)", pocket.sourceName)
        assertEquals(listOf("a", "b"), pocket.sourceSongIds)
        assertEquals(false, pocket.sourceSyncEnabled)
        // hand-made playlist stays unlinked
        val plain = s2.createPlaylist("Plain")
        assertNull(s2.convertPlaylistToPocket(plain.id)!!.sourcePlaylistId)
    }
}
