package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.games.inthepocket.InThePocketRoundWire
import com.levi.pocketdj.data.history.PlayHistoryStore
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

/** A pockets backend: records POST /pockets/events bodies, answers results/state, with knobs. */
class FakePocketsBackend : Dispatcher() {
    val eventPosts = CopyOnWriteArrayList<JsonObject>()
    val requests = CopyOnWriteArrayList<String>()
    @Volatile var eventsCode = 200
    @Volatile var eventsDelayMs = 0L
    @Volatile var resultsCode = 200
    @Volatile var deleteCode = 200
    @Volatile var deleteDelayMs = 0L

    override fun dispatch(request: RecordedRequest): MockResponse {
        requests += "${request.method} ${request.path}"
        return when {
            request.path == "/pockets/events" -> {
                eventPosts += Json.parseToJsonElement(request.body.readUtf8()).jsonObject
                MockResponse().setResponseCode(eventsCode).setBody("""{"ok":true}""").also {
                    if (eventsDelayMs > 0) it.setHeadersDelay(eventsDelayMs, java.util.concurrent.TimeUnit.MILLISECONDS)
                }
            }
            request.path == "/pockets/results" -> MockResponse().setResponseCode(resultsCode).setBody("""{"v":1,"generatedAtMs":5}""")
            request.path == "/pockets/state" -> MockResponse().setResponseCode(deleteCode).setBody("{}").also {
                if (deleteDelayMs > 0) it.setHeadersDelay(deleteDelayMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
            else -> MockResponse().setResponseCode(500)
        }
    }

    fun eventCount(): Int = requests.count { it == "POST /pockets/events" }
    fun resultsCount(): Int = requests.count { it == "GET /pockets/results" }
    fun events(i: Int) = eventPosts[i]["events"]!!.let { (it as kotlinx.serialization.json.JsonArray).map { e -> e.jsonObject } }
}

class PocketsFixture(tmp: File) {
    val backend = FakePocketsBackend()
    val server = MockWebServer().also { it.dispatcher = backend; it.start() }
    val history = PlayHistoryStore(File(tmp, "h.json"), PdjJson.lenient)
    val syncFile = File(tmp, "sync.json")
    val cacheFile = File(tmp, "cache.json")
    @Volatile var clock = 1_750_000_000_000L
    @Volatile var recOn = true
    @Volatile var pocketsOn = true
    @Volatile var creds: PocketsCredentials? = PocketsCredentials("KEY", "prof-A", "ENR")
    val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    fun service(provider: com.levi.pocketdj.data.location.ListeningContextProviding =
        com.levi.pocketdj.data.location.NoopListeningContextProvider) = ListeningPocketsService(
        history = history,
        client = ListeningPocketsClient(okhttp3.OkHttpClient(), { server.url("/").toString() }, { "DEV" }),
        credentials = { creds }, recEngineEnabled = { recOn }, pocketsEnabled = { pocketsOn },
        scope = scope, syncFile = syncFile, cacheFile = cacheFile, provider = provider,
        now = { clock }, deviceId = { "DEV" },
    )

    /** Record [n] distinct-song plays a minute apart ending shortly before [clock]. */
    fun plays(n: Int, prefix: String = "s") = (0 until n).map {
        history.record("$prefix$it", nowMs = clock - (n - it) * 120_000L, tzOffsetMin = 0)!!
    }

    fun close() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); server.shutdown() }
}

fun testRoundWire(id: String = "r1") = InThePocketRoundWire(
    id = id, originInstallId = "inst", startedAtMs = 1_750_000_000_000L, endedAtMs = null, updatedAtMs = 1_750_000_000_000L,
    tzOffsetMin = 0, context = InThePocketRoundWire.Context("morning", "weekday", 1, null), mode = "local", seed = "s",
    algoVersion = 1, targets = emptyList(), songs = emptyList(), outcome = "pending", brokeAt = null, rating = null,
    feedback = null, appVersion = null,
)
