package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.mix.engine.MixPlayOutcomeBridge
import com.levi.pocketdj.mix.engine.originCollectionIdIn
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import com.levi.pocketdj.mix.store.AutoRow
import com.levi.pocketdj.mix.store.TrackRef
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlayStarted
import com.levi.pocketdj.screens.mix.AutoMixPlan
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.random.Random

/** Pocket wheel phase 0 (port of iOS PlayAttributionTests): every play records the collection it came from. */
class PlayAttributionTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun loadable(id: String) = MixLoadable(id, "T$id", "A")

    private val catalog = MergedCatalog.merge(
        listOf(
            IndexJson(
                manifest = IndexManifest(sourceName = "Apple Music"),
                songs = listOf(IndexSong(id = "sng_1", artist = "A", name = "One", length = 60_000), IndexSong(id = "sng_2", artist = "A", name = "Two", length = 60_000)),
                playlists = listOf(IndexPlaylist("pl_pot", "Potential", listOf("sng_1", "sng_2"))),
            ),
        ),
    )

    private fun store() = CollectionsStore(file = File(tmp.root, "c.json")).also { it.catalogProvider = { catalog } }

    // ---- CollectionsStore resolution ----

    @Test fun historyContextResolvesSourcePlaylistAndFavorites() {
        val s = store()
        val ctx = s.historyContext("pl_pot")
        assertEquals(PlayContext.SOURCE_PLAYLIST, ctx.source)
        assertEquals("Potential", ctx.contextName)
        assertEquals("pl_pot", s.originCollection("pl_pot")?.second)
        val fav = s.historyContext("fav_songs")
        assertEquals(PlayContext.SOURCE_PLAYLIST, fav.source)
        assertEquals("Favorite songs", fav.contextName)
        assertEquals(PlayContext.SOURCE_PLAYLIST to "fav_songs", s.originCollection("fav_songs"))
        assertNull(s.originCollection("pl_unknown"))
        assertEquals(PlayContext.SOURCE_SETLIST, s.historyContext("pl_unknown").source)
    }

    @Test fun playNowOriginIdSurfacesAsNowPlayingOrigin() {
        val s = store()
        s.playNow(listOf("sng_1"), name = "Potential", sourceToken = PlayContext.SOURCE_PLAYLIST, originId = "pl_pot")
        assertEquals(PlayContext.SOURCE_PLAYLIST to "pl_pot", s.originCollection(NOW_PLAYING_SETLIST_ID))
        s.playNow(listOf("sng_2"), name = "Queue", sourceToken = PlayContext.SOURCE_BROWSER)
        assertNull(s.originCollection(NOW_PLAYING_SETLIST_ID))
    }

    // ---- Mix per-row crate origin ----

    @Test fun mixSourceCollectionId() {
        assertEquals("pkt_1", MixSource.Pocket("pkt_1").collectionId)
        assertEquals("pls_1", MixSource.Playlist("pls_1").collectionId)
        assertEquals("set_1", MixSource.Setlist("set_1").collectionId)
    }

    @Test fun interleaveStampsEachRowWithItsOwnCrate() {
        val a = listOf(loadable("a0"), loadable("a1"))
        val b = listOf(loadable("b0"), loadable("b1"))
        val q = AutoMixPlan.interleave(a, b, "A", "B", false, Random(0), originA = "pkt_a", originB = "pls_b")
        assertEquals(listOf("a0", "b0", "a1", "b1"), q.items.map { it.loadable.songId })
        assertEquals(listOf("pkt_a", "pls_b", "pkt_a", "pls_b"), q.items.map { it.originCollectionId })
        assertEquals(listOf("A", "B", "A", "B"), q.items.map { it.sourceLabel })
    }

    @Test fun singleCrateItemCarriesOriginWithoutLabel() {
        val it = AutoMixPlan.item(loadable("a0"), null, "pkt_a")
        assertNull(it.sourceLabel)
        assertEquals("pkt_a", it.originCollectionId)
        assertNull(AutoMixPlan.item(loadable("a0")).originCollectionId)
    }

    @Test fun originLookupTieGoesToTheRowOnAirNotTheNextCopy() {
        val q = listOf(
            AutoMixItem(loadable("x"), 1000, "A", "pkt_a"),
            AutoMixItem(loadable("m"), 1000, "A", "pkt_a"),
            AutoMixItem(loadable("x"), 1000, "B", "pls_b"),
        )
        assertEquals("pkt_a", originCollectionIdIn(q, 1, "x")) // equidistant: earlier (on-air) copy
    }

    @Test fun originLookupPrefersTheCopyNearestTheCursor() {
        val q = listOf(
            AutoMixItem(loadable("x"), 1000, "A", "pkt_a"),
            AutoMixItem(loadable("y"), 1000, "B", "pls_b"),
            AutoMixItem(loadable("x"), 1000, "B", "pls_b"),
        )
        assertEquals("pkt_a", originCollectionIdIn(q, 0, "x"))
        assertEquals("pls_b", originCollectionIdIn(q, 2, "x"))
        assertEquals("pls_b", originCollectionIdIn(q, 99, "x")) // cursor clamped
        assertNull(originCollectionIdIn(q, 0, "ghost"))
        assertNull(originCollectionIdIn(emptyList(), 0, "x"))
        assertNull(originCollectionIdIn(listOf(AutoMixItem(loadable("z"), 1)), 0, "z")) // row without provenance
    }

    @Test fun autoRowWithoutOriginDecodesAndRoundTripsByteStable() {
        val legacy = """{"track":{"songId":"s1","title":"T","artist":"A"},"durationMs":1000,"sourceLabel":"Warmup"}"""
        val row = PdjJson.lenient.decodeFromString<AutoRow>(legacy)
        assertNull(row.originCollectionId)
        assertEquals("Warmup", row.sourceLabel)
        val withOrigin = row.copy(originCollectionId = "pkt_1")
        val back = PdjJson.lenient.decodeFromString<AutoRow>(PdjJson.lenient.encodeToString(withOrigin))
        assertEquals("pkt_1", back.originCollectionId)
        assertEquals(TrackRef("s1", "T", "A"), back.track)
    }

    @Test fun bridgeStampsThePlayWithItsRowOrigin() {
        val emitted = ArrayList<PlayStarted>()
        val bridge = MixPlayOutcomeBridge(
            emit = { emitted += it }, findEvent = { _, _, _ -> null },
            noteListened = { _, _ -> }, markSkipped = {}, wasSkipped = { false },
            originOf = { if (it == "s1") "pkt_a" else null },
            contextId = { "mix_sess" }, nowMs = { 5L },
        )
        bridge.onSongPlayed("s1", Deck.A)
        bridge.onSongPlayed("s2", Deck.B)
        assertEquals(listOf("pkt_a", null), emitted.map { it.originCollectionId })
        assertEquals("mix", emitted[0].context.source)
    }

    @Test fun historyRecordsTheMixCrateAsOriginButNotForOtherSurfaces() {
        val h = PlayHistoryStore(File(tmp.root, "h.json"), PdjJson.lenient)
        val mixCtx = PlayContext(PlayContext.SOURCE_MIX, contextId = "mix_sess", contextName = "Warmup")
        val e = h.record("a", context = mixCtx, nowMs = 1_750_000_000_000L, originCollectionId = "pkt_a")!!
        assertEquals("pkt_a", e.originCollectionId)
        assertEquals("mix_sess", e.contextId)
        val album = h.record("b", context = PlayContext.album("al", "A"), nowMs = 1_750_000_100_000L, originCollectionId = "pkt_a")!!
        assertNull(album.originCollectionId)
    }

    // ---- ListeningPocketsCollections context rules ----

    @Test fun contextRulesForRunTagsFavoritesAndSourcePlaylists() {
        assertNull(ListeningPocketsCollections.context("pwr_0123", PlaySource.POCKET))
        assertNull(ListeningPocketsCollections.context("fav_songs", PlaySource.PLAYLIST))
        assertEquals("pl_pot" to "source", ListeningPocketsCollections.context("pl_pot", PlaySource.BROWSER))
        assertEquals("pl_pot" to "source", ListeningPocketsCollections.context("pl_pot", PlaySource.MIX))
        // Prefix rules still win and existing fallbacks are unchanged.
        assertEquals("pkt_1" to "pocket", ListeningPocketsCollections.context("pkt_1", PlaySource.MIX))
        assertNull(ListeningPocketsCollections.context("alb", PlaySource.ALBUM))
    }

    @Test fun rawContextPicksFirstNonRunTag() {
        assertEquals("pl_row", ListeningPocketsCollections.rawContextId("pl_row", "pkt_o", "set_c"))
        assertEquals("pkt_o", ListeningPocketsCollections.rawContextId("pwr_1", "pkt_o", "set_c"))
        assertEquals("set_c", ListeningPocketsCollections.rawContextId(null, "pwr_1", "set_c"))
        assertNull(ListeningPocketsCollections.rawContextId(null, "pwr_1", "pwr_2"))
        assertNull(ListeningPocketsCollections.rawContextId(null, null, null))
        // A favorites origin is chosen first, then dropped by context(): it never rides.
        assertNull(ListeningPocketsCollections.context(ListeningPocketsCollections.rawContextId(null, "fav_songs", "set_c"), PlaySource.PLAYLIST))
    }
}
