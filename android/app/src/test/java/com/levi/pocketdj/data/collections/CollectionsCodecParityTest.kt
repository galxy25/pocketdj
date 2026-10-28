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
    fun pocketDoesNotPersistAmPlaylistId() {
        val store = newStore()
        val p = store.createPocket("P")
        val pl = store.createPlaylist("L")
        store.linkPocketToAppleMusic(p.id, "p.AM1")
        store.linkToAppleMusic(pl.id, "p.AM2")
        assertEquals("p.AM1", store.pocket(p.id)!!.amPlaylistId)
        val text = File(tmp.root, CollectionsStore.FILE_NAME).readText()
        assertFalse(text.contains("amPlaylistId"))
        assertFalse(text.contains("p.AM1"))
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
