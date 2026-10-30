package com.levi.pocketdj.data.jukebox

import android.content.ContextWrapper
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.playback.PlaybackController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Repository-level adopt / commit-race / seam-failure tests (SURF-10 review). */
class JukeboxRepositoryAdoptTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var scope: CoroutineScope
    private lateinit var store: JukeboxSessionStore
    private lateinit var client: JukeboxClient
    private val requestLog = java.util.Collections.synchronizedList(mutableListOf<String>())

    @Before fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requestLog += request.path.orEmpty()
                    val path = request.path.orEmpty()
                    return when {
                        path == "/sessions/jbNew" ->
                            MockResponse().setBody("""{"jukeboxId":"jbNew","hostKey":"hk","name":"N"}""")
                        path == "/sessions/jbOld" ->
                            MockResponse().setBody("{\"jukeboxId\":\"jbOld\",\"hostKey\":\"ho\",\"name\":\"O\"}")
                        path.startsWith("/sessions/missing") -> MockResponse().setResponseCode(404)
                        path.contains("/requests") -> MockResponse().setBody("""{"seq":0,"requests":[]}""")
                        else -> MockResponse().setBody("{}")
                    }
                }
            }
            it.start()
        }
        val base = server.url("/").toString().removeSuffix("/")
        client = JukeboxClient(
            http = OkHttpClient(),
            json = PdjJson.lenient,
            configProvider = { JukeboxClient.Config(base, "tok", "install-1") },
        )
        store = JukeboxSessionStore(
            PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("s.preferences_pb").also { it.delete() } },
        )
    }

    @After fun tearDown() {
        scope.cancel()
        server.shutdown()
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> bare(c: Class<T>): T {
        val f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").also { it.isAccessible = true }
        val u = f.get(null)
        return u.javaClass.getMethod("allocateInstance", Class::class.java).invoke(u, c) as T
    }

    private fun repo(): JukeboxRepository = JukeboxRepository(
        context = bare(ContextWrapper::class.java),
        client = client,
        sessionStore = store,
        catalog = bare(CatalogRepository::class.java),
        rips = bare(RipsRepository::class.java),
        playback = bare(PlaybackController::class.java),
        scope = scope,
    )

    private suspend fun JukeboxRepository.await(what: String, cond: (JukeboxRepository.UiState) -> Boolean) {
        withTimeout(10_000) { while (!cond(state.value)) delay(20) }
    }

    @Test fun adopt_persists_forcesHearOff_pollsFromZero() = runBlocking {
        store.setHear(true)
        val r = repo()
        r.adopt("jbNew")
        r.await("session") { it.session?.jukeboxId == "jbNew" }
        assertFalse(r.state.value.hear)
        assertFalse(r.state.value.starting)
        assertEquals("jbNew", store.load()?.session?.jukeboxId)
        assertFalse(store.load()!!.hear)
        withTimeout(10_000) { while (requestLog.none { it.contains("/jukebox/jbNew/requests") }) delay(20) }
        val poll = requestLog.first { it.contains("/jukebox/jbNew/requests") }
        assertTrue(poll, poll.contains("since=0"))
    }

    @Test fun adopt_404_clearsStarting_setsNotice_noSession() = runBlocking {
        val r = repo()
        r.adopt("missing")
        r.await("notice") { it.notice != null }
        assertFalse(r.state.value.starting)
        assertNull(r.state.value.session)
        assertNull(store.load())
    }

    @Test fun adopt_refusedWhenDifferentSessionActive() = runBlocking {
        val r = repo()
        r.adopt("jbNew")
        r.await("session") { it.session != null }
        val before = requestLog.count { it == "/sessions/other" }
        r.adopt("other")
        delay(300)
        assertEquals("jbNew", r.state.value.session?.jukeboxId)
        assertEquals(before, requestLog.count { it == "/sessions/other" })
    }

    @Test fun switchTo_endsOldBeforeAdoptingTarget_andCommitsTarget() = runBlocking {
        val r = repo()
        r.adopt("jbOld")
        r.await("old") { it.session?.jukeboxId == "jbOld" }
        requestLog.clear()
        r.switchTo("jbNew")
        r.await("new") { it.session?.jukeboxId == "jbNew" && !it.starting }
        assertEquals("jbNew", store.load()?.session?.jukeboxId)
        val endIdx = requestLog.indexOfFirst { it.contains("/end") }
        val adoptIdx = requestLog.indexOf("/sessions/jbNew")
        assertTrue(requestLog.toString(), endIdx in 0 until adoptIdx)
    }

    @Test fun switchTo_completesEvenIfCallerScopeIsCancelled() = runBlocking {
        val r = repo()
        r.adopt("jbOld")
        r.await("old") { it.session?.jukeboxId == "jbOld" }
        // Simulates the sheet leaving composition right after the tap.
        val sheetScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        sheetScope.launch { r.switchTo("jbNew") }.join()
        sheetScope.cancel()
        r.await("new") { it.session?.jukeboxId == "jbNew" && !it.starting }
        assertEquals("jbNew", store.load()?.session?.jukeboxId)
    }

    @Test fun bootstrapRestoreDuringAdopt_isNotOverwrittenByStart_orAdoptKeepsRestoredWhenDifferent() = runBlocking {
        // Persisted session X; adopt(jbNew) is in flight (starting=true) when bootstrap runs.
        store.save(JukeboxSessionInfo(jukeboxId = "X", hostKey = "hx"))
        val r = repo()
        r.adopt("jbNew")
        r.bootstrap()
        r.await("settled") { it.session != null && !it.starting }
        // Exactly one session wins and the persisted copy matches the live one.
        assertEquals(r.state.value.session?.jukeboxId, store.load()?.session?.jukeboxId)
    }

    @Test fun endAndAwait_endsAPersistedSessionThisProcessNeverOpened() = runBlocking {
        store.save(JukeboxSessionInfo(jukeboxId = "X", hostKey = "hx"))
        val r = repo()
        r.endAndAwait()
        assertNull(store.load())
        assertNull(r.state.value.session)
        assertTrue(requestLog.toString(), requestLog.any { it.contains("/X") })
    }
}
