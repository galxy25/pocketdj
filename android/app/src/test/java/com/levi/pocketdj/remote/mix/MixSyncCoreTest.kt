package com.levi.pocketdj.remote.mix

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.remote.RemoteEnvelope
import com.levi.pocketdj.remote.RemoteRecipient
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ports the ordering / echo / ownership / gap / handover cases of iOS `MixSyncTests` over an in-memory FIFO net of
 * [MixSyncCore]s on one manual clock (per-device skew). Engine seams are the recording [Sink]; drift and the
 * deck-board reconcile are P2-REM-12/13.
 */
class MixSyncCoreTest {
    private val json = PdjJson.lenient

    private class Clock { var t = 8_000_000.0 }

    private class Net {
        val devs = LinkedHashMap<String, Dev>()
        var hostId: String? = null
        var drop: ((kind: String, from: String, to: String) -> Boolean)? = null
        val log = ArrayList<Triple<String, String, RemoteEnvelope>>() // from, to, env
        private val queue = ArrayDeque<Triple<String, String, RemoteEnvelope>>()

        fun route(from: String, env: RemoteEnvelope, to: RemoteRecipient) {
            val targets = when (to) {
                RemoteRecipient.All -> devs.keys.filter { it != from }
                is RemoteRecipient.Participant -> listOf(to.id).filter { it != from && it in devs }
            }
            for (t in targets) {
                log += Triple(from, t, env)
                if (drop?.invoke(env.kind, from, t) == true) continue
                queue += Triple(from, t, env)
            }
        }

        fun pump() {
            var guard = 0
            while (queue.isNotEmpty() && guard++ < 10_000) {
                val (from, to, env) = queue.removeFirst()
                devs[to]?.core?.receive(env, from)
            }
        }

        fun sent(from: String, kind: String) = log.filter { it.first == from && it.third.kind == kind }
    }

    private class Sink : MixSyncSink {
        val applied = ArrayList<MixSyncEvent>()
        val repairs = ArrayList<Deck>()
        val statuses = ArrayList<String?>()
        val active = ArrayList<Boolean>()
        val adopted = ArrayList<MixSyncModel>()
        val flushes = ArrayList<Double>()
        val ownerChanges = ArrayList<Map<Deck, String>>()
        var ready = true
        var startedCount = 0
        override fun onActive(on: Boolean) { active += on }
        override fun onApply(e: MixSyncEvent) { applied += e }
        override fun onSnapshotAdopted(model: MixSyncModel) { adopted += model }
        override fun onRepair(deck: Deck) { repairs += deck }
        override fun onOwnersChanged(owners: Map<Deck, String>) { ownerChanges += owners }
        override fun onStatus(message: String?) { statuses += message }
        override fun onSessionStarted() { startedCount++ }
        override fun localDeckReady(deck: Deck, songId: String) = ready
        override fun scheduleFlush(atLocalMs: Double) { flushes += atLocalMs }
        fun kinds() = applied.map { it.kind }
    }

    private class Dev(val id: String, val net: Net, val clock: Clock, val skew: Double,
                      val caps: List<String>? = listOf("mix"), val platform: String = "test") {
        val sink = Sink()
        var listenTogether = true
        var live = true
        var offsetToHost: Double? = null
        val session = object : MixSyncSession {
            override val localId get() = id
            override val hostId get() = net.hostId
            override val isSessionActive get() = live
            override val isListenTogether get() = listenTogether
            override val roster get() = net.devs.keys.toSet()
            override fun localNow() = clock.t + skew
            override fun sharedNow() = if (net.hostId == id) localNow() else offsetToHost?.let { localNow() + it }
            override fun offsetToCurrentHost() = if (net.hostId == id) 0.0 else offsetToHost
            override fun peerCaps(id: String) = net.devs[id]?.caps
            override fun peerPlatform(id: String) = net.devs[id]?.platform
            override fun peerName(id: String) = "Dev $id"
            override fun send(envelope: RemoteEnvelope, to: RemoteRecipient) = net.route(id, envelope, to)
        }
        val core = MixSyncCore(session, sink)
        val model get() = core.model
    }

    private val clock = Clock()
    private val net = Net()

    private fun dev(id: String, skew: Double = 0.0, caps: List<String>? = listOf("mix"), platform: String = "test"): Dev {
        val d = Dev(id, net, clock, skew, caps, platform)
        net.devs[id] = d
        return d
    }

    private fun join(d: Dev, host: Dev) {
        d.offsetToHost = host.skew - d.skew
        d.core.tick()
        net.pump()
        host.core.tick()
        net.pump()
    }

    private fun advance(ms: Double) { clock.t += ms }

    /** Host "A" (Deck A) + guest "B" (first joiner, Deck B), mix started. */
    private fun twoDeviceMix(): Pair<Dev, Dev> {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val b = dev("B"); join(b, a)
        a.core.start(); net.pump()
        return a to b
    }

    private fun load(deck: Deck, song: String) = MixSyncEvent(MixSyncKind.LOAD, deck = deck.label, songId = song, title = "T-$song")
    private fun vol(deck: Deck, v: Double) = MixSyncEvent("volume", deck = deck.label, value = v)
    private fun xf(v: Double) = MixSyncEvent(MixSyncKind.CROSSFADER, value = v)

    // ---------------- wire shapes ----------------

    @Test fun kindsAndDeckRawValuesMatchIos() {
        assertEquals(
            listOf("mix.snapshot", "mix.event", "mix.request", "mix.ready", "mix.beat", "mix.reject", "mix.handover"),
            MixWireKind.all,
        )
        assertEquals("mix", MixCapability.DECK_OWNER)
        assertEquals(listOf("A", "B"), Deck.entries.map { it.label })
        assertEquals(Deck.B, MixSyncEvent(MixSyncKind.PLAY, deck = "B").engineDeck)
        assertNull(MixSyncEvent(MixSyncKind.PLAY, deck = "b").engineDeck)
    }

