package com.levi.pocketdj.remote

import com.levi.pocketdj.data.jukebox.JukeboxUrls
import com.levi.pocketdj.diag.NPLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// ---- Wire bodies of the jukebox server's `/remote` long-poll relay (scripts/jukebox-server.mjs). Lenient on read. ----

@Serializable data class BrokerCreated(val roomId: String, val joinCode: String, val hostSecret: String)
@Serializable data class BrokerJoined(val participantId: String, val secret: String, val mode: String? = null)
@Serializable data class BrokerRosterEntry(val id: String, val name: String = "")
@Serializable data class BrokerEvent(val seq: Long, val from: String, val to: String = "all", val reliable: Boolean = true, val env: RemoteEnvelope)
@Serializable data class BrokerPoll(
    val events: List<BrokerEvent> = emptyList(), val roster: List<BrokerRosterEntry> = emptyList(),
    val rev: Long = 0, val cursor: Long = 0, val dropped: Boolean = false,
)

/** A non-2xx broker answer. 401/404/410 mean the room or our seat is gone (not retryable). */
class BrokerHttpException(val status: Int, message: String) : IOException("broker $status: $message") {
    val isGone: Boolean get() = status == 401 || status == 404 || status == 410
}

/** The relay's HTTP surface. Suspend functions over OkHttp (cancelling the coroutine cancels the call). */
class BrokerApi(client: OkHttpClient, private val baseUrl: () -> String, private val accountToken: () -> String = { "" }) {
    private val http: OkHttpClient = client.newBuilder().callTimeout(0, TimeUnit.MILLISECONDS).build()
    /** Long-poll client: server holds a poll for [POLL_SECONDS]; allow a margin. */
    private val pollHttp: OkHttpClient = http.newBuilder().readTimeout(POLL_SECONDS + 12, TimeUnit.SECONDS).build()
    private val sendHttp: OkHttpClient = http.newBuilder().readTimeout(15, TimeUnit.SECONDS).build()
    private val json = RemoteWire.json
    private val media = "application/json".toMediaType()

    suspend fun create(mode: RemoteSessionMode): BrokerCreated {
        val url = JukeboxUrls.remoteCreate(baseUrl()) ?: throw IOException("bad jukebox server url")
        val body = buildJsonObject { put("mode", wire(mode)) }.toString()
        val b = Request.Builder().url(url).post(body.toRequestBody(media))
        accountToken().takeIf { it.isNotBlank() }?.let { b.header("Authorization", "Bearer $it") }
        return json.decodeFromString(BrokerCreated.serializer(), execute(sendHttp, b.build()))
    }

    /** Join with the invite [joinCode], or as the room's creator with [hostSecret]. */
    suspend fun join(roomId: String, participantId: String, name: String, joinCode: String?, hostSecret: String?): BrokerJoined {
        val url = JukeboxUrls.remoteRoom(baseUrl(), roomId, "join") ?: throw IOException("bad jukebox server url")
        val body = buildJsonObject {
            put("participantId", participantId); put("name", name)
            if (joinCode != null) put("joinCode", joinCode)
        }.toString()
        val b = Request.Builder().url(url).post(body.toRequestBody(media))
        if (hostSecret != null) b.header("Authorization", "Bearer $hostSecret")
        return json.decodeFromString(BrokerJoined.serializer(), execute(sendHttp, b.build()))
    }

    suspend fun send(roomId: String, secret: String, to: RemoteRecipient, reliable: Boolean, envelope: RemoteEnvelope) {
        val url = JukeboxUrls.remoteRoom(baseUrl(), roomId, "send") ?: throw IOException("bad jukebox server url")
        val body = buildJsonObject {
            put("to", when (to) { RemoteRecipient.All -> "all"; is RemoteRecipient.Participant -> to.id })
            put("reliable", reliable)
            put("env", json.encodeToJsonElement(RemoteEnvelope.serializer(), envelope))
        }.toString()
        execute(sendHttp, Request.Builder().url(url).header("Authorization", "Bearer $secret").post(body.toRequestBody(media)).build())
    }

    suspend fun poll(roomId: String, secret: String, since: Long, rev: Long): BrokerPoll {
        val url = JukeboxUrls.remotePoll(baseUrl(), roomId, since, rev) ?: throw IOException("bad jukebox server url")
        return json.decodeFromString(BrokerPoll.serializer(), execute(pollHttp, Request.Builder().url(url).header("Authorization", "Bearer $secret").get().build()))
    }

    suspend fun leave(roomId: String, secret: String) {
        val url = JukeboxUrls.remoteRoom(baseUrl(), roomId, "leave") ?: return
        execute(sendHttp, Request.Builder().url(url).header("Authorization", "Bearer $secret").post("{}".toRequestBody(media)).build())
    }

