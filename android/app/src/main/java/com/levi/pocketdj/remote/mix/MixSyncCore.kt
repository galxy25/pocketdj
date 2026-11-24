package com.levi.pocketdj.remote.mix

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.remote.RemoteEnvelope
import com.levi.pocketdj.remote.RemoteRecipient
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import com.levi.pocketdj.remote.RemoteWire
import kotlinx.serialization.KSerializer
import java.util.Base64
import kotlin.math.abs
import kotlin.math.pow

/**
 * What the Mix core needs from the Remote session (the controller in the app, a fake in tests). All times are
 * epoch-ms Doubles on THIS device's clock unless named shared.
 */
interface MixSyncSession {
    val localId: String?
    val hostId: String?
    val isSessionActive: Boolean
    val isListenTogether: Boolean
    val roster: Set<String>
    fun localNow(): Double

    /** Shared (host) time now, null until the clock has a sample. The host's own clock IS the shared clock. */
    fun sharedNow(): Double?

    /** My clock offset to the CURRENT host (host = local + offset), null before the first sample. */
    fun offsetToCurrentHost(): Double?
    fun peerCaps(id: String): List<String>?
    fun peerPlatform(id: String): String?
    fun peerName(id: String): String?
    fun send(envelope: RemoteEnvelope, to: RemoteRecipient)
}

/** The engine / UI half (P2-REM-12/13 implement it); every method has a no-op default so tests override a few. */
interface MixSyncSink {
    /** A mix session went live / ended on this device. */
    fun onActive(on: Boolean) {}

    /** An ORDERED, non-echo event to render locally (the host-order apply; never fired for the sender's own echo). */
    fun onApply(e: MixSyncEvent) {}

    /**
     * The mirror's deck content changed through an ORDERED LOAD or EJECT (kind = MixSyncKind.LOAD / EJECT), fired for
     * every such event on every device, including the sender's own echo and events shadowed by a pending proposal.
     * The driver reports deck readiness from here (iOS reportReadiness). Core callbacks must arrive on one thread (Main).
     */
    fun onMirrorChanged(deck: Deck, kind: String) {}

    /** The whole mirror was replaced (snapshot / handover): reconcile every deck + the crossfader. */
    fun onSnapshotAdopted(model: MixSyncModel) {}

    /** [deck] must be re-reconciled from the mirror (a refused gesture, a rejoin). */
    fun onRepair(deck: Deck) {}
    fun onOwnersChanged(owners: Map<Deck, String>) {}
    fun onStatus(message: String?) {}

    /** A fresh `mix.beat` from a deck's owner (already folded into the mirror's anchor): the drift reference. */
    fun onBeat(deck: Deck, beat: MixSyncBeat, from: String) {}

    /** HOST: the mix just started; the Listen Together set yields the speakers to the decks. */
    fun onSessionStarted() {}

    /** Can THIS device sound [songId] on [deck] right now (a host holds a start until its owner can)? */
    fun localDeckReady(deck: Deck, songId: String): Boolean = true

    /** HOST: the decks already loaded here, as events (load + whole board + transport), to seed a new mix. */
    fun seedEvents(deck: Deck): List<MixSyncEvent> = emptyList()
    fun localCrossfader(): Double = 0.5

    /** A coalesced proposal is due at [atLocalMs]: the driver should call [MixSyncCore.flushOutbox] then. */
    fun scheduleFlush(atLocalMs: Double) {}
    fun log(line: String) {}
}

/**
 * The host-ordered event core of Mix Together (iOS `MixSync` minus the engine seams, ported behavior-for-behavior).
 *
 * AUTHORITY. The Remote host orders everything: a participant's gesture is a PROPOSAL (`mix.event`, no hostSeq);
 * the host validates it (ownership, drops one older than the sender's last on that control), assigns the next
 * hostSeq, rebroadcasts, and every device (host included) applies ordered events strictly in host order. Every
 * device mirrors the authoritative [MixSyncModel], so any device can answer a joiner or take over (`mix.handover`);
 * a live mix is never ended by an empty or older host.
 *
 * NO ECHO. A gesture is applied locally the instant it happens and its echo is skipped. A sender's own un-echoed
 * proposal on a control shadows another sender's earlier-ordered value on the SAME control. A proposal unanswered
 * for [MixSyncTunables.PENDING_TIMEOUT_MS] is dropped and a snapshot requested.
 *
 * OWNERSHIP. Host takes Deck A, the first `caps:["mix"]` joiner Deck B; Claim/Release are proposals; the crossfader
 * is shared.
 *
 * Single-threaded: confine to the session's thread (Main). The driver calls [tick] every 250 ms.
 */
