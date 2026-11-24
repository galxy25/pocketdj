package com.levi.pocketdj.remote

import com.levi.pocketdj.data.PdjJson
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// ---------------------------------------------------------------------------------------------------------
// The thin seam over Google Nearby Connections. Everything below is pure Kotlin so the framing, the
// handshake, the relay and the host migration are JVM-testable with a fake client.
// ---------------------------------------------------------------------------------------------------------

/** Events a [NearbyClient] reports (on any thread; the transport serialises them). */
interface NearbyListener {
    fun onEndpointFound(endpointId: String, endpointName: String)
    fun onEndpointLost(endpointId: String)
    /** [incoming] = the remote side asked to connect to us (we advertise). [authDigits] are shown on both phones. */
    fun onConnectionInitiated(endpointId: String, endpointName: String, authDigits: String, incoming: Boolean)
    fun onConnectionResult(endpointId: String, success: Boolean)
    fun onDisconnected(endpointId: String)
    fun onPayload(endpointId: String, bytes: ByteArray)
}

/** The Nearby calls the transport makes (`ConnectionsClient` in the app, a fake in tests). P2P_STAR, one service id. */
interface NearbyClient {
    var listener: NearbyListener?
    fun startAdvertising(endpointName: String, onResult: (Throwable?) -> Unit)
    fun stopAdvertising()
    fun startDiscovery(onResult: (Throwable?) -> Unit)
    fun stopDiscovery()
    fun requestConnection(localName: String, endpointId: String)
    fun acceptConnection(endpointId: String)
    fun rejectConnection(endpointId: String)
    /** One call = one `Payload.fromBytes` (a bytes payload is one atomic delivery, capped at [NearbyFrames.MAX_PAYLOAD_BYTES]). */
    fun send(endpointId: String, bytes: ByteArray)
    fun disconnect(endpointId: String)
    fun stopAll()

    companion object {
        const val SERVICE_ID = "com.levi.pocketdj.remote"
    }
}

/**
 * The frames that ride the Nearby star. Every frame is ONE JSON object, one payload.
 *  - `{"t":"hi","v":1,"id":"<participant uuid>"}`: FIRST frame each side sends after connecting; it binds the
 *    endpoint to a per-session participant id (never the Nearby endpoint id: the host election compares ids across devices).
 *  - `{"t":"roster","ids":[...]}`: relay host -> joiners, on every membership change.
 *  - `{"t":"m","from":"<id>","to":"<id>","e":{<envelope>}}`: a RemoteEnvelope. Joiner -> host omits `from` (the host
 *    stamps the sender from the endpoint binding, never trusting the claim) and omits `to` for "everyone".
 */
sealed interface NearbyFrame {
    /** [proof]: [NearbyInvite.proof] of the invite token when the sender holds it (joiner -> host). */
    data class Hi(val id: String, val proof: String? = null) : NearbyFrame
    data class Roster(val ids: List<String>) : NearbyFrame
    data class Message(val from: String?, val to: String?, val envelope: RemoteEnvelope) : NearbyFrame
}

object NearbyFrames {
    /** Nearby's `Payload.fromBytes` limit. */
    const val MAX_PAYLOAD_BYTES = 32 * 1024
    /** Largest envelope the host may put in one `state` message; the frame wrapper + ids fit in the remaining ~2.7 KB. */
    const val MAX_STATE_BYTES = 30 * 1024
    const val VERSION = 1