    private suspend fun execute(client: OkHttpClient, request: Request): String = withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { if (cont.isActive) cont.resumeWithException(e) }
                override fun onResponse(call: Call, response: Response) {
                    response.use { r ->
                        val text = try { r.body?.string().orEmpty() } catch (e: IOException) { if (cont.isActive) cont.resumeWithException(e); return }
                        if (!cont.isActive) return
                        if (r.isSuccessful) cont.resume(text) else cont.resumeWithException(BrokerHttpException(r.code, text.take(120)))
                    }
                }
            })
        }
    }

    companion object {
        const val POLL_SECONDS = 25L
        fun wire(mode: RemoteSessionMode): String = when (mode) {
            RemoteSessionMode.LISTEN_TOGETHER -> "listenTogether"
            RemoteSessionMode.BACKSEAT -> "backseat"
        }
        fun modeOf(wire: String?): RemoteSessionMode? = when (wire) {
            "listenTogether" -> RemoteSessionMode.LISTEN_TOGETHER
            "backseat" -> RemoteSessionMode.BACKSEAT
            else -> null
        }
    }
}

/**
 * [RemoteTransport] over the jukebox server's `/remote` relay (P2-REM-10): HTTP long-poll in, ordered POSTs out. The
 * server never reads an envelope; it stamps the sender and fans out, never echoing to the sender. Participant ids are
 * the per-session UUIDs we choose at join (they order the hand-over election, as on Nearby).
 *
 * Failure model: transient errors back off and retry; 401/404/410 (room gone, our seat swept) or [maxPollFailures]
 * consecutive failures end the session (the controller sees an empty roster). A `dropped` poll (the server's ring
 * buffer evicted events we hadn't read) is logged; the controller's state re-request recovers the queue.
 */
class BrokerRemoteTransport(
    private val api: BrokerApi,
    private val roomId: String,
    override val localParticipantId: String,
    private val secret: String,
    private val scope: CoroutineScope,
    private val maxPollFailures: Int = 6,
    private val backoffMs: (attempt: Int) -> Long = { minOf(500L shl (it - 1).coerceIn(0, 4), 8_000L) },
    private val log: (String) -> Unit = { NPLog.lane(NPLog.REMOTE, it) },
) : RemoteTransport {
    private val inboundChannel = Channel<RemoteInbound>(Channel.UNLIMITED)
    private val roster = MutableStateFlow(setOf(localParticipantId))
    private val outbox = Channel<Outgoing>(Channel.UNLIMITED)
    private var pollJob: Job? = null
    private var sendJob: Job? = null
    @Volatile private var finished = false

    override val inbound: Flow<RemoteInbound> = inboundChannel.receiveAsFlow()
    override val participants: StateFlow<Set<String>> = roster

    /** Under the server's 64 KB body cap with the JSON wrapper to spare (window halving fits the rest). */
    override val maxStateBytes: Int = MAX_STATE_BYTES

    private class Outgoing(val envelope: RemoteEnvelope, val to: RemoteRecipient, val reliable: Boolean)

    /** Begin polling and sending. Call once, after the join. */
    fun start() {
        pollJob = scope.launch { pollLoop() }
        sendJob = scope.launch { sendLoop() }
    }

    override fun send(envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Boolean) {
        if (finished) return
        outbox.trySend(Outgoing(envelope, to, reliable))
    }

    override fun leave() {
        if (finished) return
        finish()
        // Best effort, outside the loops we just cancelled: the server's TTL sweep covers a lost request.
        scope.launch { runCatching { api.leave(roomId, secret) } }
    }

    private suspend fun pollLoop() {
        var since = 0L
        var rev = -1L
        var failures = 0
        while (!finished) {
            try {
                val p = api.poll(roomId, secret, since, rev)
                failures = 0
                if (finished) return
                if (p.dropped) log("broker: poll lagged the ring buffer; some messages were lost")
                since = maxOf(since, p.cursor)
                rev = p.rev
                for (e in p.events.sortedBy { it.seq }) inboundChannel.trySend(RemoteInbound(e.env, e.from))
                val ids = p.roster.map { it.id }.toSet()
                if (ids.isNotEmpty() && ids != roster.value) roster.value = ids
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (finished) return
                if (e is BrokerHttpException && e.isGone) { log("broker: session gone (${e.status})"); finish(); return }
                failures++
                log("broker: poll failed #$failures: ${e.message}")
                if (failures >= maxPollFailures) { finish(); return }
                delay(backoffMs(failures))
            }
        }
    }

    private suspend fun sendLoop() {
        for (m in outbox) {
            if (finished) return
            var attempt = 0
            while (!finished) {
                try {
                    api.send(roomId, secret, m.to, m.reliable, m.envelope)
                    break
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (e is BrokerHttpException && e.isGone) { finish(); return }
                    // A bad request is our bug, not the network's: retrying can't help. Unreliable messages are never retried.
                    val retryable = m.reliable && !(e is BrokerHttpException && e.status in 400..499)
                    attempt++
                    if (!retryable || attempt >= SEND_ATTEMPTS) { log("broker: dropped a ${m.envelope.kind}: ${e.message}"); break }
                    delay(backoffMs(attempt))
                }
            }
        }
    }

    private fun finish() {
        if (finished) return
        finished = true
        pollJob?.cancel(); sendJob?.cancel()
        outbox.close()
        inboundChannel.close()
        roster.value = emptySet()
    }

    companion object {
        const val MAX_STATE_BYTES = 48_000
        const val SEND_ATTEMPTS = 3
    }
}
