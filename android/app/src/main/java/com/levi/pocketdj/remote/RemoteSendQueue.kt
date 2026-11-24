package com.levi.pocketdj.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException

/**
 * The outbound side of a real transport: TWO independent lanes, each delivering strictly in send order
 * (ONE worker coroutine per lane, never a coroutine per message: that let a later state overtake an earlier one on iOS).
 *  - RELIABLE (state / commands / hellos): retried with backoff on failure while the lane waits. Bounded
 *    ([RELIABLE_CAP]; coalescible kinds are shed first, else the oldest) and COALESCED: an undelivered
 *    `state`/`heartbeat` to the same recipient is replaced by the newer one (latest wins).
 *  - UNRELIABLE (pings, heartbeats): best effort, never retried, never behind a reliable retry; bounded
 *    ([UNRELIABLE_CAP]).
 * Per-participant messages are BUFFERED while that participant is unresolvable (a reply to a joiner's hello can beat
 * the roster update), flushed on [participantsChanged] (cap [BUFFER_CAP] per peer, at most [BUFFERED_PEERS_CAP] peers,
 * a departed peer's buffer dropped).
 *
 * All methods must be called from the single thread that [scope]'s dispatcher runs on (Main), which makes the
 * "lane empty -> worker exits" check atomic with [enqueue]. Generic over the transport's recipient type.
 */
class RemoteSendQueue<R>(
    private val scope: CoroutineScope,
    private val resolve: (RemoteRecipient) -> R?,
    private val retryDelaysMs: List<Long> = listOf(250L, 1000L),
    private val log: (String) -> Unit = {},
    private val send: suspend (RemoteEnvelope, R, Boolean) -> Unit,
) {
    data class Outbound(val envelope: RemoteEnvelope, val to: RemoteRecipient, val reliable: Boolean)

    private val reliableLane = ArrayDeque<Outbound>()
    private val unreliableLane = ArrayDeque<Outbound>()
    private var reliableWorker: Job? = null
    private var unreliableWorker: Job? = null
    private var finished = false
    private val bufferedMap = LinkedHashMap<String, ArrayDeque<Outbound>>()

    var deliveredCount = 0; private set
    var failureCount = 0; private set
    var droppedCount = 0; private set
    val pendingReliable: Int get() = reliableLane.size
    val pendingUnreliable: Int get() = unreliableLane.size

    /** Snapshot of buffered messages per unresolved participant id. */
    val buffered: Map<String, List<Outbound>> get() = bufferedMap.mapValues { it.value.toList() }

    fun enqueue(envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Boolean) {
        if (finished) return
        push(Outbound(envelope, to, reliable))
        startWorkers()
    }

    /** The roster moved: drop departed buffers; flush buffered messages whose peer is now resolvable, in original order. */
    fun participantsChanged(departed: Set<String> = emptySet()) {
        for (id in departed) bufferedMap.remove(id)
        val it = bufferedMap.entries.iterator()
        val flush = mutableListOf<Outbound>()
        while (it.hasNext()) {
            val (id, msgs) = it.next()
            if (resolve(RemoteRecipient.Participant(id)) != null) { flush += msgs; it.remove() }
        }
        flush.forEach { push(it) }
        startWorkers()
    }

    fun finish() {
        finished = true
        reliableWorker?.cancel(); reliableWorker = null
        unreliableWorker?.cancel(); unreliableWorker = null
        reliableLane.clear(); unreliableLane.clear(); bufferedMap.clear()
    }

    private fun push(o: Outbound) {
        val lane = if (o.reliable) reliableLane else unreliableLane
        val cap = if (o.reliable) RELIABLE_CAP else UNRELIABLE_CAP
        if (o.envelope.kind in COALESCED_KINDS) {
            val i = lane.indexOfFirst { it.envelope.kind == o.envelope.kind && it.to == o.to }
            if (i >= 0) { lane.removeAt(i); droppedCount++ }
        }
        lane.addLast(o)
        if (lane.size > cap) {
            val i = lane.indexOfFirst { it.envelope.kind in COALESCED_KINDS }.let { if (it < 0) 0 else it }
            val gone = lane.removeAt(i)
            droppedCount++
            log("send queue full ($cap): dropped ${gone.envelope.kind}")
        }
    }

    private fun startWorkers() {
        if (finished) return
        if (reliableWorker == null && reliableLane.isNotEmpty()) {
            reliableWorker = scope.launch { drain(true) }
        }
        if (unreliableWorker == null && unreliableLane.isNotEmpty()) {
            unreliableWorker = scope.launch { drain(false) }
        }
    }

    private suspend fun drain(reliable: Boolean) {
        val lane = if (reliable) reliableLane else unreliableLane
        try {
            while (scope.isActive && !finished) {
                val next = lane.removeFirstOrNull() ?: break
                deliver(next)
            }
        } finally {
            if (reliable) reliableWorker = null else unreliableWorker = null
        }
    }

    private suspend fun deliver(o: Outbound) {
        val recipient = resolve(o.to)
        if (recipient == null) {
            val to = o.to
            if (to is RemoteRecipient.Participant && o.reliable) bufferForLater(o, to.id)
            return
        }
        var attempt = 0
        while (true) {
            try {
                send(o.envelope, recipient, o.reliable)
                deliveredCount++
                return
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failureCount++
                log("send ${o.envelope.kind} failed (attempt ${attempt + 1}): ${e.message}")
                if (!o.reliable || attempt >= retryDelaysMs.size || finished) return
                val d = retryDelaysMs[attempt]
                attempt++
                if (d > 0) delay(d)
            }
        }
    }

    private fun bufferForLater(o: Outbound, id: String) {
        if (finished) return
        if (!bufferedMap.containsKey(id)) {
            while (bufferedMap.size >= BUFFERED_PEERS_CAP) {
                val oldest = bufferedMap.keys.first()
                droppedCount += bufferedMap.remove(oldest)?.size ?: 0
            }
            bufferedMap[id] = ArrayDeque()
        }
        val list = bufferedMap.getValue(id)
        list.addLast(o)
        while (list.size > BUFFER_CAP) { list.removeFirst(); droppedCount++ }
    }

    companion object {
        const val BUFFER_CAP = 32
        const val BUFFERED_PEERS_CAP = 16
        const val RELIABLE_CAP = 256
        const val UNRELIABLE_CAP = 32
        val COALESCED_KINDS: Set<String> = setOf(RemoteMessageKind.STATE.wire, RemoteMessageKind.HEARTBEAT.wire)
    }
}