    fun encode(frame: NearbyFrame): ByteArray {
        val o: JsonObject = when (frame) {
            is NearbyFrame.Hi -> buildMap<String, JsonElement> {
                put("t", JsonPrimitive("hi")); put("v", JsonPrimitive(VERSION)); put("id", JsonPrimitive(frame.id))
                frame.proof?.let { put("p", JsonPrimitive(it)) }
            }.let(::JsonObject)
            is NearbyFrame.Roster -> JsonObject(mapOf("t" to JsonPrimitive("roster"), "ids" to JsonArray(frame.ids.map { JsonPrimitive(it) })))
            is NearbyFrame.Message -> buildMap<String, JsonElement> {
                put("t", JsonPrimitive("m"))
                frame.from?.let { put("from", JsonPrimitive(it)) }
                frame.to?.let { put("to", JsonPrimitive(it)) }
                put("e", PdjJson.lenient.encodeToJsonElement(RemoteEnvelope.serializer(), frame.envelope))
            }.let(::JsonObject)
        }
        return o.toString().toByteArray(Charsets.UTF_8)
    }

    /** Null for anything malformed or unknown: a hostile or newer peer is ignored, never fatal. */
    fun decode(bytes: ByteArray): NearbyFrame? = try {
        val o = PdjJson.lenient.parseToJsonElement(String(bytes, Charsets.UTF_8)).jsonObject
        when (o["t"]?.jsonPrimitive?.contentOrNull) {
            "hi" -> o["id"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }?.let { NearbyFrame.Hi(it, o["p"]?.jsonPrimitive?.contentOrNull) }
            "roster" -> NearbyFrame.Roster(o["ids"]!!.jsonArray.map { it.jsonPrimitive.content })
            "m" -> NearbyFrame.Message(
                from = o["from"]?.jsonPrimitive?.contentOrNull,
                to = o["to"]?.jsonPrimitive?.contentOrNull,
                envelope = PdjJson.lenient.decodeFromJsonElement(RemoteEnvelope.serializer(), o["e"]!!),
            )
            else -> null
        }
    } catch (_: Exception) { null }
}

/** A joiner that picked the host from the Nearby list (no token) and is waiting for the host's explicit approval. */
data class PendingJoin(val endpointId: String, val deviceName: String, val authDigits: String)

/**
 * The Nearby Connections [RemoteTransport] (P2-REM-9). A star: the HOST advertises, joiners discover and connect to it,
 * and the host relays participant -> participant traffic (never echoing to the sender). It works with no server and no
 * internet. If the relay host leaves, the remaining joiners MIGRATE: the lowest remaining id advertises, the rest
 * rediscover it by the session's token hash, so the Remote controller's own hand-over election can carry on.
 *
 * One instance per session. Callbacks and [send] are serialised on an internal lock.
 */
