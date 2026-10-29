package com.levi.pocketdj.data.catalog

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.favorites.FavoritesStore
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.SourceConfig
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** ANS-COL-3: imported amrec_ rows yield to an indexed twin inside the real repository merge, then collections + favorites follow. */
class ImportedSupersedeWiringTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private val scopes = mutableListOf<CoroutineScope>()

    private val body = """{"manifest":{"sourceName":"Apple Music"},"albums":[],"songs":[
        {"id":"sng_real","artist":"A","name":"Real One","appleMusicId":"9"}]}"""

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown(); scopes.forEach { it.cancel() } }

    private fun repo(): CatalogRepository {
        val scope = CoroutineScope(Dispatchers.IO + Job()).also { scopes += it }
        val ds = PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "s.preferences_pb") }
        val store = AppSettingsStore(ds)
        kotlinx.coroutines.runBlocking { store.setSources(listOf(SourceConfig("a", "A", server.url("/a.json").toString()))) }
        return CatalogRepository(CatalogService(tmp.newFolder("cache"), OkHttpClient()), store, scope)
    }

    private fun await(r: CatalogRepository, n: Int) {
        val end = System.currentTimeMillis() + 10_000
        while (r.refreshCompletions < n && System.currentTimeMillis() < end) Thread.sleep(5)
        if (r.refreshCompletions < n) throw AssertionError("only ${r.refreshCompletions}/$n refreshes completed")
    }

    private fun song(id: String, am: String?) = ImportedSongsStore.SongEntry(songId = id, title = "Imp $id", artist = "A", appleMusicId = am)

    @Test fun repositoryMergeDropsRemappedRowAndFiresCallbackAfterPublish() {
        server.enqueue(MockResponse().setBody(body))
        val imported = ImportedSongsStore(File(tmp.root, "i.json"))
        imported.add(listOf(song("amrec_1", "9"), song("sng_keep", "5")))
        val r = repo()
        r.importedSource = { real -> imported.resolve(real) }
        val seen = CopyOnWriteArrayList<List<Pair<String, String>>>()
        var catalogAtCallback: MergedCatalog? = null
        r.onImportedSupersede = { catalogAtCallback = r.state.value.catalog; seen += it }
        r.loadIfNeeded(); await(r, 1)
        val cat = r.state.value.catalog!!
        assertEquals(listOf(listOf("amrec_1" to "sng_real")), seen.toList())
        assertNotNull("the callback fires AFTER the merge published", catalogAtCallback)
        assertNull("no duplicate: the remapped imported row is not in the catalog", cat.songsById["amrec_1"])
        assertNotNull(cat.songsById["sng_real"])
        assertEquals("Imported", cat.sourceOfSong["sng_keep"])
        assertEquals("only amrec_ entries are removed, and only by the callback", 2, imported.songs().size)
    }

    @Test fun landingRemovesImportedThenRemapsCollectionsAndFavorites() {
        val col = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        val fav = File(tmp.root, "fav.json").let { f -> FavoritesStore(f, writer = VersionedJsonWriter(f)) }
        val imported = ImportedSongsStore(File(tmp.root, "i.json"))
        imported.add(listOf(song("amrec_1", "9")))
        val cat = MergedCatalog.merge(listOf(IndexJson(manifest = IndexManifest(sourceName = "AM"), songs = listOf(
            IndexSong(id = "amrec_1", artist = "A", name = "x"), IndexSong(id = "sng_real", artist = "A", name = "x", appleMusicId = "9")))))
        col.catalogProvider = { cat }
        val pocket = col.createPocket("P"); col.addSongToPocket("amrec_1", pocket.id)
        fav.toggle("amrec_1", null); assertTrue(fav.isFavorite("amrec_1"))

        val order = mutableListOf<String>()
        ImportedSongsStore.landSupersede(
            listOf("amrec_1" to "sng_real"),
            removeImported = { order += "remove"; imported.remove(it) },
            remapCollections = { order += "collections"; col.remapSongIds(it) },
            remapFavorites = { order += "favorites"; fav.remapSongIds(it) },
        )
        assertEquals(listOf("remove", "collections", "favorites"), order)
        assertTrue(imported.songs().isEmpty())
        assertEquals(listOf("sng_real"), col.pocket(pocket.id)!!.songIds)
        assertTrue(fav.isFavorite("sng_real")); assertFalse(fav.isFavorite("amrec_1"))
    }

    @Test fun aFailingStepNeverBlocksTheRest() {
        val order = mutableListOf<String>()
        ImportedSongsStore.landSupersede(
            listOf("a" to "b"),
            removeImported = { order += "remove"; error("boom") },
            remapCollections = { order += "collections" },
            remapFavorites = { order += "favorites" },
        )
        assertEquals(listOf("remove", "collections", "favorites"), order)
        ImportedSongsStore.landSupersede(emptyList(), { order += "x" }, { order += "x" }, { order += "x" })
        assertEquals(3, order.size)
    }
}