class MixSyncCore(
    private val session: MixSyncSession,
    private val sink: MixSyncSink = object : MixSyncSink {},
) {
    private data class Pending(val seq: Int, val at: Double)
    private data class Held(val msg: MixSyncEventMessage, val from: String, val since: Double)
    private data class Queued(val msg: MixSyncEventMessage, val due: Double)

    var isActive = false
        private set
    var owners: Map<Deck, String> = emptyMap()
        private set
    var model = MixSyncModel()
        private set
    var statusMessage: String? = null
        private set

    /** Each peer's per-deck readiness (`mix.ready`): peer id -> deck label. */
    private val peerReadinessMap = HashMap<String, HashMap<String, MixSyncReady>>()
    val peerReadiness: Map<String, Map<String, MixSyncReady>> get() = peerReadinessMap

    private var nextOriginSeq = 1
    private val pending = HashMap<String, Pending>()
    private var expectedHostSeq = 1
    private val buffer = HashMap<Int, MixSyncEventMessage>()
    private var gapSince: Double? = null
    private var awaitingSnapshotSince: Double? = null
    var snapshotAttempts = 0
        private set
    private var nextRequestAt = Double.NEGATIVE_INFINITY
    private val held = HashMap<Deck, Held>()
    private val lastProposalSeq = HashMap<String, Int>()
    private val outbox = HashMap<String, Queued>()
    private val lastSentAt = HashMap<String, Double>()
    private var lastHostId: String? = null
    private var lastRoster: Set<String> = emptySet()
    private var lastOffset: Double? = null
    private var previousHostOffset = 0.0

    /** Test seam: proposals the host dropped as stale. */
    var staleDropped = 0
        private set

    val bufferedEventCount: Int get() = buffer.size

    private val now: Double get() = session.localNow()
    private val localId: String? get() = session.localId
    private val isHost: Boolean get() = localId != null && localId == session.hostId

    // ---- UI surface ----

    val canStart: Boolean get() = session.isSessionActive && isHost && session.isListenTogether && !isActive

    val startBlockedReason: String?
        get() {
            if (!session.isSessionActive || isActive) return null
            if (!session.isListenTogether) return "Mixing together needs Listen Together — in Backseat only the car plays."
            if (!isHost) return "Only the session host can start a mix."
            return null
        }

    /** May THIS device's gestures drive [deck]? (Always, outside a mix session.) */
    fun canControl(deck: Deck): Boolean = !isActive || (localId != null && owners[deck] == localId)

    fun owner(deck: Deck): String? = owners[deck]
    val myDecks: List<Deck> get() = localId?.let { me -> Deck.entries.filter { owners[it] == me } } ?: emptyList()

    fun name(id: String): String = if (id == localId) "You" else session.peerName(id) ?: "Someone"

    private fun publishOwners() {
        val o = Deck.entries.mapNotNull { d -> model.owner(d)?.let { d to it } }.toMap()
        if (o != owners) {
            owners = o
            sink.onOwnersChanged(o)
        }
    }

    // ---- Session lifecycle (host) ----

    /** HOST: start mixing inside the current Listen Together session. */
    fun start() {
        if (!canStart) return
        val me = localId ?: return
        checkTopology()
        model = MixSyncModel(epoch = me, hostSeq = model.hostSeq)
        lastProposalSeq.clear()
        hostOrder(MixSyncEvent(MixSyncKind.SESSION, flag = true), me)
        hostOrder(MixSyncEvent(MixSyncKind.OWNER, deck = Deck.A.label, owner = me), me)
        for (d in Deck.entries) for (e in sink.seedEvents(d)) hostOrder(e, me)
        hostOrder(MixSyncEvent(MixSyncKind.CROSSFADER, value = sink.localCrossfader()), me)
        autoAssignB()
        sink.onSessionStarted()
    }

    /** HOST: end the mix (every device keeps its decks, back to solo mixing). */
    fun end() {
        val me = localId ?: return
        if (!isActive || !isHost) return
        hostOrder(MixSyncEvent(MixSyncKind.SESSION, flag = false), me)
    }

    fun claim(deck: Deck) = propose(MixSyncEvent(MixSyncKind.CLAIM, deck = deck.label))
    fun release(deck: Deck) = propose(MixSyncEvent(MixSyncKind.RELEASE, deck = deck.label))

    private fun setActive(on: Boolean) {
        if (on == isActive) return
        isActive = on
        sink.onActive(on)
        if (on) {
            statusMessage = null
        } else {
            peerReadinessMap.clear()
            held.clear(); pending.clear(); outbox.clear()
        }
    }

    /** The Remote session is gone: the mix ends here (decks keep playing locally). */
    private fun resetAll() {
        setActive(false)
        model = MixSyncModel(hostSeq = model.hostSeq)
        publishOwners()
        lastHostId = null
        lastRoster = emptySet()
        lastOffset = null
        buffer.clear()
        gapSince = null
        awaitingSnapshotSince = null
        snapshotAttempts = 0
        lastProposalSeq.clear()
        expectedHostSeq = 1
    }

    // ---- Tick ----

    /** One heartbeat (250 ms in production; tests call it directly). */
    fun tick() {
        checkTopology()
        if (!session.isSessionActive) return
        val t = now
        if (!isHost) {
            gapSince?.let {
                val exhausted = awaitingSnapshotSince != null && snapshotAttempts >= MixSyncTunables.SNAPSHOT_MAX_ATTEMPTS
                if (!exhausted && t - it >= MixSyncTunables.GAP_TIMEOUT_MS) requestSnapshot("gap")
            }
            if (awaitingSnapshotSince != null && snapshotAttempts < MixSyncTunables.SNAPSHOT_MAX_ATTEMPTS &&
                t >= nextRequestAt
            ) requestSnapshot("retry")
            expirePending(t)
        }
        flushOutbox(t)
        if (!isActive) return
        if (isHost) {
            autoAssignB()
            for ((d, h) in held.entries.toList()) if (t - h.since >= MixSyncTunables.READY_TIMEOUT_MS) releaseHeld(d)
        }
    }

    /** Follow the Remote session's host / roster (the controller owns election; we follow it). */
    fun checkTopology() {
        val me = localId
        if (!session.isSessionActive || me == null) {
            if (isActive || lastHostId != null) resetAll()
            return
        }
        val host = session.hostId
        if (host != lastHostId) {
            val previous = lastHostId
            lastHostId = host
            previousHostOffset = if (previous == me) 0.0 else (lastOffset ?: 0.0)
            pending.clear(); held.clear(); buffer.clear()
            gapSince = null
            awaitingSnapshotSince = null
            snapshotAttempts = 0
            nextRequestAt = Double.NEGATIVE_INFINITY
            if (isHost) {
                if (previous != null) takeOver(me) else model = model.copy(epoch = me)
            } else if (host != null) {
                // I WAS the host and yielded: the new host may not have the mix; hand it mine.
                if (previous == me && model.active) pushHandover(host)
                requestSnapshot("host")
            }
        }
        if (!isHost && host != null) session.offsetToCurrentHost()?.let { lastOffset = it }
        val roster = session.roster
        if (roster != lastRoster) {
            val gone = lastRoster - roster
            lastRoster = roster
            for (g in gone) {
                peerReadinessMap.remove(g)
                lastProposalSeq.keys.removeAll { it.startsWith("$g|") }
            }
            if (isHost && model.active) {
                for (d in Deck.entries) {
                    val o = model.owner(d)
                    if (o != null && (o in gone || o !in roster)) {
                        hostOrder(MixSyncEvent(MixSyncKind.OWNER, deck = d.label, owner = null), me)
                    }
                }
                autoAssignB()
            }
        }
    }

    /**
     * HAND-OVER: the old host left and the Remote controller elected me. My mirror becomes the authority,
     * re-anchored from the old host's timeline onto my own clock, departed owners freed, the sequence continued;
     * then broadcast whole.
     */
    private fun takeOver(me: String) {
        val off = lastOffset ?: 0.0
        val decks = model.decks.mapValues { (_, ds) ->
            var d = ds
            d.anchor?.let { a -> a.atSharedTime?.let { d = d.copy(anchor = a.copy(atSharedTime = it - off)) } }
            if (d.owner != null && d.owner !in session.roster) d = d.copy(owner = null)
            d
        }
        model = model.copy(epoch = me, decks = decks)
        lastOffset = null
        lastProposalSeq.clear()
        publishOwners()
        sink.log("mix hand-over -> $me seq=${model.hostSeq} active=${model.active}")
        if (model.active) post(MixWireKind.SNAPSHOT, MixSyncSnapshot.serializer(), model.snapshot(), RemoteRecipient.All)
    }

    private fun isDeckOwnerCandidate(id: String): Boolean {
        if (session.peerCaps(id)?.contains(MixCapability.DECK_OWNER) == true) return true
        val platform = session.peerPlatform(id)
        if (peerReadiness[id] == null || platform == null) return false
        return platform != "Apple TV"
    }

    /** The first mix-capable joiner gets Deck B (once per session; a released B stays free until claimed). */
    private fun autoAssignB() {
        val me = localId ?: return
        if (!isHost || !model.active || model.assignedB || model.owner(Deck.B) != null) return
        val first = session.roster.sorted().firstOrNull {
            it != me && model.decks(it).isEmpty() && isDeckOwnerCandidate(it)
        } ?: return
        hostOrder(MixSyncEvent(MixSyncKind.OWNER, deck = Deck.B.label, owner = first), me)
    }

    // ---- Local gestures -> proposals ----

    private fun coalesceInterval(e: MixSyncEvent): Double = when {
        e.kind == MixSyncKind.SEEK -> MixSyncTunables.SEEK_INTERVAL_MS
        e.kind in MixSyncKind.continuous -> MixSyncTunables.CONTINUOUS_INTERVAL_MS
        else -> 0.0
    }

    /** A local gesture of THIS device's DJ becomes a proposal (already applied locally; never waits a round trip). */
    fun propose(e: MixSyncEvent) {
        if (!isActive || localId == null) return
        val seq = nextOriginSeq++
        val msg = MixSyncEventMessage(originSeq = seq, event = e)
        val key = e.controlKey
        val t = now
        if (!isHost) {
            if (session.hostId == null) {
                statusMessage = "Waiting for the session host…"
                sink.onStatus(statusMessage)
                return
            }
            if (e.kind != MixSyncKind.CLAIM && e.kind != MixSyncKind.RELEASE) pending[key] = Pending(seq, t)
        }
        val interval = coalesceInterval(e)
        if (interval <= 0) {
            outbox.remove(key) // a discrete event on the control supersedes a queued drag
            send(msg)
            return
        }
        // COALESCE: the first move goes at once; later ones inside the interval replace each other and the LAST
        // is sent when the interval closes (the final value always lands).
        if (outbox[key] == null && t - (lastSentAt[key] ?: Double.NEGATIVE_INFINITY) >= interval) {
            lastSentAt[key] = t
            send(msg)
        } else {
            val due = (lastSentAt[key] ?: t) + interval
            outbox[key] = Queued(msg, due)
            sink.scheduleFlush(due)
        }
    }

    val nextOutboxDue: Double? get() = outbox.values.minOfOrNull { it.due }

    private fun send(msg: MixSyncEventMessage) {
        val me = localId ?: return
        if (isHost) { handleProposal(msg, me); return }
        val host = session.hostId ?: return
        post(MixWireKind.EVENT, MixSyncEventMessage.serializer(), msg, RemoteRecipient.Participant(host))
    }

    /** Send every queued (coalesced) proposal whose interval has closed. */
    fun flushOutbox(t: Double = now) {
        val due = outbox.entries.filter { it.value.due <= t }.sortedBy { it.value.msg.originSeq }
        for ((key, q) in due) {
            outbox.remove(key)
            lastSentAt[key] = t
            send(q.msg)
        }
    }

    private fun expirePending(t: Double) {
        val expired = pending.filter { t - it.value.at >= MixSyncTunables.PENDING_TIMEOUT_MS && outbox[it.key] == null }
        if (expired.isEmpty()) return
        for (k in expired.keys) pending.remove(k)
        sink.log("mix proposals unanswered (${expired.keys.sorted().joinToString(",")}) -> snapshot")
        requestSnapshot("pending")
    }

    // ---- Host: validate + order ----

    private fun handleProposal(msg: MixSyncEventMessage, from: String) {
        val e = msg.event
        fun reject(reason: String) {
            sink.log("mix reject ${e.kind} deck=${e.deck ?: "-"} from=$from: $reason")
            if (from == localId) {
                statusMessage = reason
                sink.onStatus(reason)
                e.engineDeck?.let { sink.onRepair(it) }
            } else {
                post(MixWireKind.REJECT, MixSyncReject.serializer(), MixSyncReject(msg.originSeq, reason), RemoteRecipient.Participant(from))
                post(MixWireKind.SNAPSHOT, MixSyncSnapshot.serializer(), model.snapshot(), RemoteRecipient.Participant(from))
            }
        }
        if (!model.active) return reject("No mix session is running.")
        // STALE: an older proposal from this sender on this control arriving after a newer one (a reordered send).
        val seqKey = "$from|${e.controlKey}"
        if (e.kind != MixSyncKind.CLAIM && e.kind != MixSyncKind.RELEASE) {
            val last = lastProposalSeq[seqKey]
            if (last != null && msg.originSeq <= last) {
                staleDropped++
                sink.log("mix stale ${e.kind} deck=${e.deck ?: "-"} from=$from seq=${msg.originSeq}<=$last")
                return
            }
            lastProposalSeq[seqKey] = msg.originSeq
        }
        when (e.kind) {
            MixSyncKind.SESSION, MixSyncKind.OWNER -> reject("Only the host can do that.")
            MixSyncKind.CLAIM -> {
                val d = e.engineDeck ?: return
                model.owner(d)?.let { return reject("Deck ${d.label} belongs to ${name(it)}.") }
                hostOrder(MixSyncEvent(MixSyncKind.OWNER, deck = d.label, owner = from), from, msg.originSeq)
            }
            MixSyncKind.RELEASE -> {
                val d = e.engineDeck
                if (d == null || model.owner(d) != from) return reject("That deck isn’t yours.")
                hostOrder(MixSyncEvent(MixSyncKind.OWNER, deck = d.label, owner = null), from, msg.originSeq)
            }
            MixSyncKind.CROSSFADER -> hostOrder(e, from, msg.originSeq)
            else -> {
                val d = e.engineDeck ?: return
                if (model.owner(d) != from) {
                    val who = model.owner(d)?.let { name(it) } ?: "nobody — claim it first"
                    return reject("Deck ${d.label} belongs to $who.")
                }
                hostOrder(e, from, msg.originSeq)
            }
        }
    }

    /**
     * HOST: stamp + order one event: re-anchor a start into the future, hold a start until the owner's device is
     * ready, fold it into the model, broadcast it, apply it here.
     */
    private fun hostOrder(event: MixSyncEvent, origin: String, originSeq: Int = 0, bypassReadiness: Boolean = false) {
        if (!isHost) return
        var e = event
        val t = now // the host's clock IS the shared clock
        val deck = e.engineDeck
        if (deck != null && (e.isTransport || e.kind == MixSyncKind.LOAD || e.kind == MixSyncKind.EJECT)) {
            held.remove(deck) // a newer transport supersedes a held start
        }
        val anchor = e.anchor
        if (e.carriesAnchor && anchor != null) {
            var a = if (anchor.atSharedTime == null) anchor.copy(atSharedTime = t) else anchor
            if (a.isPlaying && deck != null) {
                if (e.isTransport && !bypassReadiness && !ownerReady(deck)) {
                    e = e.copy(anchor = a)
                    held[deck] = Held(MixSyncEventMessage(originSeq, origin, event = e), origin, t)
                    return
                }
                val target = maxOf(a.atSharedTime ?: t, t + MixSyncTunables.START_LEAD_MS)
                a = MixSyncAnchor(a.position(target, model.deck(deck).rate), target, true)
            }
            e = e.copy(anchor = a)
        }
        val seq = model.hostSeq + 1
        model = model.copy(hostSeq = seq)
        val msg = MixSyncEventMessage(originSeq, origin, seq, model.epoch, e)
        model = model.apply(e, t)
        if (e.kind == MixSyncKind.OWNER) publishOwners()
        post(MixWireKind.EVENT, MixSyncEventMessage.serializer(), msg, RemoteRecipient.All)
        applyOrdered(msg)
    }

    private fun releaseHeld(d: Deck) {
        val h = held.remove(d) ?: return
        hostOrder(h.msg.event, h.from, h.msg.originSeq, bypassReadiness = true)
    }

    /** Can the deck's OWNER device sound its current song (so a start can go out)? */
    private fun ownerReady(d: Deck): Boolean {
        val sid = model.deck(d).track?.songId ?: return true
        val owner = model.owner(d) ?: localId
        if (owner == localId) return sink.localDeckReady(d, sid)
        val r = owner?.let { peerReadiness[it]?.get(d.label) } ?: return false
        return r.songId == sid && r.status != MixSyncReady.Status.LOADING
    }

    // ---- Inbound ----

    /** Route one inbound mix envelope (the driver registers [MixWireKind.all] with the controller). */
    fun receive(env: RemoteEnvelope, from: String) {
        when (env.kind) {
            MixWireKind.EVENT -> env.decode(MixSyncEventMessage.serializer())?.let { receiveEvent(it, from) }
            MixWireKind.SNAPSHOT -> env.decode(MixSyncSnapshot.serializer())?.let { receiveSnapshot(it, from) }
            MixWireKind.REQUEST -> receiveRequest(from)
            MixWireKind.READY -> env.decode(MixSyncReady.serializer())?.let { receiveReady(it, from) }
            MixWireKind.BEAT -> env.decode(MixSyncBeat.serializer())?.let { receiveBeat(it, from) }
            MixWireKind.REJECT -> env.decode(MixSyncReject.serializer())?.let { receiveReject(it, from) }
            MixWireKind.HANDOVER -> env.decode(MixSyncHandover.serializer())?.let { receiveHandover(it, from) }
        }
    }

    private fun receiveEvent(msg: MixSyncEventMessage, from: String) {
        checkTopology()
        val seq = msg.hostSeq
        if (seq != null) {
            if (isHost || from != session.hostId) return
            if (awaitingSnapshotSince != null) { bufferEvent(seq, msg); return }
            if (msg.epoch != model.epoch) { bufferEvent(seq, msg); requestSnapshot("epoch"); return }
            if (seq < expectedHostSeq) return // duplicate
            bufferEvent(seq, msg)
            drain()
        } else if (isHost) {
            handleProposal(msg, from)
        }
    }

    /** Hold an ordered event until its turn. BOUNDED: past the cap the buffer is dropped and a snapshot requested NOW. */
    private fun bufferEvent(seq: Int, msg: MixSyncEventMessage) {
        if (buffer[seq] == null && buffer.size >= MixSyncTunables.EVENT_BUFFER_CAP) {
            sink.log("mix event buffer full (${buffer.size}) -> dropped, snapshot")
            buffer.clear()
            gapSince = null
            awaitingSnapshotSince = null // restart the request ladder: ask at once
            nextRequestAt = Double.NEGATIVE_INFINITY
            requestSnapshot("overflow")
        }
        buffer[seq] = msg
    }

    /** Apply buffered ordered events strictly in host order. */
    private fun drain() {
        while (true) {
            val m = buffer.remove(expectedHostSeq) ?: break
            model = model.apply(m.event, session.sharedNow() ?: now).copy(hostSeq = expectedHostSeq)
            expectedHostSeq++
            if (m.event.kind == MixSyncKind.OWNER) publishOwners()
            applyOrdered(m)
        }
        gapSince = if (buffer.isEmpty()) null else (gapSince ?: now)
    }

    private fun receiveSnapshot(s: MixSyncSnapshot, from: String) {
        checkTopology()
        if (isHost || from != session.hostId) return
        // A live mix is never ended (or rolled back) by a host that doesn't have it: hand it ours instead.
        if (isActive && s.epoch != model.epoch && (!s.active || s.hostSeq < model.hostSeq)) {
            sink.log("mix snapshot from $from refused (active=${s.active} seq=${s.hostSeq} < ours=${model.hostSeq}) -> handover")
            pushHandover(from)
            return
        }
        model = MixSyncModel(s)
        publishOwners()
        expectedHostSeq = s.hostSeq + 1
        awaitingSnapshotSince = null
        snapshotAttempts = 0
        nextRequestAt = Double.NEGATIVE_INFINITY
        pending.clear()
        buffer.entries.removeAll { !(it.key > s.hostSeq && it.value.epoch == s.epoch) }
        setActive(s.active)
        if (s.active) sink.onSnapshotAdopted(model)
        drain()
    }

    /** Send my live mirror to [host], anchors re-expressed on my local clock. */
    private fun pushHandover(host: String) {
        val off = previousHostOffset
        val snap = model.snapshot()
        val decks = snap.decks.mapValues { (_, ds) ->
            val a = ds.anchor
            val at = a?.atSharedTime
            if (a != null && at != null) ds.copy(anchor = a.copy(atSharedTime = at - off)) else ds
        }
        post(
            MixWireKind.HANDOVER, MixSyncHandover.serializer(),
            MixSyncHandover(snap.copy(decks = decks), now), RemoteRecipient.Participant(host),
        )
    }

    /** HOST: a participant's live mirror. Adopt it only when mine is empty / inactive or behind it. */
    private fun receiveHandover(h: MixSyncHandover, from: String) {
        checkTopology()
        val me = localId ?: return
        if (!isHost || !h.snapshot.active) return
        if (model.active && h.snapshot.hostSeq <= model.hostSeq) return
        val m0 = MixSyncModel(h.snapshot)
        val t = now
        val decks = m0.decks.mapValues { (_, ds) ->
            var d = ds
            val a = d.anchor
            val at = a?.atSharedTime
            // "That long before the sender sent" ~ that long before now (one-way latency ignored).
            if (a != null && at != null) d = d.copy(anchor = a.copy(atSharedTime = t - (h.sentAtLocal - at)))
            if (d.owner != null && d.owner !in session.roster) d = d.copy(owner = null)
            d
        }
        sink.log("mix handover from $from adopted seq=${maxOf(m0.hostSeq, model.hostSeq) + 1}")
        model = m0.copy(epoch = me, hostSeq = maxOf(m0.hostSeq, model.hostSeq) + 1, decks = decks)
        lastProposalSeq.clear()
        publishOwners()
        setActive(true)
        sink.onSnapshotAdopted(model)
        post(MixWireKind.SNAPSHOT, MixSyncSnapshot.serializer(), model.snapshot(), RemoteRecipient.All)
    }

    private fun receiveRequest(from: String) {
        checkTopology()
        if (!isHost) return
        post(MixWireKind.SNAPSHOT, MixSyncSnapshot.serializer(), model.snapshot(), RemoteRecipient.Participant(from))
    }

    private fun receiveReady(r: MixSyncReady, from: String) {
        val m = peerReadinessMap.getOrPut(from) { HashMap() }
        if (m[r.deck] != r) m[r.deck] = r
        val d = Deck.fromLabel(r.deck)
        if (isHost && d != null && held[d] != null && ownerReady(d)) releaseHeld(d)
        if (isHost) autoAssignB()
    }

    private fun receiveReject(r: MixSyncReject, from: String) {
        if (from != session.hostId) return
        pending.entries.removeAll { it.value.seq == r.originSeq }
        statusMessage = r.reason
        sink.onStatus(r.reason)
        // The host's snapshot follows and puts the deck back.
    }

    private fun receiveBeat(b: MixSyncBeat, from: String) {
        val d = Deck.fromLabel(b.deck) ?: return
        if (!isActive || b.epoch != model.epoch || from == localId) return
        if (from != (model.owner(d) ?: session.hostId)) return
        // EVERY device keeps the deck's anchor fresh from its owner.
        if (model.deck(d).track?.songId == b.songId) {
            model = model.copy(decks = model.decks + (d to model.deck(d).copy(anchor = b.anchor)))
        }
        sink.onBeat(d, b, from)
    }

    // ---- Apply (every device, host order) ----

    private fun applyOrdered(msg: MixSyncEventMessage) {
        val e = msg.event
        when (e.kind) {
            MixSyncKind.SESSION -> {
                setActive(e.flag ?: false)
                if (isActive && !isHost) sink.onSnapshotAdopted(model)
                return
            }
            MixSyncKind.OWNER -> return // the model already moved; the UI follows it
        }
        if (!isActive) return
        if (e.kind == MixSyncKind.LOAD || e.kind == MixSyncKind.EJECT) e.engineDeck?.let { sink.onMirrorChanged(it, e.kind) }
        val key = e.controlKey
        if (msg.origin == localId) {
            if (isHost) return // the host's own gesture, applied when made
            val p = pending[key]
            if (p != null) {
                // My own gesture, already applied locally. Keep shadowing while a newer one is in flight.
                if (p.seq > msg.originSeq) return
                pending.remove(key)
                if (p.seq == msg.originSeq) return
            }
            // No mark left (expired, or a snapshot reconciled under it): the host's ordered value is the truth.
            sink.onApply(e)
            return
        }
        // My newer proposal on this control is in flight and will be ordered after this one.
        if (pending[key] != null) return
        sink.onApply(e)
    }

    private fun requestSnapshot(reason: String) {
        val host = session.hostId
        if (isHost || host == null) return
        val t = now
        if (awaitingSnapshotSince == null) {
            awaitingSnapshotSince = t
            snapshotAttempts = 0
        } else if (t < nextRequestAt) {
            return // the backoff paces it
        }
        snapshotAttempts++
        nextRequestAt = t + MixSyncTunables.SNAPSHOT_RETRY_MS * 2.0.pow((snapshotAttempts - 1).toDouble())
        post(MixWireKind.REQUEST, MixSyncRequest.serializer(), MixSyncRequest(reason), RemoteRecipient.Participant(host))
    }

    /** The local owner's own heartbeat anchor folded into the mirror (iOS mutates `model.decks[d].anchor` on send), so snapshots stay fresh. */
    fun noteLocalAnchor(deck: Deck, anchor: MixSyncAnchor) {
        model = model.copy(decks = model.decks + (deck to model.deck(deck).copy(anchor = anchor)))
    }

    /** Broadcast this device's deck readiness (`mix.ready`). */
    fun sendReady(r: MixSyncReady) = post(MixWireKind.READY, MixSyncReady.serializer(), r, RemoteRecipient.All)

    /** The owner's 2 s deck heartbeat (`mix.beat`), best-effort. */
    fun sendBeat(b: MixSyncBeat) = post(MixWireKind.BEAT, MixSyncBeat.serializer(), b, RemoteRecipient.All)

    private fun <T> post(kind: String, ser: KSerializer<T>, body: T, to: RemoteRecipient) {
        val payload = Base64.getEncoder().encodeToString(
            RemoteWire.json.encodeToString(ser, body).toByteArray(Charsets.UTF_8),
        )
        session.send(RemoteEnvelope(RemoteWire.VERSION, kind, payload), to)
    }

    companion object {
        /** Crossfader equality helper for adopters comparing the engine against a mirror. */
        fun differs(a: Double, b: Double) = abs(a - b) > 1e-6
    }
}

