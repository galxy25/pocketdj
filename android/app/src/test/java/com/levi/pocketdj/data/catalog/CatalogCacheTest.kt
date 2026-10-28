package com.levi.pocketdj.data.catalog

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.settings.SourceConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import com.levi.pocketdj.data.settings.AppSettingsStore
import java.io.File
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CatalogCacheTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var cacheDir: File

    private val body = """{"manifest":{"sourceName":"My Vinyl"},"albums":[],"songs":[{"id":"s1","artist":"A","name":"S"}]}"""

    @Before fun setUp() { server = MockWebServer().also { it.start() }; cacheDir = tmp.newFolder("c") }
    @After fun tearDown() { server.shutdown() }

    private fun url() = server.url("/i.json").toString()

    @Test fun serviceReusesSeedOn304WithoutDecoding() = runTest {
        val warm = CatalogService(cacheDir, OkHttpClient())
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        val first = warm.load(url())
        assertTrue(first.changed)
        assertFalse(first.fromCache)

        server.enqueue(MockResponse().setResponseCode(304))
        val second = warm.load(url(), seed = first.index)
        assertSame(first.index, second.index)
        assertFalse(second.changed)
        assertTrue(second.fromCache)
    }

    @Test fun serviceWithoutSeedOn304DecodesCacheAndReportsChanged() = runTest {
        val svc = CatalogService(cacheDir, OkHttpClient())
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        svc.load(url())
        server.enqueue(MockResponse().setResponseCode(304))
        val r = svc.load(url())
        assertTrue(r.fromCache)
        assertTrue(r.changed)
    }

    @Test fun serviceReusesSeedOnNetworkFailureAndServerError() = runTest {
        val svc = CatalogService(cacheDir, OkHttpClient())
        server.enqueue(MockResponse().setBody(body))
        val seed = svc.load(url()).index
        server.enqueue(MockResponse().setResponseCode(500))
        val r1 = svc.load(url(), seed)
        assertSame(seed, r1.index); assertFalse(r1.changed)
        server.shutdown()
        val r2 = svc.load(url(), seed)
        assertSame(seed, r2.index); assertFalse(r2.changed)
    }

    @Test fun seedOn304NeverTouchesTheDiskCacheDecode() = runTest {
        val svc = CatalogService(cacheDir, OkHttpClient())
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        val seed = svc.load(url()).index
        // Corrupt the cached bytes: any decode of them would fail or differ.
        svc.cacheFile(url()).writeText("garbage")
        server.enqueue(MockResponse().setResponseCode(304))
        assertSame(seed, svc.load(url(), seed).index)
    }

    // ---- repository ----

    private val scopes = mutableListOf<CoroutineScope>()
    @After fun cancelScopes() { scopes.forEach { it.cancel() } }

    private fun repo(): CatalogRepository {
        val scope = CoroutineScope(Dispatchers.IO + Job()).also { scopes += it }
        val ds = PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "s.preferences_pb") }
        val store = AppSettingsStore(ds)
        kotlinx.coroutines.runBlocking {
            store.setSources(listOf(SourceConfig("a", "A", server.url("/a.json").toString())))
        }
        return CatalogRepository(CatalogService(cacheDir, OkHttpClient()), store, scope)
    }

    private fun waitIdle(r: CatalogRepository, min: Int) {
        val end = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < end) {
            val s = r.state.value
            if (s.phase == CatalogRepository.Phase.Ready && !s.isRefreshing && r.mergeCount >= min) { Thread.sleep(100); if (!r.state.value.isRefreshing) return }
            Thread.sleep(20)
        }
        throw AssertionError("repo never settled: ${r.state.value.phase}")
    }

    @Test fun allSourcesUnchangedSkipsMergeAndKeepsCatalogInstance() {
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        server.enqueue(MockResponse().setResponseCode(304))
        val r = repo()
        r.loadIfNeeded()
        waitIdle(r, 1)
        val catalog = r.state.value.catalog
        val merges = r.mergeCount
        r.refresh()
        val end = System.currentTimeMillis() + 10_000
        while (server.requestCount < 2 && System.currentTimeMillis() < end) Thread.sleep(20)
        Thread.sleep(300)
        waitIdle(r, merges)
        assertEquals(merges, r.mergeCount)
        assertSame(catalog, r.state.value.catalog)
    }

    @Test fun changedSourceMergesAndEmitsNewCatalog() {
        server.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"v1\""))
        server.enqueue(MockResponse().setBody(body.replace("\"s1\"", "\"s2\"")).setHeader("ETag", "\"v2\""))
        val r = repo()
        r.loadIfNeeded()
        waitIdle(r, 1)
        val catalog = r.state.value.catalog
        val merges = r.mergeCount
        r.refresh()
        val end = System.currentTimeMillis() + 10_000
        while (r.mergeCount == merges && System.currentTimeMillis() < end) Thread.sleep(20)
        waitIdle(r, merges + 1)
        assertEquals(merges + 1, r.mergeCount)
        assertTrue(r.state.value.catalog !== catalog)
    }
}
