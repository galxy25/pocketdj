package com.levi.pocketdj.data.jukebox

import android.content.ContextWrapper
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.playback.PlaybackController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** MIX-16: with a live mix the state POST carries the on-air deck track + the auto-queue tail. */
@OptIn(ExperimentalCoroutinesApi::class)
class JukeboxRepositoryMixTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var scope: CoroutineScope
    private val stateBodies = java.util.Collections.synchronizedList(mutableListOf<String>())

    private class FakeMix : MixJukeboxPort {
        override var autoMixing = true
        override var onAir: MixJukeboxPort.OnAir? = MixJukeboxPort.OnAir("on", "Deck Song", "Deck Artist", 5_000, 180_000, false)
        override var upcoming = listOf(MixLoadable("u1", "Tail One", "T1"))
        override var played = emptyList<MixLoadable>()
        override fun insert(item: AutoMixItem, action: JukeboxDecisionAction) {}
    }

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.path.orEmpty()
                    if (path.endsWith("/state")) stateBodies += request.body.readUtf8()
                    return when {
                        path == "/sessions/jb1" -> MockResponse().setBody("""{"jukeboxId":"jb1","hostKey":"hk","name":"N"}""")
                        path.contains("/requests") -> MockResponse().setBody("""{"seq":0,"requests":[]}""")
                        else -> MockResponse().setBody("{}")
                    }
                }
            }
            it.start()
        }
    }

    @After fun tearDown() {
        scope.cancel(); server.shutdown(); Dispatchers.resetMain()
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> bare(c: Class<T>): T {
        val f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").also { it.isAccessible = true }
        val u = f.get(null)
        return u.javaClass.getMethod("allocateInstance", Class::class.java).invoke(u, c) as T
    }

    @Test fun statePostCarriesOnAirDeckTrackAndAutoQueueTail() = runBlocking {
        val base = server.url("/").toString().removeSuffix("/")
        val client = JukeboxClient(OkHttpClient(), PdjJson.lenient) { JukeboxClient.Config(base, "tok", "install-1") }
        val store = JukeboxSessionStore(
            PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("s.preferences_pb").also { it.delete() } },
        )
        val mix = FakeMix()
        val source = MixJukeboxSource(port = { mix }, isLoadable = { true })
        val repo = JukeboxRepository(
            context = bare(ContextWrapper::class.java), client = client, sessionStore = store,
            catalog = bare(CatalogRepository::class.java), rips = bare(RipsRepository::class.java),
            playback = bare(PlaybackController::class.java), scope = scope, mixSource = { source },
        )
        repo.adopt("jb1")
        withTimeout(10_000) { while (stateBodies.isEmpty()) delay(20) }
        val body = stateBodies.first()
        assertTrue(body, body.contains("Deck Song"))
        assertTrue(body, body.contains("Deck Artist"))
        assertTrue(body, body.contains("Tail One"))
        assertTrue(body, body.contains("180000"))
        assertEquals(1, repo.state.value.upNextCount)
    }
}