/** Adapts the Remote controller to [MixSyncSession] and registers the mix handlers + activity probe + caps. */
class RemoteControllerMixSession(private val c: RemoteSessionController) : MixSyncSession {
    override val localId get() = c.localId.value
    override val hostId get() = c.hostId.value
    override val isSessionActive get() = c.isActive.value
    override val isListenTogether get() = c.mode.value == RemoteSessionMode.LISTEN_TOGETHER
    override val roster get() = c.roster.value
    override fun localNow() = c.clock.localNow()
    override fun sharedNow() = c.clock.sharedNow
    override fun offsetToCurrentHost(): Double? = if (c.clock.hostId == c.hostId.value) c.clock.offsetMs else null
    override fun peerCaps(id: String) = c.peerInfo.value[id]?.caps
    override fun peerPlatform(id: String) = c.peerInfo.value[id]?.platform
    override fun peerName(id: String) = c.peers.firstOrNull { it.id == id }?.name
    override fun send(envelope: RemoteEnvelope, to: RemoteRecipient) = c.sendRaw(envelope, to)

    /** Wire [core] into the controller (handlers, host-election activity probe, the `mix` capability). */
    fun install(core: MixSyncCore, advertiseDeckOwner: Boolean = true) {
        for (k in MixWireKind.all) c.registerHandler(k) { env, from -> core.receive(env, from) }
        c.registerActivityProbe { core.isActive }
        if (advertiseDeckOwner && MixCapability.DECK_OWNER !in c.localCaps) {
            c.localCaps = c.localCaps + MixCapability.DECK_OWNER
        }
        c.registerSessionObserver { core.checkTopology() }
    }
}
