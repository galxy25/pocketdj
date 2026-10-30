package com.levi.pocketdj.data.jukebox

import android.content.ContextWrapper
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.CatalogService
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.rips.RipsRepository
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.SourceConfig
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlaybackController
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerState
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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

/** SURF-10: accepting an Apple-Music-only match requests the rip first, then places once it lands. */
@OptIn(ExperimentalCoroutinesApi::class)
class JukeboxRepositoryAdHocRipTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var scope: CoroutineScope
    private val decisions = java.util.Collections.synchronizedList(mutableListOf<String>())
    private val song = IndexSong(id = "amrec_77", artist = "Guest Artist", name = "Guest Song", appleMusicId = "77")

    private class FakeQueue : JukeboxQueue {
        val calls = java.util.Collections.synchronizedList(mutableListOf<String>())
        override val isRunning = true
        override fun snapshot() = SequencerState()
        override fun insertNext(item: QueueItem) { calls += "next:${item.id}" }
        override fun append(item: QueueItem) { calls += "end:${item.id}" }
        override fun insertRandom(item: QueueItem, slot: (IntRange) -> Int) { calls += "random:${item.id}" }
        override fun adoptForeign(current: QueueItem, positionMs: Long, context: PlayContext) {}
        override fun startRun(item: QueueItem, context: PlayContext) { calls += "start:${item.id}" }
    }

    private class FakeMix : MixJukeboxPort {
        @Volatile override var autoMixing = false
        override val onAir: MixJukeboxPort.OnAir? = null
        override val upcoming = emptyList<MixLoadable>()
        override val played = emptyList<MixLoadable>()
        override fun insert(item: AutoMixItem, action: JukeboxDecisionAction) {}
    }

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val served = AtomicBoolean(false)
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.path.orEmpty()
                    return when {
                        path == "/sessions/jb1" -> MockResponse().setBody("""{"jukeboxId":"jb1","hostKey":"hk","name":"N"}""")
                        path == "/cat.json" -> MockResponse().setBody("""{"manifest":{"sourceName":"A"},"albums":[],"songs":[]}""")
                        path.contains("/decide") -> { decisions += path; MockResponse().setBody("{}") }
                        path.contains("/requests") ->
                            if (served.compareAndSet(false, true)) {
                                MockResponse().setBody(
                                    """{"seq":1,"requests":[{"id":"r1","seq":1,"title":"Guest Song","artist":"Guest Artist","status":"pending"}]}""",
                                )
                            } else {
                                MockResponse().setBody("""{"seq":1,"requests":[]}""")
                            }
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

    /** A controller shell whose only live member is an idle nowPlaying (what the sequencer path reads). */
    private fun idlePlayback(): PlaybackController {
        val pc = bare(PlaybackController::class.java)
        PlaybackController::class.java.getDeclaredField("nowPlaying").also { it.isAccessible = true }
            .set(pc, kotlinx.coroutines.flow.MutableStateFlow<Any?>(null))
        return pc
    }

    private class Harness(
        val repo: JukeboxRepository,
        val queue: FakeQueue,
        val playable: AtomicBoolean,
        val starts: AtomicInteger,
    )

    private fun harness(
        starterResult: Boolean,
        mix: MixJukeboxSource? = null,
    ): Harness {
        val base = server.url("/").toString().removeSuffix("/")
        val client = JukeboxClient(OkHttpClient(), PdjJson.lenient) { JukeboxClient.Config(base, "tok", "install-1") }
        val store = JukeboxSessionStore(
            PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("s.preferences_pb").also { it.delete() } },
        )
        val settings = AppSettingsStore(
            PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("a.preferences_pb").also { it.delete() } },
        )
        runBlocking { settings.setSources(listOf(SourceConfig("a", "A", server.url("/cat.json").toString()))) }
        val catalog = CatalogRepository(CatalogService(tmp.newFolder(), OkHttpClient()), settings, scope)
        val playable = AtomicBoolean(false)
        val starts = AtomicInteger(0)
        val queue = FakeQueue()
        val repo = JukeboxRepository(
            context = bare(ContextWrapper::class.java), client = client, sessionStore = store,
            catalog = catalog, rips = bare(RipsRepository::class.java),
            playback = idlePlayback(), scope = scope,
            mixSource = { mix }, ripPlayable = { playable.get() },
        )
        repo.queue = queue
        repo.externalMatch = JukeboxExternalMatch { _, _ -> song }
        repo.placementSink = JukeboxAmPlacementSink(isPlayable = { playable.get() }, waitMs = 10_000, pollMs = 20)
        repo.adHocRipStarter = JukeboxAdHocRipStarter { starts.incrementAndGet(); starterResult }
        return Harness(repo, queue, playable, starts)
    }

    private suspend fun awaitRow(h: Harness) {
        h.repo.adopt("jb1")
        withTimeout(10_000) {
            while (h.repo.state.value.requests.firstOrNull()?.match !is JukeboxRepository.Match.Found) delay(20)
        }
    }

    @Test fun amOnlyMatchIsFlaggedAdHocAndPlayable() = runBlocking {
        val h = harness(true)
        awaitRow(h)
        val found = h.repo.state.value.requests.single().match as JukeboxRepository.Match.Found
        assertTrue(found.isAdHoc)
        assertTrue(found.playable)
    }

    @Test fun noRipServerKeepsTheRowAndQueuesNothing() = runBlocking {
        val h = harness(starterResult = false)
        awaitRow(h)
        h.repo.decide("r1", JukeboxDecisionAction.NEXT)
        withTimeout(10_000) { while (h.repo.state.value.transientError == null) delay(20) }
        assertTrue(h.repo.state.value.transientError!!.contains("Couldn't start the rip"))
        assertEquals(1, h.starts.get())
        assertEquals("row stays so the host can retry", 1, h.repo.state.value.requests.size)
        assertTrue(h.queue.calls.isEmpty())
        assertTrue("no decision posted for a request that could not be fulfilled", decisions.isEmpty())
    }

    @Test fun placesOnlyAfterTheRipLands() = runBlocking {
        val h = harness(starterResult = true)
        awaitRow(h)
        h.repo.decide("r1", JukeboxDecisionAction.NEXT)
        withTimeout(10_000) { while (h.repo.state.value.requests.isNotEmpty()) delay(20) }
        delay(200)
        assertEquals(1, h.starts.get())
        assertTrue("nothing queued while the rip is in flight", h.queue.calls.isEmpty())
        h.playable.set(true)
        try {
            withTimeout(10_000) { while (h.queue.calls.isEmpty()) delay(20) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("not placed; state=${h.repo.state.value}")
        }
        assertEquals(listOf("next:amrec_77"), h.queue.calls.toList())
    }

    @Test fun mixStartedDuringTheRipWaitTakesThePlacementNotTheSequencer() = runBlocking {
        val port = FakeMix()
        val burns = AtomicInteger(0)
        val mix = MixJukeboxSource(port = { port }, isLoadable = { false }, requestBurn = { burns.incrementAndGet() })
        val h = harness(starterResult = true, mix = mix)
        awaitRow(h)
        h.repo.decide("r1", JukeboxDecisionAction.NEXT)
        withTimeout(10_000) { while (h.repo.state.value.requests.isNotEmpty()) delay(20) }
        port.autoMixing = true // host starts Auto-Mix while the rip is in flight
        h.playable.set(true)
        withTimeout(10_000) { while (mix.pendingCount == 0) delay(20) }
        assertTrue("sequencer must not sound on top of the live mix", h.queue.calls.isEmpty())
        assertEquals("parked behind a burn", 1, burns.get())
    }
}
