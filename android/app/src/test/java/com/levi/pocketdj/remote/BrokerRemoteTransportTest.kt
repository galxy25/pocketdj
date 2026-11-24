package com.levi.pocketdj.remote

import com.levi.pocketdj.data.jukebox.JukeboxUrls
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/** The broker client against a scripted MockWebServer relay (P2-REM-10). Real time + real IO threads, tiny delays. */
class BrokerRemoteTransportTest {
    private lateinit var server: MockWebServer
    private val scripts = ConcurrentHashMap<String, ConcurrentLinkedDeque<MockResponse>>()
    private val seen = CopyOnWriteArrayList<RecordedRequest>()
    private lateinit var scope: CoroutineScope

    private fun json(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)
    private fun script(op: String, vararg r: MockResponse) { scripts.getOrPut(op) { ConcurrentLinkedDeque() }.addAll(r) }
    private fun requests(op: String) = seen.filter { it.path!!.substringBefore('?').endsWith("/$op") || (op == "remote" && it.path == "/remote") }

    @Before fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    seen += request
                    val op = if (request.path == "/remote") "remote" else request.path!!.substringBefore('?').substringAfterLast('/')
                    // An idle poll parks briefly (a stand-in for the 25 s hold) instead of spinning.
                    val fallback = if (op == "poll") emptyPoll().setBodyDelay(80, TimeUnit.MILLISECONDS) else json("{}")
                    return scripts[op]?.pollFirst() ?: fallback
                }
            }
            it.start()
        }
    }

    @After fun tearDown() { scope.cancel(); server.shutdown() }

    private fun emptyPoll(rev: Long = 1, cursor: Long = 0, roster: String = """[{"id":"me","name":"Me"}]""") =
        json("""{"events":[],"roster":$roster,"rev":$rev,"cursor":$cursor,"dropped":false}""")

    private fun api(token: String = "") = BrokerApi(OkHttpClient(), { server.url("/").toString().removeSuffix("/") }, { token })
    private fun transport(maxFailures: Int = 3) = BrokerRemoteTransport(
        api(), "abcd2345", "me", "sekret", scope, maxPollFailures = maxFailures, backoffMs = { 10L }, log = {},
    )
    private fun env(kind: String = "state", payload: String = "e30=") = RemoteEnvelope(1, kind, payload)
    private fun <T> await(ms: Long = 5000, block: suspend () -> T): T = runBlocking { withTimeout(ms) { block() } }
    private fun body(r: RecordedRequest): JsonObject = Json.parseToJsonElement(r.body.readUtf8()).jsonObject

    // ---- URLs + API ----

    @Test fun urlsUseTheServerBaseAndFunnelMount() {
        assertEquals("http://h:8788/remote", JukeboxUrls.remoteCreate("http://h:8788/")?.toString())
        assertEquals("https://x.ts.net/jukebox/remote/abcd2345/send", JukeboxUrls.remoteRoom("https://x.ts.net/jukebox", "abcd2345", "send")?.toString())
        assertEquals("http://h/remote/abcd2345/poll?since=7&rev=-1", JukeboxUrls.remotePoll("http://h", "abcd2345", 7, -1)?.toString())
        assertNull(JukeboxUrls.remoteCreate("not a url"))
    }

    @Test fun createSendsTheAccountTokenAndTheModeAndParsesTheRoom() {
        script("remote", json("""{"roomId":"k7q2m9xa","joinCode":"K7Q2M9XA","hostSecret":"hs"}"""))
        val room = await { BrokerApi(OkHttpClient(), { server.url("/").toString().removeSuffix("/") }, { "acct" }).create(RemoteSessionMode.BACKSEAT) }
        assertEquals("k7q2m9xa", room.roomId); assertEquals("K7Q2M9XA", room.joinCode); assertEquals("hs", room.hostSecret)
        val r = seen.single()
        assertEquals("POST", r.method); assertEquals("Bearer acct", r.getHeader("Authorization"))
        assertEquals("backseat", body(r)["mode"]!!.jsonPrimitive.content)
    }

    @Test fun joinCarriesTheCodeOrTheHostSecret() {
        script("join", json("""{"participantId":"p1","secret":"s1","mode":"listenTogether","extra":1}"""), json("""{"participantId":"p2","secret":"s2"}"""))
        val guest = await { api().join("abcd2345", "p1", "Pixel", "ABCD2345", null) }
        assertEquals("s1", guest.secret); assertEquals(RemoteSessionMode.LISTEN_TOGETHER, BrokerApi.modeOf(guest.mode))
        val host = await { api().join("abcd2345", "p2", "Pixel", null, "hs") }
        assertNull(BrokerApi.modeOf(host.mode))
        val (g, h) = requests("join")
        assertEquals("ABCD2345", body(g)["joinCode"]!!.jsonPrimitive.content); assertNull(g.getHeader("Authorization"))
        assertEquals("Bearer hs", h.getHeader("Authorization")); assertFalse(body(h).containsKey("joinCode"))
    }

    @Test fun sendPutsTheEnvelopeAsAnObjectWithTheRecipient() {
        await { api().send("abcd2345", "sek", RemoteRecipient.Participant("peer"), false, env("ping", "QQ==")) }
        val b = body(seen.single())
        assertEquals("peer", b["to"]!!.jsonPrimitive.content)
        assertFalse(b["reliable"]!!.jsonPrimitive.boolean)
        val e = b["env"]!!.jsonObject
        assertEquals("1", e["v"]!!.jsonPrimitive.content); assertEquals("ping", e["kind"]!!.jsonPrimitive.content); assertEquals("QQ==", e["payload"]!!.jsonPrimitive.content)
        assertEquals("Bearer sek", seen.single().getHeader("Authorization"))
    }

    @Test fun nonSuccessIsABrokerHttpExceptionAndGoneStatusesAreFlagged() {
        script("poll", json("""{"error":"x"}""", 410), json("""{"error":"y"}""", 500))
        val gone = runCatching { await { api().poll("abcd2345", "s", 0, -1) } }.exceptionOrNull() as BrokerHttpException
        assertEquals(410, gone.status); assertTrue(gone.isGone)
        val err = runCatching { await { api().poll("abcd2345", "s", 0, -1) } }.exceptionOrNull() as BrokerHttpException
        assertFalse(err.isGone)
    }

    // ---- Transport ----

    @Test fun pollDeliversEventsInSeqOrderWithTheServerStampedSender() {
        script(
            "poll",
            json(
                """{"events":[{"seq":3,"from":"b","to":"all","env":{"v":1,"kind":"state","payload":"Mg=="}},
                   {"seq":2,"from":"a","to":"me","reliable":false,"env":{"v":1,"kind":"ping","payload":"MQ=="}}],
                   "roster":[{"id":"me","name":"M"},{"id":"a","name":"A"},{"id":"b"}],"rev":4,"cursor":3,"dropped":false}""",
            ),
        )
        val t = transport(); t.start()
        val got = await { val l = ArrayList<RemoteInbound>(); t.inbound.first { l += it; l.size == 2 }; l }
        assertEquals(listOf("a" to "ping", "b" to "state"), got.map { it.from to it.envelope.kind })
        assertEquals(setOf("me", "a", "b"), await { t.participants.first { it.size == 3 } })
        t.leave()
    }

    @Test fun theNextPollResumesFromTheCursorAndRevision() {
        script("poll", emptyPoll(rev = 4, cursor = 9))
        val t = transport(); t.start()
        await { while (requests("poll").size < 2) kotlinx.coroutines.delay(10) }
        val (first, second) = requests("poll")
        assertTrue(first.path!!.contains("since=0") && first.path!!.contains("rev=-1"))
        assertTrue(second.path!!.contains("since=9") && second.path!!.contains("rev=4"))
        assertEquals("Bearer sekret", second.getHeader("Authorization"))
        t.leave()
    }

    @Test fun aGonePollEndsTheSession() {
        script("poll", json("""{"error":"left"}""", 410))
        val t = transport(); t.start()
        await { t.participants.first { it.isEmpty() } }
        assertEquals(emptyList<RemoteInbound>(), await { t.inbound.toList() }) // the inbound flow completes
    }

    @Test fun transientPollFailuresBackOffAndRecover() {
        script(
            "poll", json("{}", 500), json("{}", 503),
            json("""{"events":[{"seq":1,"from":"a","env":{"v":1,"kind":"state","payload":"e30="}}],"roster":[{"id":"me"},{"id":"a"}],"rev":2,"cursor":1}"""),
        )
        val t = transport(maxFailures = 4); t.start()
        assertEquals("a", await { t.inbound.first().from })
        assertTrue(t.participants.value.isNotEmpty())
        t.leave()
    }

    @Test fun exhaustingTheFailureBudgetEndsTheSession() {
        script("poll", json("{}", 500), json("{}", 500), json("{}", 500))
        val t = transport(maxFailures = 3); t.start()
        await { t.participants.first { it.isEmpty() } }
    }

    @Test fun sendsPostInOrderOneAtATime() {
        val t = transport(); t.start()
        (1..4).forEach { t.send(env("m$it"), RemoteRecipient.All, reliable = true) }
        await { while (requests("send").size < 4) kotlinx.coroutines.delay(10) }
        assertEquals(listOf("m1", "m2", "m3", "m4"), requests("send").map { body(it)["env"]!!.jsonObject["kind"]!!.jsonPrimitive.content })
        t.leave()
    }

    @Test fun aReliableSendRetriesATransientFailureButAnUnreliableOneDoesNot() {
        script("send", json("{}", 502), json("{}", 502))
        val t = transport(); t.start()
        t.send(env("ping"), RemoteRecipient.All, reliable = false) // consumes the first 502, never retried
        t.send(env("state"), RemoteRecipient.All, reliable = true)  // consumes the second 502, retried once
        await { while (requests("send").size < 3) kotlinx.coroutines.delay(10) }
        assertEquals(listOf("ping", "state", "state"), requests("send").map { body(it)["env"]!!.jsonObject["kind"]!!.jsonPrimitive.content })
        t.leave()
    }

    @Test fun aRejectedSendIsNotRetried() {
        script("send", json("""{"error":"bad envelope"}""", 400))
        val t = transport(); t.start()
        t.send(env("junk"), RemoteRecipient.All, reliable = true)
        t.send(env("good"), RemoteRecipient.All, reliable = true)
        await { while (requests("send").size < 2) kotlinx.coroutines.delay(10) }
        assertEquals(listOf("junk", "good"), requests("send").map { body(it)["env"]!!.jsonObject["kind"]!!.jsonPrimitive.content })
        t.leave()
    }

    @Test fun leaveTellsTheServerAndStopsEverything() {
        val t = transport(); t.start()
        t.leave()
        await { while (requests("leave").isEmpty()) kotlinx.coroutines.delay(10) }
        assertEquals("Bearer sekret", requests("leave").single().getHeader("Authorization"))
        assertTrue(t.participants.value.isEmpty())
        val before = requests("send").size
        t.send(env(), RemoteRecipient.All, reliable = true)
        Thread.sleep(150)
        assertEquals(before, requests("send").size)
        t.leave() // idempotent
        Thread.sleep(50)
        assertEquals(1, requests("leave").size)
    }

    @Test fun theStateCapFitsUnderTheServersBodyLimit() {
        val t = transport()
        assertTrue(t.maxStateBytes < 64 * 1024 - 1024)
        assertEquals(setOf("me"), t.participants.value) // seated as soon as we have a transport
    }

    // ---- Starter ----

    private fun starter(controller: RemoteSessionController, configured: Boolean = true) =
        BrokerRemoteStarter(controller, scope, api(), { configured }, { "Pixel" }, log = {}, newParticipantId = { "me" })

    private fun controller() = RemoteSessionController(
        target = InMemoryRemoteTarget { 1_000_000.0 }, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
        deviceName = { "Pixel" }, platform = "test", clock = SharedClock { 1_000_000.0 }, scope = scope,
    )

    @Test fun startCreatesJoinsAsCreatorAndAttachesAsHost() {
        script("remote", json("""{"roomId":"k7q2m9xa","joinCode":"K7Q2M9XA","hostSecret":"hs"}"""))
        script("join", json("""{"participantId":"me","secret":"s1"}"""))
        val c = controller(); val s = starter(c)
        val out = await { s.start(RemoteSessionMode.LISTEN_TOGETHER) } as com.levi.pocketdj.screens.remote.StartOutcome.Started
        assertEquals("K7Q2M9XA", out.invite!!.code); assertEquals("pocketdj://remote/join/K7Q2M9XA", out.invite!!.url)
        assertEquals(out.invite, s.invite.value)
        assertTrue(c.isActive.value); assertTrue(c.isHost)
        assertEquals("Bearer hs", requests("join").single().getHeader("Authorization"))
        c.leave()
        s.clearInvite(); assertNull(s.invite.value)
    }

    @Test fun joinByCodeAddressesTheLowerCasedRoomAndTakesTheHostsMode() {
        script("join", json("""{"participantId":"me","secret":"s1","mode":"backseat"}"""))
        val c = controller(); val s = starter(c)
        val out = await { s.joinWithCode("k7q2m9xa") }
        assertEquals(com.levi.pocketdj.screens.remote.JoinOutcome.Joined, out)
        assertEquals("/remote/k7q2m9xa/join", requests("join").single().path)
        assertEquals("K7Q2M9XA", body(requests("join").single())["joinCode"]!!.jsonPrimitive.content)
        assertEquals(RemoteSessionMode.BACKSEAT, c.mode.value)
        assertFalse(c.isHost)
        c.leave()
    }

    @Test fun joinFailuresAreFriendlyAndLeaveNothingAttached() {
        script("join", json("""{"error":"bad code"}""", 401))
        val c = controller(); val s = starter(c)
        val out = await { s.joinWithCode("ABCD2345") } as com.levi.pocketdj.screens.remote.JoinOutcome.Failed
        assertTrue(out.message.contains("code"))
        assertFalse(c.isActive.value)
        val bad = await { s.joinWithCode("!!") } as com.levi.pocketdj.screens.remote.JoinOutcome.Failed
        assertTrue(bad.message.contains("session code"))
    }

    @Test fun withoutAServerTheStarterIsUnavailableAndRefuses() {
        val s = starter(controller(), configured = false)
        assertFalse(s.available)
        assertTrue(await { s.start(RemoteSessionMode.LISTEN_TOGETHER) } is com.levi.pocketdj.screens.remote.StartOutcome.Failed)
        assertTrue(await { s.joinWithCode("ABCD2345") } is com.levi.pocketdj.screens.remote.JoinOutcome.Failed)
        assertTrue(seen.isEmpty())
    }

    @Test fun friendlyMessagesCoverTheServersStatuses() {
        fun msg(code: Int) = BrokerRemoteStarter.friendly(BrokerHttpException(code, ""))
        assertTrue(msg(404).contains("wasn't found")); assertTrue(msg(403).contains("full")); assertTrue(msg(429).contains("Too many"))
        assertTrue(msg(503).contains("too many sessions")); assertTrue(msg(418).contains("418"))
        assertTrue(BrokerRemoteStarter.friendly(java.io.IOException("x")).contains("reach"))
        assertNotNull(BrokerApi.wire(RemoteSessionMode.LISTEN_TOGETHER))
    }
}