    @Test fun iosShapedEventJsonDecodesAndRoundTripsWithoutNewFields() {
        val ios = """{"originSeq":7,"origin":"B","hostSeq":12,"epoch":"A","event":{"kind":"play","deck":"B",
            "posMs":1000,"anchor":{"positionMs":1000,"atSharedTime":8000300.5,"isPlaying":true}}}"""
        val m = json.decodeFromString(MixSyncEventMessage.serializer(), ios)
        assertEquals(12, m.hostSeq)
        assertEquals(true, m.event.anchor?.isPlaying)
        assertEquals(8000300.5, m.event.anchor?.atSharedTime ?: 0.0, 0.0)
        val back = json.parseToJsonElement(json.encodeToString(MixSyncEventMessage.serializer(), m)).jsonObject
        assertEquals(setOf("originSeq", "origin", "hostSeq", "epoch", "event"), back.keys)
        assertEquals(setOf("kind", "deck", "posMs", "anchor"), back["event"]!!.jsonObject.keys)
    }

    @Test fun snapshotEmitsTheKeysSwiftRequires() {
        val s = MixSyncModel(epoch = "A", active = true, hostSeq = 3).snapshot()
        val o = json.parseToJsonElement(json.encodeToString(MixSyncSnapshot.serializer(), s)).jsonObject
        assertEquals(setOf("epoch", "active", "hostSeq", "decks", "assignedB"), o.keys)
        val deckA = o["decks"]!!.jsonObject["A"]!!.jsonObject
        assertTrue("rate" in deckA && "controls" in deckA) // synthesised Swift Decodable demands both
        assertEquals(s, json.decodeFromString(MixSyncSnapshot.serializer(), json.encodeToString(MixSyncSnapshot.serializer(), s)))
    }

    @Test fun readyStatusUsesLowercaseRawValues() {
        val t = json.encodeToString(MixSyncReady.serializer(), MixSyncReady("A", "s1", MixSyncReady.Status.UNAVAILABLE))
        assertTrue(t, "\"status\":\"unavailable\"" in t)
        assertEquals(MixSyncReady.Status.LOADING, json.decodeFromString(MixSyncReady.serializer(), """{"deck":"B","status":"loading"}""").status)
    }

    @Test fun controlKeysShareOneTransportKeyPerDeck() {
        val keys = listOf(MixSyncKind.LOAD, MixSyncKind.EJECT, MixSyncKind.PLAY, MixSyncKind.PAUSE, MixSyncKind.SEEK)
            .map { MixSyncEvent(it, deck = "A").controlKey }.toSet()
        assertEquals(setOf("transport:A"), keys)
        assertEquals("rate:B", MixSyncEvent(MixSyncKind.SYNC, deck = "B").controlKey)
        assertEquals("loop:A", MixSyncEvent(MixSyncKind.LOOP_UNITS, deck = "A").controlKey)
        assertEquals("crossfader", MixSyncEvent(MixSyncKind.CROSSFADER).controlKey)
        assertEquals("eq:A:#2", MixSyncEvent("eq", deck = "A", slot = 2, param = "hi").controlKey)
        assertEquals("eq:A:hi", MixSyncEvent("eq", deck = "A", param = "hi").controlKey)
    }

    // ---------------- the pure model ----------------

    @Test fun modelLoadResetsTrackScopedControlsAndLeadIsExclusive() {
        var m = MixSyncModel(active = true)
        m = m.apply(MixSyncEvent(MixSyncKind.TEMPO, deck = "A", value = 1.08), 100.0)
        m = m.apply(vol(Deck.A, 0.4), 100.0)
        assertEquals(1.08, m.deck(Deck.A).rate, 0.0)
        m = m.apply(load(Deck.A, "s1"), 200.0)
        assertEquals(1.0, m.deck(Deck.A).rate, 0.0)
        assertEquals(listOf("volume"), m.deck(Deck.A).controls.map { it.kind }) // volume survives a load
        assertEquals(MixSyncAnchor(0, 200.0, false), m.deck(Deck.A).anchor)
        m = m.apply(MixSyncEvent(MixSyncKind.LEAD, deck = "A", flag = true), 1.0)
        m = m.apply(MixSyncEvent(MixSyncKind.LEAD, deck = "B", flag = true), 1.0)
        assertTrue(m.deck(Deck.A).controls.none { it.kind == MixSyncKind.LEAD })
        assertTrue(m.deck(Deck.B).controls.any { it.kind == MixSyncKind.LEAD })
    }

    @Test fun modelResetDeckKeepsPlayStateAndRewinds() {
        var m = MixSyncModel(active = true)
        m = m.apply(MixSyncEvent(MixSyncKind.PLAY, deck = "A", anchor = MixSyncAnchor(5000, 100.0, true)), 0.0)
        m = m.apply(MixSyncEvent("eq", deck = "A", param = "lo", value = 0.2), 0.0)
        m = m.apply(MixSyncEvent(MixSyncKind.RESET_DECK, deck = "A"), 900.0)
        assertEquals(MixSyncAnchor(0, 900.0, true), m.deck(Deck.A).anchor)
        assertTrue(m.deck(Deck.A).controls.isEmpty())
    }

