package com.levi.pocketdj.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * An in-memory transport hub connecting any number of [LoopbackTransport]s (unit tests + the showcase seed). Delivery is
 * async (a hop through each receiver's channel), in send order per receiver.
 *
 * Ordering contract: with latency injection, one coroutine is launched per message, so send order per receiver holds
 * only when [scope] is single-threaded (Main, a TestScope, or `limitedParallelism(1)`); equal delays can reorder on a
 * multi-threaded dispatcher. Immediate delivery (no latency) is always in order.
 *
 * Injection is a pure function of its inputs, so tests are deterministic:
 *  - [latency] (seconds) per (from, to); null or <= 0 means immediate. Needs [scope] when used.
 *  - [drop] true means the envelope from -> to is lost.
 */
class LoopbackHub(private val scope: CoroutineScope? = null) {
    private val peers = LinkedHashMap<String, LoopbackTransport>()
    var latency: ((from: String, to: String) -> Double)? = null
    var drop: ((RemoteEnvelope, from: String, to: RemoteRecipient) -> Boolean)? = null

    /** Join a new peer under [id] (ids order the hand-over election, so tests pick them). */
    @Synchronized
    fun join(id: String = UUID.randomUUID().toString(), maxStateBytes: Int = DEFAULT_MAX_STATE_BYTES): LoopbackTransport {
        val t = LoopbackTransport(id, this, maxStateBytes)
        peers[id] = t
        broadcastRoster()
        return t
    }

    @get:Synchronized
    val participantIds: Set<String> get() = peers.keys.toSet()

    @Synchronized
    internal fun remove(id: String) {
        val t = peers.remove(id) ?: return
        t.finish()
        broadcastRoster()
    }

    /** End the session for everyone. */
    @Synchronized
    fun end() {
        val all = peers.values.toList()
        peers.clear()
        all.forEach { it.finish() }
    }

    internal fun deliver(env: RemoteEnvelope, from: String, to: RemoteRecipient) {
        if (drop?.invoke(env, from, to) == true) return
        val targets: List<LoopbackTransport> = synchronized(this) {
            when (to) {
                RemoteRecipient.All -> peers.values.filter { it.localParticipantId != from }
                is RemoteRecipient.Participant -> listOfNotNull(peers[to.id]).filter { it.localParticipantId != from }
            }
        }
        for (t in targets) {
            val msg = RemoteInbound(env, from)
            val d = latency?.invoke(from, t.localParticipantId) ?: 0.0
            if (d > 0) {
                val s = requireNotNull(scope) { "LoopbackHub latency needs a scope" }
                s.launch { delay((d * 1000).toLong()); t.receive(msg) }
            } else t.receive(msg)
        }
    }

    private fun broadcastRoster() {
        val ids = peers.keys.toSet()
        peers.values.forEach { it.rosterChanged(ids) }
    }

    companion object { const val DEFAULT_MAX_STATE_BYTES = 256 * 1024 }
}

class LoopbackTransport internal constructor(
    override val localParticipantId: String,
    private val hub: LoopbackHub,
    override val maxStateBytes: Int,
) : RemoteTransport {
    private val inboundChannel = Channel<RemoteInbound>(Channel.UNLIMITED)
    private val roster = MutableStateFlow<Set<String>>(emptySet())
    override val inbound: Flow<RemoteInbound> = inboundChannel.receiveAsFlow()
    override val participants: StateFlow<Set<String>> = roster

    private val sentLog = ArrayList<Pair<RemoteEnvelope, RemoteRecipient>>()
    /** Every envelope this peer SENT (tests assert "no echo" against it). */
    val sent: List<Pair<RemoteEnvelope, RemoteRecipient>> get() = synchronized(sentLog) { sentLog.toList() }

    override fun send(envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Boolean) {
        synchronized(sentLog) { sentLog += envelope to to }
        hub.deliver(envelope, localParticipantId, to)
    }

    override fun leave() = hub.remove(localParticipantId)

    /** Inject a raw envelope as if [from] sent it (tests: unknown kinds, hostile payloads). */
    fun inject(envelope: RemoteEnvelope, from: String) = receive(RemoteInbound(envelope, from))

    internal fun receive(msg: RemoteInbound) { inboundChannel.trySend(msg) }
    internal fun rosterChanged(ids: Set<String>) { roster.value = ids }
    internal fun finish() { inboundChannel.close(); roster.value = emptySet() }
}