class NearbyRemoteTransport(
    private val client: NearbyClient,
    override val localParticipantId: String,
    private val deviceName: String,
    private val sessionMode: RemoteSessionMode?,
    /** Host: the hash of the invite token. Joiner: the hash to look for, or [NearbyInvite.OPEN_HASH] for a pick-from-list join. */
    tokenHash: String,
    private val scope: CoroutineScope,
    allowOpenJoin: Boolean = true,
    private val migrateTimeoutMs: Long = DEFAULT_MIGRATE_TIMEOUT_MS,
    private val maxJoiners: Int = DEFAULT_MAX_JOINERS,
    private val log: (String) -> Unit = {},
    /** Shown on both phones while a connection is pending: (the other device's name, the digits to compare). */
    private val onAuthDigits: (String, String) -> Unit = { _, _ -> },
    /** The invite token (host, or a joiner who scanned/typed it). Never sent; only [NearbyInvite.proof] of it is. */
    private val token: String? = null,
    /** Host: the open joins waiting for approval changed. */
    private val onPendingJoins: (List<PendingJoin>) -> Unit = {},
    private val pendingJoinTimeoutMs: Long = DEFAULT_PENDING_TIMEOUT_MS,
    private val connectRetryDelayMs: Long = DEFAULT_RETRY_DELAY_MS,
) : RemoteTransport, NearbyListener {

    override val maxStateBytes: Int = NearbyFrames.MAX_STATE_BYTES

    private val inboundChannel = Channel<RemoteInbound>(Channel.UNLIMITED)
    override val inbound: Flow<RemoteInbound> = inboundChannel.receiveAsFlow()
    private val roster = MutableStateFlow<Set<String>>(emptySet())
    override val participants: StateFlow<Set<String>> = roster

    /** Completes when this device is linked into the session (host: advertising; joiner: the host's roster arrived). */
    val linked = CompletableDeferred<Unit>()

    private val lock = Any()
    private var sessionHash = tokenHash
    private var openJoin = allowOpenJoin
    private var isRelayHost = false
    private var finished = false

    // Relay-host side: accepted endpoints and their bound participant ids.
    private val acceptedEndpoints = LinkedHashSet<String>()
    private val idByEndpoint = HashMap<String, String>()
    private val endpointById = LinkedHashMap<String, String>()
    /** Endpoints accepted on a matching token HASH: admitted only by a valid proof (or a known roster id after migration). */
    private val hashEndpoints = HashSet<String>()
    /** Endpoints the host approved by hand (open join): admitted on their first frame. */
    private val approvedEndpoints = HashSet<String>()
    private val hiSent = HashSet<String>()
    private val pendingJoins = LinkedHashMap<String, PendingJoin>()
    private val pendingExpiry = HashMap<String, Job>()
    /** After a migration: the previous roster. Its members may re-link without the token. */
    private var knownIds: Set<String> = emptySet()

    // Joiner side.
    private var expectedEndpoint: String? = null
    private var hostEndpoint: String? = null
    private var hostParticipantId: String? = null
    private var lastRoster: Set<String> = emptySet()
    private var finding = false
    private var migrateJob: Job? = null
    private var connectRetries = 0

    /** The mode the host advertised (joiner side), once known. */
    @Volatile var hostMode: RemoteSessionMode? = null
        private set

    init { client.listener = this }

    // ---- Entry points ----

    /** Become the relay host: advertise. [onResult] reports the advertising outcome (the caller decides what a failure means). */
    fun startHosting(onResult: (Throwable?) -> Unit = {}) = synchronized(lock) {
        isRelayHost = true
        publishRoster()
        client.startAdvertising(NearbyInvite.endpointName(deviceName, sessionHash, sessionMode)) { err ->
            if (err == null) linked.complete(Unit)
            onResult(err)
        }
    }

    /** Join the host at [endpointId] (picked from the Nearby list, or found by the caller). */
    fun joinEndpoint(endpointId: String) = synchronized(lock) { connectTo(endpointId) }

    /** Join by invite token hash: discover and connect to the first host advertising it. */
    fun joinByHash(onResult: (Throwable?) -> Unit = {}) = synchronized(lock) {
        finding = true; connectRetries = 0
        client.startDiscovery(onResult)
    }

    // ---- RemoteTransport ----

    override fun send(envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Boolean) {
        synchronized(lock) {
            if (finished) return
            if (isRelayHost) {
                val from = localParticipantId
                when (to) {
                    RemoteRecipient.All -> endpointById.values.forEach { transmit(it, NearbyFrame.Message(from, null, envelope)) }
                    is RemoteRecipient.Participant -> endpointById[to.id]?.let { transmit(it, NearbyFrame.Message(from, to.id, envelope)) }
                }
            } else {
                val host = hostEndpoint ?: run { log("send dropped: not linked (${envelope.kind})"); return }
                val target = (to as? RemoteRecipient.Participant)?.id
                if (target == localParticipantId) return
                transmit(host, NearbyFrame.Message(null, target, envelope))
            }
        }
    }

    override fun leave() = synchronized(lock) { finish("leave") }

    // ---- NearbyListener ----

    override fun onEndpointFound(endpointId: String, endpointName: String) = synchronized(lock) {
        if (finished || !finding || expectedEndpoint != null) return
        val ep = NearbyInvite.parseEndpointName(endpointName)
        if (ep.hash != null && ep.hash == sessionHash) connectTo(endpointId)
    }

    override fun onEndpointLost(endpointId: String) = Unit

    override fun onConnectionInitiated(endpointId: String, endpointName: String, authDigits: String, incoming: Boolean) = synchronized(lock) {
        if (finished) { client.rejectConnection(endpointId); return }
        if (incoming) {
            val ep = NearbyInvite.parseEndpointName(endpointName)
            val room = isRelayHost && acceptedEndpoints.size + pendingJoins.size < maxJoiners
            when {
                !room -> { log("rejected connection from ${ep.deviceName}: ${if (isRelayHost) "full" else "not hosting"}"); client.rejectConnection(endpointId) }
                ep.hash == sessionHash -> {
                    // The hash is public (it is in the advertisement): accept the link, but admit nobody without the proof.
                    onAuthDigits(ep.deviceName, authDigits)
                    acceptedEndpoints += endpointId; hashEndpoints += endpointId; client.acceptConnection(endpointId)
                }
                ep.hash == NearbyInvite.OPEN_HASH && openJoin -> {
                    // A pick-from-list join has no token. Hold it UNACCEPTED until the host approves it by name + digits.
                    val join = PendingJoin(endpointId, ep.deviceName, authDigits)
                    pendingJoins[endpointId] = join
                    pendingExpiry[endpointId] = scope.launch {
                        delay(pendingJoinTimeoutMs)
                        synchronized(lock) { if (pendingJoins.containsKey(endpointId)) denyJoin(endpointId) }
                    }
                    onPendingJoins(pendingJoins.values.toList())
                }
                else -> { log("rejected connection from ${ep.deviceName}: token mismatch"); client.rejectConnection(endpointId) }
            }
        } else {
            if (endpointId != expectedEndpoint) { client.rejectConnection(endpointId); return }
            val ep = NearbyInvite.parseEndpointName(endpointName)
            // A host that doesn't carry our token hash is not the host we asked for (an open join takes whatever it picked).
            if (sessionHash != NearbyInvite.OPEN_HASH && ep.hash != sessionHash) {
                log("host hash mismatch, dropping"); expectedEndpoint = null; client.rejectConnection(endpointId); return
            }
            if (ep.hash != null) sessionHash = ep.hash
            hostMode = ep.mode
            onAuthDigits(ep.deviceName, authDigits)
            client.acceptConnection(endpointId)
        }
    }

    override fun onConnectionResult(endpointId: String, success: Boolean) = synchronized(lock) {
        if (finished) return
        if (success) {
            // Our id goes FIRST, so the other side can bind this endpoint to a participant id.
            if (endpointId in acceptedEndpoints || endpointId == expectedEndpoint) sendHi(endpointId)
        } else {
            acceptedEndpoints -= endpointId; hashEndpoints -= endpointId; approvedEndpoints -= endpointId; hiSent -= endpointId
            dropPending(endpointId)
            if (endpointId == expectedEndpoint) {
                expectedEndpoint = null
                if (finding && connectRetries < MAX_CONNECT_RETRIES) {
                    // Nearby reports an endpoint once, so a transient failure would never be retried by discovery.
                    connectRetries++
                    scope.launch {
                        delay(connectRetryDelayMs)
                        synchronized(lock) { if (!finished && finding && expectedEndpoint == null) connectTo(endpointId) }
                    }
                } else if (!finding && migrateJob == null && !linked.isCompleted) linked.completeExceptionally(IllegalStateException("The host declined the connection."))
            }
        }
    }

    override fun onDisconnected(endpointId: String) = synchronized(lock) {
        if (finished) return
        acceptedEndpoints -= endpointId; hashEndpoints -= endpointId; approvedEndpoints -= endpointId; hiSent -= endpointId
        dropPending(endpointId)
        if (isRelayHost) {
            val id = idByEndpoint.remove(endpointId)
            if (id != null) { endpointById.remove(id); publishRoster() }
        } else if (endpointId == hostEndpoint) {
            hostLost()
        } else if (endpointId == expectedEndpoint) {
            expectedEndpoint = null
        }
    }

    override fun onPayload(endpointId: String, bytes: ByteArray) = synchronized(lock) {
        if (finished) return
        val frame = NearbyFrames.decode(bytes) ?: run { log("dropped undecodable frame (${bytes.size} B)"); return }
        if (isRelayHost) hostReceive(endpointId, frame) else joinerReceive(endpointId, frame)
    }

    // ---- Relay host ----

    private fun hostReceive(endpointId: String, frame: NearbyFrame) {
        if (endpointId !in acceptedEndpoints) return
        when (frame) {
            is NearbyFrame.Hi -> {
                val id = frame.id
                if (id == localParticipantId) { client.disconnect(endpointId); return }
                if (!admitted(endpointId, frame)) { log("refused a join without proof"); acceptedEndpoints -= endpointId; hashEndpoints -= endpointId; client.disconnect(endpointId); return }
                if (idByEndpoint[endpointId] != null) return // a second hi on the same link is ignored
                endpointById[id]?.takeIf { it != endpointId }?.let { old -> idByEndpoint.remove(old); client.disconnect(old) }
                idByEndpoint[endpointId] = id
                endpointById[id] = endpointId
                sendHi(endpointId) // the joiner must hear our id before the roster
                publishRoster()
            }
            is NearbyFrame.Message -> {
                // Anything before the id handshake has no sender we can stamp: ignore it.
                val sender = idByEndpoint[endpointId] ?: return
                val to = frame.to
                when {
                    to == null -> {
                        deliver(frame.envelope, sender)
                        endpointById.forEach { (id, ep) -> if (id != sender) transmit(ep, NearbyFrame.Message(sender, null, frame.envelope)) }
                    }
                    to == localParticipantId -> deliver(frame.envelope, sender)
                    to != sender -> endpointById[to]?.let { transmit(it, NearbyFrame.Message(sender, to, frame.envelope)) }
                }
            }
            is NearbyFrame.Roster -> Unit // only the host sends rosters
        }
    }

    /** Our id (+ proof, joiner side) goes first on a link, exactly once, whichever side's "connected" callback fires first. */
    private fun sendHi(endpointId: String) {
        if (!hiSent.add(endpointId)) return
        transmit(endpointId, NearbyFrame.Hi(localParticipantId, if (endpointId == expectedEndpoint) token?.let(NearbyInvite::proof) else null))
    }

    private fun admitted(endpointId: String, hi: NearbyFrame.Hi): Boolean = when {
        endpointId in approvedEndpoints -> true
        endpointId in hashEndpoints ->
            (token != null && hi.proof == NearbyInvite.proof(token)) || hi.id in knownIds
        else -> false
    }

    /** Host: let the pending open join in. */
    fun approveJoin(endpointId: String): Unit = synchronized(lock) {
        if (finished || pendingJoins[endpointId] == null) return
        dropPending(endpointId)
        acceptedEndpoints += endpointId; approvedEndpoints += endpointId
        client.acceptConnection(endpointId)
    }

    /** Host: turn the pending open join away. */
    fun denyJoin(endpointId: String): Unit = synchronized(lock) {
        if (pendingJoins[endpointId] == null) return
        dropPending(endpointId)
        client.rejectConnection(endpointId)
    }

    private fun dropPending(endpointId: String) {
        pendingExpiry.remove(endpointId)?.cancel()
        if (pendingJoins.remove(endpointId) != null) onPendingJoins(pendingJoins.values.toList())
    }

    private fun publishRoster() {
        val ids = LinkedHashSet<String>().apply { add(localParticipantId); addAll(endpointById.keys) }
        roster.value = ids
        val frame = NearbyFrame.Roster(ids.toList())
        endpointById.values.forEach { transmit(it, frame) }
    }

    // ---- Joiner ----

    private fun connectTo(endpointId: String) {
        if (finished) return
        expectedEndpoint = endpointId
        client.requestConnection(NearbyInvite.endpointName(deviceName, sessionHash, null), endpointId)
    }

    private fun joinerReceive(endpointId: String, frame: NearbyFrame) {
        if (endpointId != expectedEndpoint && endpointId != hostEndpoint) return
        when (frame) {
            is NearbyFrame.Hi -> {
                if (hostEndpoint != null && hostEndpoint != endpointId) return
                hostEndpoint = endpointId
                hostParticipantId = frame.id
                finding = false
                client.stopDiscovery()
            }
            is NearbyFrame.Roster -> {
                if (endpointId != hostEndpoint) return
                val ids = frame.ids.toMutableSet().also { it.add(localParticipantId) }
                lastRoster = ids
                roster.value = ids
                migrateJob?.cancel(); migrateJob = null
                linked.complete(Unit)
            }
            is NearbyFrame.Message -> {
                if (endpointId != hostEndpoint) return
                val from = frame.from ?: hostParticipantId ?: return
                if (from == localParticipantId) return
                deliver(frame.envelope, from)
            }
        }
    }

    /** The relay host's link dropped. The remaining participants re-form around the lowest id. */
    private fun hostLost() {
        val gone = hostParticipantId
        hostEndpoint = null; hostParticipantId = null; expectedEndpoint = null
        val remaining = (lastRoster - setOfNotNull(gone)).ifEmpty { setOf(localParticipantId) }
        roster.value = remaining
        lastRoster = remaining
        if (!linked.isCompleted) { finish("host lost before link"); return }
        log("relay host left; migrating among ${remaining.size}")
        if (remaining.min() == localParticipantId) {
            isRelayHost = true
            knownIds = remaining - localParticipantId
            openJoin = false // a migrated relay only takes participants that present the session's hash
            client.startAdvertising(NearbyInvite.endpointName(deviceName, sessionHash, sessionMode)) { err ->
                if (err != null) synchronized(lock) { log("migration advertise failed: ${err.message}"); finish("advertise failed") }
            }
            publishRoster()
        } else {
            finding = true; connectRetries = 0
            client.startDiscovery { err -> if (err != null) synchronized(lock) { log("migration discover failed: ${err.message}"); finish("discover failed") } }
            migrateJob = scope.launch {
                delay(migrateTimeoutMs)
                synchronized(lock) { if (hostEndpoint == null) finish("migration timed out") }
            }
        }
    }

    // ---- Plumbing ----

    private fun deliver(envelope: RemoteEnvelope, from: String) { inboundChannel.trySend(RemoteInbound(envelope, from)) }

    private fun transmit(endpointId: String, frame: NearbyFrame) {
        val bytes = NearbyFrames.encode(frame)
        if (bytes.size > NearbyFrames.MAX_PAYLOAD_BYTES) {
            log("frame too large (${bytes.size} B), dropped"); return
        }
        client.send(endpointId, bytes)
    }

    private fun finish(why: String) {
        if (finished) return
        finished = true
        log("finish: $why")
        migrateJob?.cancel()
        pendingExpiry.values.forEach { it.cancel() }; pendingExpiry.clear()
        if (pendingJoins.isNotEmpty()) { pendingJoins.clear(); onPendingJoins(emptyList()) }
        runCatching { client.stopAll() }
        client.listener = null
        inboundChannel.close()
        roster.value = emptySet()
        if (!linked.isCompleted) linked.completeExceptionally(IllegalStateException("Couldn't connect ($why)."))
    }

    companion object {
        const val DEFAULT_MIGRATE_TIMEOUT_MS = 15_000L
        const val DEFAULT_MAX_JOINERS = 7
        const val DEFAULT_PENDING_TIMEOUT_MS = 30_000L
        const val DEFAULT_RETRY_DELAY_MS = 1_000L
        const val MAX_CONNECT_RETRIES = 3
    }
}