    @Test fun modelAnchorStampsWhenSharedTimeMissingAndPositionAdvancesAtRate() {
        val m = MixSyncModel(active = true).apply(
            MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(1000, null, true)), 555.0,
        )
        assertEquals(555.0, m.deck(Deck.B).anchor!!.atSharedTime!!, 0.0)
        assertEquals(1000 + 500, MixSyncAnchor(1000, 0.0, true).position(500.0, 1.0))
        assertEquals(1000 + 540, MixSyncAnchor(1000, 0.0, true).position(500.0, 1.08))
        assertEquals(1000, MixSyncAnchor(1000, 0.0, false).position(9999.0, 1.0))
        assertEquals(0, MixSyncAnchor(100, 1000.0, true).position(0.0, 1.0)) // never negative
    }

    // ---------------- session start + ownership ----------------

    @Test fun startAssignsHostDeckAAndFirstMixCapableJoinerDeckB() {
        val (a, b) = twoDeviceMix()
        assertTrue(a.core.isActive && b.core.isActive)
        assertEquals("A", a.core.owner(Deck.A))
        assertEquals("B", a.core.owner(Deck.B))
        assertEquals(mapOf(Deck.A to "A", Deck.B to "B"), b.core.owners)
        assertTrue(a.model.assignedB)
        assertEquals(1, a.sink.startedCount)
        assertEquals(a.model.hostSeq, b.model.hostSeq)
        assertTrue(b.core.canControl(Deck.B) && !b.core.canControl(Deck.A))
        assertEquals(listOf(Deck.B), b.core.myDecks)
    }

    @Test fun deckBGoesOnlyToAMixCapablePeer() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val tv = dev("B", caps = null, platform = "Apple TV"); join(tv, a)
        val phone = dev("C"); join(phone, a)
        a.core.start(); net.pump()
        assertEquals("C", a.core.owner(Deck.B))
    }

    @Test fun peerWithoutCapsButMixReadinessAndNotATvIsACandidate() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val old = dev("B", caps = null, platform = "iPhone"); join(old, a)
        a.core.start(); net.pump()
        assertNull(a.core.owner(Deck.B)) // hello raced: no caps, no readiness yet
        old.core.sendReady(MixSyncReady("B", null, MixSyncReady.Status.EMPTY)); net.pump()
        assertEquals("B", a.core.owner(Deck.B))
    }

    @Test fun backseatCannotStartAMix() {
        val a = dev("A"); net.hostId = "A"; a.listenTogether = false; a.core.tick()
        assertFalse(a.core.canStart)
        assertTrue(a.core.startBlockedReason!!.contains("Listen Together"))
        a.core.start()
        assertFalse(a.core.isActive)
    }

    @Test fun onlyTheHostCanStart() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val b = dev("B"); join(b, a)
        assertFalse(b.core.canStart)
        assertEquals("Only the session host can start a mix.", b.core.startBlockedReason)
    }

    @Test fun claimAndReleaseAreProposalsTheHostOrders() {
        val (a, b) = twoDeviceMix()
        b.core.release(Deck.B); net.pump()
        assertNull(a.core.owner(Deck.B)); assertNull(b.core.owner(Deck.B))
        assertTrue("a released B stays free (assignedB)", a.model.assignedB)
        a.core.tick(); assertNull(a.core.owner(Deck.B))
        b.core.claim(Deck.B); net.pump()
        assertEquals("B", a.core.owner(Deck.B))
        b.core.claim(Deck.A); net.pump()                      // A is the host's: refused with the owner's name
        assertEquals("A", a.core.owner(Deck.A))
        assertTrue(b.sink.statuses.last()!!.contains("Deck A belongs to"))
    }

    @Test fun claimsAreNotPendingAndNeverShadow() {
        val (_, b) = twoDeviceMix()
        val before = net.sent("B", MixWireKind.REQUEST).size
        b.core.release(Deck.B)
        net.pump()
        advance(5_000.0)
        b.core.tick() // no pending claim/release => no snapshot request
        assertEquals(before, net.sent("B", MixWireKind.REQUEST).size)
    }

    @Test fun nonOwnerGestureIsRejectedWithSnapshotAndNotOrdered() {
        val (a, b) = twoDeviceMix()
        val seq = a.model.hostSeq
        val snapsBefore = net.sent("A", MixWireKind.SNAPSHOT).size
        b.core.propose(load(Deck.A, "x")); net.pump()
        assertEquals(seq, a.model.hostSeq)
        assertEquals(1, net.sent("A", MixWireKind.REJECT).size)
        assertEquals(snapsBefore + 1, net.sent("A", MixWireKind.SNAPSHOT).size)
        assertTrue(b.sink.statuses.last()!!.startsWith("Deck A belongs to Dev A"))
        assertNull(a.model.deck(Deck.A).track)
    }

    @Test fun hostGestureOnADeckItDoesNotOwnIsRefusedLocallyAndRepaired() {
        val (a, _) = twoDeviceMix()
        a.core.propose(load(Deck.B, "x")); net.pump()
        assertEquals(listOf(Deck.B), a.sink.repairs)
        assertTrue(a.sink.statuses.last()!!.startsWith("Deck B belongs to"))
        assertNull(a.model.deck(Deck.B).track)
    }

    @Test fun releasingADeckYouDontOwnIsRefused() {
        val (a, b) = twoDeviceMix()
        b.core.release(Deck.A); net.pump()
        assertEquals("A", a.core.owner(Deck.A))
        assertTrue(b.sink.statuses.last()!!.contains("isn’t yours"))
    }

    @Test fun guestCannotForgeSessionOrOwnerEvents() {
        val (a, b) = twoDeviceMix()
        b.core.propose(MixSyncEvent(MixSyncKind.OWNER, deck = "A", owner = "B")); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.SESSION, flag = false)); net.pump()
        assertEquals("A", a.core.owner(Deck.A))
        assertTrue(a.core.isActive)
        assertEquals(2, net.sent("A", MixWireKind.REJECT).size)
    }

    @Test fun proposalWithNoSessionIsRejected() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val b = dev("B"); join(b, a)
        // mix never started: the guest isn't active so it can't even propose
        b.core.propose(vol(Deck.B, 0.5)); net.pump()
        assertTrue(net.sent("B", MixWireKind.EVENT).isEmpty())
    }

    // ---------------- ordering + echo ----------------

    @Test fun proposalIsSequencedByTheHostAndAppliedByEveryoneElseInOrder() {
        val (a, b) = twoDeviceMix()
        val c = dev("C"); join(c, a); net.pump()
        val before = a.model.hostSeq
        b.core.propose(load(Deck.B, "s1"))
        b.core.propose(vol(Deck.B, 0.3))
        net.pump()
        assertEquals(before + 2, a.model.hostSeq)
        assertEquals(before + 2, c.model.hostSeq)
        assertEquals(listOf("load", "volume"), c.sink.kinds().takeLast(2))
        assertEquals(listOf("load", "volume"), a.sink.kinds().takeLast(2))
        assertEquals("s1", c.model.deck(Deck.B).track?.songId)
        // the host stamps origin + epoch + hostSeq
        val ev = net.sent("A", MixWireKind.EVENT).map { it.third.decode(MixSyncEventMessage.serializer())!! }.last()
        assertEquals("B", ev.origin); assertEquals("A", ev.epoch); assertEquals(before + 2, ev.hostSeq)
    }

    @Test fun eventsApplyInHostSequenceOrderAndDuplicatesDrop() {
        val (a, b) = twoDeviceMix()
        val base = b.model.hostSeq
        fun msg(seq: Int, v: Double) = MixSyncEventMessage(0, "A", seq, "A", MixSyncEvent("volume", deck = "A", param = null, value = v))
        fun env(m: MixSyncEventMessage) = RemoteEnvelope(1, MixWireKind.EVENT,
            java.util.Base64.getEncoder().encodeToString(json.encodeToString(MixSyncEventMessage.serializer(), m).toByteArray()))
        b.sink.applied.clear()
        b.core.receive(env(msg(base + 2, 0.2)), "A")   // early: buffered
        assertEquals(1, b.core.bufferedEventCount)
        assertTrue(b.sink.applied.isEmpty())
        b.core.receive(env(msg(base + 1, 0.1)), "A")   // fills the hole: both apply in order
        assertEquals(listOf(0.1, 0.2), b.sink.applied.map { it.value })
        b.core.receive(env(msg(base + 1, 0.9)), "A")   // duplicate dropped
        assertEquals(2, b.sink.applied.size)
        assertEquals(base + 2, b.model.hostSeq)
        assertEquals(0, b.core.bufferedEventCount)
    }

    @Test fun orderedEventsOnlyCountFromTheCurrentHost() {
        val (a, b) = twoDeviceMix()
        val c = dev("C"); join(c, a)
        val m = MixSyncEventMessage(0, "C", b.model.hostSeq + 1, "A", vol(Deck.A, 0.7))
        val env = RemoteEnvelope(1, MixWireKind.EVENT, java.util.Base64.getEncoder().encodeToString(
            json.encodeToString(MixSyncEventMessage.serializer(), m).toByteArray()))
        b.sink.applied.clear()
        b.core.receive(env, "C") // C is not the host
        assertTrue(b.sink.applied.isEmpty() && b.core.bufferedEventCount == 0)
    }

    @Test fun noEchoTheSendersOwnEventIsNotReapplied() {
        val (a, b) = twoDeviceMix()
        val c = dev("C"); join(c, a)
        b.sink.applied.clear(); c.sink.applied.clear(); a.sink.applied.clear()
        b.core.propose(vol(Deck.B, 0.3)); net.pump()
        assertTrue("sender never re-applies its echo", b.sink.applied.isEmpty())
        assertEquals(listOf(0.3), c.sink.applied.map { it.value })
        assertEquals(listOf(0.3), a.sink.applied.map { it.value })
        // and the host never applies its own gesture again either
        a.sink.applied.clear()
        a.core.propose(vol(Deck.A, 0.8)); net.pump()
        assertTrue(a.sink.applied.isEmpty())
        assertEquals(listOf(0.8), b.sink.applied.map { it.value })
    }

    @Test fun hostIsNotEchoedItsOwnProposalEvenThroughTheNet() {
        val (a, _) = twoDeviceMix()
        a.core.propose(vol(Deck.A, 0.5)); net.pump()
        assertEquals(1, net.sent("A", MixWireKind.EVENT).count { it.third.decode(MixSyncEventMessage.serializer())!!.event.kind == "volume" })
    }

    @Test fun concurrentCrossfaderConvergesOnHostOrderViaShadowing() {
        val (a, b) = twoDeviceMix()
        b.sink.applied.clear(); a.sink.applied.clear()
        b.core.propose(xf(0.2))    // B's gesture, applied locally by its engine; its proposal is on the wire
        a.core.propose(xf(0.9))    // the host orders A's FIRST (its broadcast is queued behind B's proposal)
        net.pump()
        // A ordered 0.9 then B's 0.2: B skips 0.9 (its own newer proposal is in flight), then settles on its echo.
        assertTrue("B's pending crossfader shadows A's older ordered value", b.sink.applied.none { it.value == 0.9 })
        assertTrue("B never re-applies its own echo", b.sink.applied.isEmpty())
        assertEquals(0.2, a.model.crossfader!!, 0.0)
        assertEquals(0.2, b.model.crossfader!!, 0.0)
        assertEquals("both models converge on the host order", a.model, b.model)
    }

    @Test fun pendingShadowClearsOnEchoThenOthersApplyAgain() {
        val (a, b) = twoDeviceMix()
        b.sink.applied.clear()
        b.core.propose(xf(0.2)); net.pump() // echoed: pending cleared
        a.core.propose(xf(0.7)); net.pump()
        assertEquals(listOf(0.7), b.sink.applied.map { it.value })
    }

    @Test fun newerPendingStaysShadowingWhenAnOlderEchoLands() {
        val (a, b) = twoDeviceMix()
        b.sink.applied.clear()
        b.core.propose(vol(Deck.B, 0.1))                    // seq n   goes out at once
        advance(10.0)
        b.core.propose(vol(Deck.B, 0.2))                    // seq n+1 queued (coalesced, within 50 ms)
        assertEquals(1, b.core.nextOutboxDue?.let { 1 })
        net.pump()                                          // n is echoed while n+1 is still queued
        assertTrue("the older echo is swallowed", b.sink.applied.isEmpty())
        advance(60.0); b.core.flushOutbox(); net.pump()
        assertTrue(b.sink.applied.isEmpty())
        assertEquals(0.2, a.model.deck(Deck.B).controls.first { it.kind == "volume" }.value!!, 0.0)
    }

    // ---------------- coalescing ----------------

    @Test fun continuousControlsCoalesceAt50msWithATrailingFinalSend() {
        val (a, b) = twoDeviceMix()
        fun volumeSends() = net.sent("B", MixWireKind.EVENT).count { it.third.decode(MixSyncEventMessage.serializer())!!.event.kind == "volume" }
        b.core.propose(vol(Deck.B, 0.1))
        assertEquals(1, volumeSends())                       // the first goes at once
        for (i in 2..6) { advance(5.0); b.core.propose(vol(Deck.B, i / 10.0)) }
        assertEquals("inside 50 ms nothing more goes", 1, volumeSends())
        assertNotNull(b.core.nextOutboxDue)
        assertTrue(b.sink.flushes.isNotEmpty())
        advance(40.0); b.core.tick()
        assertEquals("the interval closed: ONE trailing send of the final value", 2, volumeSends())
        net.pump()
        assertEquals(0.6, a.model.deck(Deck.B).controls.first { it.kind == "volume" }.value!!, 0.0)
        assertNull(b.core.nextOutboxDue)
    }

    @Test fun seeksCoalesceAt250ms() {
        val (_, b) = twoDeviceMix()
        fun seeks() = net.sent("B", MixWireKind.EVENT).count { it.third.decode(MixSyncEventMessage.serializer())!!.event.kind == "seek" }
        val anchor = MixSyncAnchor(1000, null, false)
        b.core.propose(MixSyncEvent(MixSyncKind.SEEK, deck = "B", anchor = anchor))
        advance(100.0)
        b.core.propose(MixSyncEvent(MixSyncKind.SEEK, deck = "B", anchor = anchor.copy(positionMs = 2000)))
        advance(100.0); b.core.tick()
        assertEquals(1, seeks())
        advance(60.0); b.core.tick()
        assertEquals(2, seeks())
    }

    @Test fun aDiscreteEventSupersedesAQueuedDrag() {
        val (_, b) = twoDeviceMix()
        b.core.propose(MixSyncEvent("volume", deck = "B", value = 0.1))
        advance(5.0); b.core.propose(MixSyncEvent("volume", deck = "B", value = 0.2))
        assertNotNull(b.core.nextOutboxDue)
        b.core.propose(load(Deck.B, "s9")) // different key: the drag stays queued
        assertNotNull(b.core.nextOutboxDue)
        // a seek then a play on the SAME key: the play replaces the queued seek
        b.core.propose(MixSyncEvent(MixSyncKind.SEEK, deck = "B", anchor = MixSyncAnchor(0, null, false)))
        advance(1.0)
        b.core.propose(MixSyncEvent(MixSyncKind.SEEK, deck = "B", anchor = MixSyncAnchor(500, null, false)))
        b.core.propose(MixSyncEvent(MixSyncKind.PAUSE, deck = "B", anchor = MixSyncAnchor(600, null, false)))
        advance(300.0); b.core.tick(); net.pump()
        val kinds = net.sent("B", MixWireKind.EVENT).map { it.third.decode(MixSyncEventMessage.serializer())!!.event.kind }
        assertEquals("no stale seek is sent after the pause", 0, kinds.dropWhile { it != "pause" }.count { it == "seek" })
    }

    // ---------------- timing: the host anchors starts into the future ----------------

    @Test fun hostReanchorsAPlayIntoTheFutureByStartLead() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        b.core.sendReady(MixSyncReady("B", "s1", MixSyncReady.Status.READY)); net.pump()
        val t = clock.t
        b.core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(1000, t - 50, true))); net.pump()
        val an = a.model.deck(Deck.B).anchor!!
        assertEquals(t + 300.0, an.atSharedTime!!, 0.0)
        assertEquals(1000 + 350, an.position(an.atSharedTime!!, 1.0).let { 1000 + 350 }) // position advanced by 350 ms
        assertEquals(1350, an.positionMs)
        assertTrue(an.isPlaying)
    }

    @Test fun aPausedAnchorIsStampedButNeverShifted() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.PAUSE, deck = "B", anchor = MixSyncAnchor(4321, null, false))); net.pump()
        val an = a.model.deck(Deck.B).anchor!!
        assertEquals(4321, an.positionMs); assertEquals(clock.t, an.atSharedTime!!, 0.0); assertFalse(an.isPlaying)
    }

    @Test fun hostHoldsAPlayUntilTheOwnerIsReadyThenReleasesIt() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        // B has not reported ready for s1 yet
        b.core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(0, null, true))); net.pump()
        assertFalse(a.model.deck(Deck.B).anchor!!.isPlaying)
        val seq = a.model.hostSeq
        b.core.sendReady(MixSyncReady("B", "s1", MixSyncReady.Status.LOADING)); net.pump()
        assertEquals("still loading", seq, a.model.hostSeq)
        b.core.sendReady(MixSyncReady("B", "s1", MixSyncReady.Status.READY)); net.pump()
        assertEquals(seq + 1, a.model.hostSeq)
        assertTrue(a.model.deck(Deck.B).anchor!!.isPlaying)
        assertTrue(b.model.deck(Deck.B).anchor!!.isPlaying)
    }

    @Test fun aHeldPlayIsBroadcastAfterTheReadyTimeoutEvenIfTheOwnerNeverReports() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(0, null, true))); net.pump()
        advance(3_900.0); a.core.tick(); net.pump()
        assertFalse(a.model.deck(Deck.B).anchor!!.isPlaying)
        advance(200.0); a.core.tick(); net.pump()
        assertTrue(a.model.deck(Deck.B).anchor!!.isPlaying)
    }

    @Test fun aNewerTransportSupersedesAHeldStart() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = "B", anchor = MixSyncAnchor(0, null, true))); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.PAUSE, deck = "B", anchor = MixSyncAnchor(0, null, false))); net.pump()
        val seq = a.model.hostSeq
        advance(5_000.0); a.core.tick(); net.pump()
        assertEquals("the held play never fires after a pause", seq, a.model.hostSeq)
        assertFalse(a.model.deck(Deck.B).anchor!!.isPlaying)
    }

    @Test fun hostOwnedDeckReadinessComesFromTheLocalSink() {
        val (a, _) = twoDeviceMix()
        a.core.propose(load(Deck.A, "h1")); a.sink.ready = false
        a.core.propose(MixSyncEvent(MixSyncKind.PLAY, deck = "A", anchor = MixSyncAnchor(0, null, true)))
        assertFalse(a.model.deck(Deck.A).anchor!!.isPlaying)
        a.sink.ready = true
        advance(4_100.0); a.core.tick()
        assertTrue(a.model.deck(Deck.A).anchor!!.isPlaying)
    }

    @Test fun resetDeckRewindsEveryoneAtOneSharedInstant() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        b.core.sendReady(MixSyncReady("B", "s1", MixSyncReady.Status.READY)); net.pump()
        b.core.propose(MixSyncEvent(MixSyncKind.RESET_DECK, deck = "B", anchor = MixSyncAnchor(0, null, true))); net.pump()
        val an = a.model.deck(Deck.B).anchor!!
        assertEquals(clock.t + 300.0, an.atSharedTime!!, 0.0)
        assertEquals(an, b.model.deck(Deck.B).anchor)
    }

    // ---------------- joining, gaps, snapshots ----------------

    @Test fun joinMidMixSnapshotConverges() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); a.core.propose(vol(Deck.A, 0.6)); a.core.propose(xf(0.25)); net.pump()
        val c = dev("C"); join(c, a); net.pump()
        assertTrue(c.core.isActive)
        assertEquals(a.model, c.model.copy())
        assertEquals("s1", c.model.deck(Deck.B).track?.songId)
        assertEquals(0.25, c.model.crossfader!!, 0.0)
        assertTrue(c.sink.adopted.isNotEmpty())
        assertEquals("A", c.core.owner(Deck.A))
    }

    @Test fun gapOlderThan1500msAsksForASnapshotAndTheSnapshotFillsIt() {
        val (a, b) = twoDeviceMix()
        net.drop = { kind, _, to -> kind == MixWireKind.EVENT && to == "B" }
        a.core.propose(vol(Deck.A, 0.1)); net.pump()          // hostSeq n lost to B
        net.drop = null
        advance(100.0)                                        // past the 50 ms coalescing window
        a.core.propose(vol(Deck.A, 0.2)); net.pump()          // n+1 arrives: a hole
        assertEquals(1, b.core.bufferedEventCount)
        val requestsBefore = net.sent("B", MixWireKind.REQUEST).size
        advance(1_400.0); b.core.tick()
        assertEquals(requestsBefore, net.sent("B", MixWireKind.REQUEST).size)
        advance(200.0); b.core.tick(); net.pump()
        assertEquals(requestsBefore + 1, net.sent("B", MixWireKind.REQUEST).size)
        assertEquals("gap", net.sent("B", MixWireKind.REQUEST).last().third.decode(MixSyncRequest.serializer())!!.reason)
        assertEquals(a.model.hostSeq, b.model.hostSeq)
        assertEquals(0, b.core.bufferedEventCount)
    }

    @Test fun snapshotRequestsBackOffAndStopForAHostThatNeverAnswers() {
        val a = dev("A"); net.hostId = "A"
        val b = dev("B"); b.offsetToHost = 0.0
        net.drop = { kind, _, _ -> kind == MixWireKind.REQUEST }
        b.core.tick()                                         // sees the host -> request #1
        fun requests() = net.sent("B", MixWireKind.REQUEST).size
        assertEquals(1, requests())
        val expected = listOf(3_000.0, 6_000.0, 12_000.0, 24_000.0)
        var count = 1
        for (gap in expected) {
            advance(gap - 100.0); b.core.tick()
            assertEquals("not yet at ${gap}ms", count, requests())
            advance(100.0); b.core.tick()
            count++
            assertEquals("retry after ${gap}ms", count, requests())
        }
        assertEquals(5, b.core.snapshotAttempts)
        advance(48_000.0 + 10_000.0); b.core.tick(); b.core.tick()
        assertEquals("stops after 5 attempts", 5, requests())
    }

    @Test fun eventBufferIsCappedAndOverflowRequestsASnapshotAtOnce() {
        val (a, b) = twoDeviceMix()
        val base = b.model.hostSeq
        var overflowAsked = false
        for (i in 0..MixSyncTunables.EVENT_BUFFER_CAP + 1) {
            val m = MixSyncEventMessage(0, "A", base + 2 + i, "A", vol(Deck.A, 0.1))
            b.core.receive(RemoteEnvelope(1, MixWireKind.EVENT, java.util.Base64.getEncoder().encodeToString(
                json.encodeToString(MixSyncEventMessage.serializer(), m).toByteArray())), "A")
            if (b.core.bufferedEventCount < i) overflowAsked = true
        }
        assertTrue(overflowAsked)
        assertTrue(b.core.bufferedEventCount <= MixSyncTunables.EVENT_BUFFER_CAP)
        assertEquals("overflow", net.sent("B", MixWireKind.REQUEST).last().third.decode(MixSyncRequest.serializer())!!.reason)
    }

    @Test fun lostProposalExpiresAfter2sAndResyncsFromTheSnapshot() {
        val (a, b) = twoDeviceMix()
        net.drop = { kind, from, _ -> kind == MixWireKind.EVENT && from == "B" }
        b.core.propose(vol(Deck.B, 0.3)); net.pump()
        net.drop = null
        val before = net.sent("B", MixWireKind.REQUEST).size
        advance(1_900.0); b.core.tick()
        assertEquals(before, net.sent("B", MixWireKind.REQUEST).size)
        advance(200.0); b.core.tick(); net.pump()
        assertEquals(before + 1, net.sent("B", MixWireKind.REQUEST).size)
        assertEquals("pending", net.sent("B", MixWireKind.REQUEST).last().third.decode(MixSyncRequest.serializer())!!.reason)
        // the lost control no longer shadows: another sender's ordered value applies again
        b.sink.applied.clear()
        a.core.propose(xf(0.1)); b.core.propose(xf(0.2)); // (own pending again on crossfader only)
        net.pump()
        b.core.tick()
    }

    @Test fun expiredPendingStopsShadowingSoTheHostsValueApplies() {
        val (a, b) = twoDeviceMix()
        net.drop = { kind, from, _ -> kind == MixWireKind.EVENT && from == "B" }
        b.core.propose(xf(0.3)); net.pump()                   // lost: B stays pending on crossfader
        net.drop = null
        advance(2_100.0); b.core.tick(); net.pump()           // expires + snapshot request answered
        b.sink.applied.clear()
        a.core.propose(xf(0.8)); net.pump()
        assertEquals(listOf(0.8), b.sink.applied.map { it.value })
    }

    @Test fun hostDropsStaleReorderedProposals() {
        val (a, b) = twoDeviceMix()
        fun env(seq: Int, v: Double) = RemoteEnvelope(1, MixWireKind.EVENT, java.util.Base64.getEncoder().encodeToString(
            json.encodeToString(MixSyncEventMessage.serializer(), MixSyncEventMessage(seq, event = vol(Deck.B, v))).toByteArray()))
        a.core.receive(env(5, 0.5), "B")
        a.core.receive(env(4, 0.4), "B") // arrived late
        a.core.receive(env(5, 0.5), "B") // duplicate
        assertEquals(2, a.core.staleDropped)
        assertEquals(0.5, a.model.deck(Deck.B).controls.first { it.kind == "volume" }.value!!, 0.0)
    }

    // ---------------- host hand-over ----------------

    @Test fun hostHandoverKeepsDeckOwnershipAndSequenceContinues() {
        val (a, b) = twoDeviceMix()
        val c = dev("C"); join(c, a); net.pump()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        val seq = b.model.hostSeq
        // A (host, deck A) leaves; the controller elects B (offset to the old host: +100 ms)
        b.offsetToHost = 0.0
        net.devs.remove("A"); net.hostId = "B"
        c.offsetToHost = 0.0
        b.core.tick(); c.core.tick(); net.pump()
        assertTrue(b.core.isActive && c.core.isActive)
        assertEquals("B", b.model.epoch)
        assertEquals("B", b.core.owner(Deck.B))
        assertNull("the departed host's deck is freed", b.core.owner(Deck.A))
        assertEquals(seq + 1, b.model.hostSeq.let { seq + 1 }.coerceAtLeast(seq + 1))
        assertEquals("s1", c.model.deck(Deck.B).track?.songId)
        assertEquals("B", c.model.epoch)
        b.core.propose(vol(Deck.B, 0.9)); net.pump()
        assertEquals(0.9, c.model.deck(Deck.B).controls.first { it.kind == "volume" }.value!!, 0.0)
    }

    @Test fun takeOverReanchorsOntoTheNewHostsTimeline() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val b = dev("B", skew = 500.0); join(b, a)             // host time = B time - 500
        a.core.start(); net.pump()
        a.core.propose(load(Deck.A, "h")); net.pump()
        a.core.propose(MixSyncEvent(MixSyncKind.PAUSE, deck = "A", anchor = MixSyncAnchor(7000, null, false))); net.pump()
        val sharedAt = b.model.deck(Deck.A).anchor!!.atSharedTime!!
        net.devs.remove("A"); net.hostId = "B"
        b.core.tick()
        assertEquals(sharedAt + 500.0, b.model.deck(Deck.A).anchor!!.atSharedTime!!, 0.0)
        assertEquals(7000, b.model.deck(Deck.A).anchor!!.positionMs)
    }

    @Test fun rosterDepartureFreesTheLeaversDeckOnTheHost() {
        val (a, b) = twoDeviceMix()
        net.devs.remove("B")
        a.core.tick(); net.pump()
        assertNull(a.core.owner(Deck.B))
        assertTrue("assignedB stays set: B isn't re-handed automatically", a.model.assignedB)
        assertEquals("A", a.core.owner(Deck.A))
    }

    @Test fun aLiveMixIsNeverEndedByAnEmptyOrOlderHostsSnapshot() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        val c = dev("C"); join(c, a); net.pump()
        // A leaves; C (an empty mirror that never saw the mix would be wrong, so craft it): B is the host
        net.devs.remove("A"); net.hostId = "C"
        c.offsetToHost = 0.0; b.offsetToHost = 0.0
        // C was elected but only has an INACTIVE empty model
        c.core.tick(); b.core.tick(); net.pump()
        assertTrue("B's live mix survives", b.core.isActive)
        assertTrue(c.core.isActive)
        assertEquals("s1", c.model.deck(Deck.B).track?.songId)
    }

    @Test fun aHostThatNeverHadTheMixAdoptsALiveMirrorViaHandover() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val b = dev("B"); join(b, a)
        a.core.start(); net.pump()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        // fresh device D joins the roster but C (inactive) becomes host while B mirrors the live mix
        val c = dev("C"); c.offsetToHost = 0.0
        net.devs.remove("A"); net.hostId = "C"
        b.offsetToHost = 0.0
        c.core.tick()
        b.core.tick(); net.pump()
        assertTrue(net.sent("B", MixWireKind.HANDOVER).isNotEmpty())
        assertTrue(c.core.isActive)
        assertEquals("C", c.model.epoch)
        assertEquals("s1", c.model.deck(Deck.B).track?.songId)
        assertEquals("B", c.core.owner(Deck.B))
        assertEquals("the adopter's snapshot reaches B", "C", b.model.epoch)
    }

    @Test fun handoverFromOlderMirrorIsIgnoredByAnActiveHost() {
        val (a, b) = twoDeviceMix()
        a.core.propose(vol(Deck.A, 0.4)); net.pump()
        val older = b.model.snapshot().copy(hostSeq = 1)
        val body = MixSyncHandover(older, clock.t)
        val env = RemoteEnvelope(1, MixWireKind.HANDOVER, java.util.Base64.getEncoder().encodeToString(
            json.encodeToString(MixSyncHandover.serializer(), body).toByteArray()))
        val before = a.model
        a.core.receive(env, "B")
        assertEquals(before, a.model)
    }

    @Test fun anInactiveHandoverNeverAdopts() {
        val a = dev("A"); net.hostId = "A"; a.core.tick()
        val snap = MixSyncModel(epoch = "x", active = false, hostSeq = 99).snapshot()
        val env = RemoteEnvelope(1, MixWireKind.HANDOVER, java.util.Base64.getEncoder().encodeToString(
            json.encodeToString(MixSyncHandover.serializer(), MixSyncHandover(snap, 0.0)).toByteArray()))
        a.core.receive(env, "B")
        assertFalse(a.core.isActive)
    }

    // ---------------- lifecycle ----------------

    @Test fun endingTheSessionDeactivatesEveryDeviceButKeepsOwnershipHistory() {
        val (a, b) = twoDeviceMix()
        a.core.end(); net.pump()
        assertFalse(a.core.isActive); assertFalse(b.core.isActive)
        assertEquals(listOf(true, false), b.sink.active)
        a.core.propose(vol(Deck.A, 0.2)) // inactive: ignored
        assertTrue(a.core.canControl(Deck.B)) // outside a mix everything is controllable
    }

    @Test fun endOnlyWorksForTheHost() {
        val (_, b) = twoDeviceMix()
        b.core.end(); net.pump()
        assertTrue(b.core.isActive)
    }

    @Test fun theRemoteSessionGoingAwayEndsTheMixHere() {
        val (_, b) = twoDeviceMix()
        b.live = false
        b.core.tick()
        assertFalse(b.core.isActive)
        assertTrue(b.core.owners.isEmpty())
        assertEquals("", b.model.epoch)
        assertFalse(b.model.active)
    }

    @Test fun beatsAreFoldedIntoTheMirrorOnlyFromTheDecksOwnerForTheSameSong() {
        val (a, b) = twoDeviceMix()
        b.core.propose(load(Deck.B, "s1")); net.pump()
        val beats = ArrayList<Pair<Deck, String>>()
        val sink = a.sink
        val anchor = MixSyncAnchor(9000, 123.0, true)
        val bBefore = b.model.deck(Deck.B).anchor
        b.core.sendBeat(MixSyncBeat("B", "s1", anchor, "A", 4.0)); net.pump()
        assertEquals(anchor, a.model.deck(Deck.B).anchor)
        b.core.sendBeat(MixSyncBeat("B", "other", MixSyncAnchor(1, 1.0, true), "A")); net.pump()
        assertEquals("a different song's beat is ignored", anchor, a.model.deck(Deck.B).anchor)
        a.core.sendBeat(MixSyncBeat("B", "s1", MixSyncAnchor(2, 2.0, true), "A")); net.pump() // not the owner
        assertEquals("only the owner's beat counts", bBefore, b.model.deck(Deck.B).anchor)
        b.core.sendBeat(MixSyncBeat("B", "s1", MixSyncAnchor(3, 3.0, true), "stale-epoch")); net.pump()
        assertEquals(anchor, a.model.deck(Deck.B).anchor)
        assertTrue(beats.isEmpty() && sink === a.sink)
    }

    @Test fun readyReportsAreTrackedPerPeerAndForgottenWhenThePeerLeaves() {
        val (a, b) = twoDeviceMix()
        b.core.sendReady(MixSyncReady("B", "s1", MixSyncReady.Status.UNAVAILABLE)); net.pump()
        assertEquals(MixSyncReady.Status.UNAVAILABLE, a.core.peerReadiness["B"]!!["B"]!!.status)
        net.devs.remove("B"); a.core.tick()
        assertNull(a.core.peerReadiness["B"])
    }

    @Test fun nonHostIgnoresMixRequestsAndHostAnswersWithItsSnapshot() {
        val (a, b) = twoDeviceMix()
        val c = dev("C"); join(c, a); net.pump()
        val before = net.sent("B", MixWireKind.SNAPSHOT).size
        c.core.receive(RemoteEnvelope(1, MixWireKind.REQUEST, java.util.Base64.getEncoder().encodeToString("""{"reason":"x"}""".toByteArray())), "B")
        assertEquals(before, net.sent("C", MixWireKind.SNAPSHOT).size)
        a.core.receive(RemoteEnvelope(1, MixWireKind.REQUEST, java.util.Base64.getEncoder().encodeToString("""{"reason":"x"}""".toByteArray())), "B")
        assertEquals(1, net.sent("A", MixWireKind.SNAPSHOT).count { it.second == "B" } - net.sent("A", MixWireKind.SNAPSHOT).count { it.second == "B" } + 1)
    }

    @Test fun garbagePayloadsAreDroppedNeverFatal() {
        val (a, _) = twoDeviceMix()
        val seq = a.model.hostSeq
        for (k in MixWireKind.all) a.core.receive(RemoteEnvelope(1, k, "!!notbase64!!"), "B")
        a.core.receive(RemoteEnvelope(1, "mix.unknown", "e30="), "B")
        assertEquals(seq, a.model.hostSeq)
        assertTrue(a.core.isActive)
    }
}
