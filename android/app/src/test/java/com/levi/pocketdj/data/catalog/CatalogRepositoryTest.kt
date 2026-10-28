package com.levi.pocketdj.data.catalog

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.discover.DiscoverAddsStore
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.SourceConfig
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** DISC-2: the provisional "Discover" source inside the real repository merge. */
class CatalogRepositoryTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private val scopes = mutableListOf<CoroutineScope>()

    private val body = """{"manifest":{"sourceName":"Apple Music"},"albums":[],"songs":[
        {"id":"real_1","artist":"A","name":"Real One","appleMusicId":"1"},
        {"id":"amrec_dup","artist":"A","name":"Real Wins","appleMusicId":"99"}]}"""

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown(); scopes.forEach { it.cancel() } }

    private fun repo(): CatalogRepository {
        val scope = CoroutineScope(Dispatchers.IO + Job()).also { scopes += it }
        val ds = PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "s.preferences_pb") }
        val store = AppSettingsStore(ds)
        kotlinx.coroutines.runBlocking {
            store.setSources(listOf(SourceConfig("a", "A", server.url("/a.json").toString())))
        }
        return CatalogRepository(CatalogService(tmp.newFolder("cache"), OkHttpClient()), store, scope)
    }

    private fun await(r: CatalogRepository, n: Int) {
        val end = System.currentTimeMillis() + 10_000
        while (r.refreshCompletions < n && System.currentTimeMillis() < end) Thread.sleep(5)
        if (r.refreshCompletions < n) throw AssertionError("only ${r.refreshCompletions}/$n refreshes completed")
    }

    private fun entry(id: String, am: String) =
        DiscoverAddsStore.Entry(songId = id, appleMusicId = am, title = "Prov $am", artist = "A", addedAtMs = 1.0)

    @Test fun provisionalIsAppendedLastShadowedByRealAndNeverDeleted() {
        server.enqueue(MockResponse().setBody(body))
        val adds = DiscoverAddsStore(File(tmp.root, "d.json"))
        adds.add(entry("amrec_5", "5")); adds.add(entry("amrec_dup", "77"))
        val r = repo()
        r.provisionalSources = { real -> adds.resolve(real) }
        r.loadIfNeeded(); await(r, 1)
        val cat = r.state.value.catalog!!
        assertEquals(listOf("Apple Music", "Discover"), cat.availableSources)
        assertEquals("Discover", cat.sourceOfSong["amrec_5"])
        assertEquals("first-wins: the real row shadows the provisional twin", "Real Wins", cat.songsById["amrec_dup"]?.name)
        assertEquals("Apple Music", cat.sourceOfSong["amrec_dup"])
        assertEquals("shadowing never deletes the provisional entry", 2, adds.entries.size)
    }

    @Test fun realRowWithSameAppleMusicIdSupersedesAndReportsRemapPairs() {
        server.enqueue(MockResponse().setBody(body))
        val adds = DiscoverAddsStore(File(tmp.root, "d.json"))
        adds.add(entry("amrec_1", "1")); adds.add(entry("amrec_5", "5"))
        val r = repo()
        r.provisionalSources = { real -> adds.resolve(real) }
        val pairs = java.util.concurrent.CopyOnWriteArrayList<Pair<String, String>>()
        r.onSupersede = { pairs += it }
        r.loadIfNeeded(); await(r, 1)
        val cat = r.state.value.catalog!!
        assertEquals(listOf("amrec_1" to "real_1"), pairs.toList())
        assertEquals("the superseded provisional row is not in the catalog", null, cat.songsById["amrec_1"])
        assertNotNull(cat.songsById["real_1"]); assertNotNull(cat.songsById["amrec_5"])
    }

    @Test fun addingAfterLoadAndRefreshingShowsTheNewProvisionalRow() {
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        server.enqueue(MockResponse().setResponseCode(304))
        server.enqueue(MockResponse().setResponseCode(304))
        val adds = DiscoverAddsStore(File(tmp.root, "d.json"))
        val r = repo()
        r.provisionalSources = { real -> adds.resolve(real) }
        adds.onChanged = { r.refresh() }
        r.loadIfNeeded(); await(r, 1)
        assertTrue(r.state.value.catalog!!.songsById["amrec_7"] == null)
        adds.add(entry("amrec_7", "7")); await(r, 2)
        assertEquals("Discover", r.state.value.catalog!!.sourceOfSong["amrec_7"])
        // User removal leaves the catalog again.
        adds.userRemove("amrec_7"); await(r, 3)
        assertTrue(r.state.value.catalog!!.songsById["amrec_7"] == null)
    }

    @Test fun localRemergeShowsAddWithoutAnyNetworkFetch() {
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        val adds = DiscoverAddsStore(File(tmp.root, "d.json"))
        val r = repo()
        r.provisionalSources = { real -> adds.resolve(real) }
        adds.onChanged = { r.remergeLocal() }
        r.loadIfNeeded(); await(r, 1)
        val requests = server.requestCount
        adds.add(entry("amrec_8", "8"))
        val end = System.currentTimeMillis() + 10_000
        while (r.state.value.catalog!!.songsById["amrec_8"] == null && System.currentTimeMillis() < end) Thread.sleep(5)
        assertEquals("Discover", r.state.value.catalog!!.sourceOfSong["amrec_8"])
        assertEquals("no source was re-requested", requests, server.requestCount)
    }

    @Test fun provisionalRowsShowEvenWhenNoSourceLoads() {
        server.enqueue(MockResponse().setResponseCode(500))
        val adds = DiscoverAddsStore(File(tmp.root, "d.json"))
        adds.add(entry("amrec_9", "9"))
        val r = repo()
        r.provisionalSources = { real -> adds.resolve(real) }
        r.loadIfNeeded(); await(r, 1)
        assertEquals("Discover", r.state.value.catalog?.sourceOfSong?.get("amrec_9"))
    }
}
