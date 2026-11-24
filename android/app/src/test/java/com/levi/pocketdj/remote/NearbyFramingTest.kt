package com.levi.pocketdj.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** An in-memory "radio": fake Nearby clients that advertise, discover, connect and exchange payloads like P2P_STAR. */
private class FakeNearbyNet {
    val clients = ArrayList<FakeClient>()
    private var n = 0

    fun client(): FakeClient = FakeClient("ep-${++n}").also { clients += it }

    inner class FakeClient(val endpointId: String) : NearbyClient {
        override var listener: NearbyListener? = null
        var advertisedName: String? = null
        var discovering = false
        val accepted = HashSet<String>()
        val connected = HashSet<String>()
        val pendingWith = HashSet<String>()
        val sentFrames = ArrayList<Pair<String, ByteArray>>()
        var vanished = false

        override fun startAdvertising(endpointName: String, onResult: (Throwable?) -> Unit) {
            advertisedName = endpointName
            onResult(null)
            clients.filter { it.discovering && !it.vanished }.forEach { it.listener?.onEndpointFound(endpointId, endpointName) }
        }
        override fun stopAdvertising() { advertisedName = null }
        override fun startDiscovery(onResult: (Throwable?) -> Unit) {
            discovering = true
            onResult(null)
            clients.filter { it !== this && it.advertisedName != null && !it.vanished }.forEach { listener?.onEndpointFound(it.endpointId, it.advertisedName!!) }
        }
        override fun stopDiscovery() { discovering = false }
        override fun requestConnection(localName: String, endpointId: String) {
            val host = clients.first { it.endpointId == endpointId }
            pendingWith += endpointId; host.pendingWith += this.endpointId
            host.listener?.onConnectionInitiated(this.endpointId, localName, "4821", true)
            listener?.onConnectionInitiated(endpointId, host.advertisedName ?: "?", "4821", false)
        }
        override fun acceptConnection(endpointId: String) {
            accepted += endpointId
            val other = clients.first { it.endpointId == endpointId }
            if (this.endpointId in other.accepted) {
                connected += endpointId; other.connected += this.endpointId
                other.listener?.onConnectionResult(this.endpointId, true)
                listener?.onConnectionResult(endpointId, true)
            }
        }
        override fun rejectConnection(endpointId: String) {
            val other = clients.first { it.endpointId == endpointId }
            other.listener?.onConnectionResult(this.endpointId, false)
            listener?.onConnectionResult(endpointId, false)
        }
        override fun send(endpointId: String, bytes: ByteArray) {
            sentFrames += endpointId to bytes
            clients.firstOrNull { it.endpointId == endpointId && !it.vanished }?.listener?.onPayload(this.endpointId, bytes)
        }
        override fun disconnect(endpointId: String) {
            connected -= endpointId
            clients.firstOrNull { it.endpointId == endpointId }?.let { it.connected -= this.endpointId; it.listener?.onDisconnected(this.endpointId) }
        }
        override fun stopAll() {
            advertisedName = null; discovering = false
            for (ep in connected.toList()) disconnect(ep)
        }
        fun vanish() { vanished = true; advertisedName = null; listener = null }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class NearbyFramingTest {
    private val hash = NearbyInvite.hash("ABCD2345")
    private fun env(tag: String) = RemoteEnvelope(1, RemoteMessageKind.COMMAND.wire, tag)

    private fun TestScope.collecting(t: NearbyRemoteTransport, into: MutableList<RemoteInbound>) {
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { t.inbound.collect { into += it } }
    }

    private fun TestScope.transport(
        net: FakeNearbyNet, id: String, hash: String = this@NearbyFramingTest.hash, open: Boolean = true,
        scope: CoroutineScope = backgroundScope, migrateMs: Long = 15_000,
    ) = NearbyRemoteTransport(net.client(), id, "Dev-$id", RemoteSessionMode.LISTEN_TOGETHER, hash, scope, open, migrateMs)

    private fun host(t: NearbyRemoteTransport) { t.startHosting() }

    private fun TestScope.session(vararg joinerIds: String, hostId: String = "m"): List<Triple<NearbyRemoteTransport, MutableList<RemoteInbound>, String>> {
        val net = FakeNearbyNet()
        val h = transport(net, hostId)
        host(h)
        val out = ArrayList<Triple<NearbyRemoteTransport, MutableList<RemoteInbound>, String>>()
        val hLog = ArrayList<RemoteInbound>().also { collecting(h, it) }
        out += Triple(h, hLog, hostId)
        for (id in joinerIds) {
            val j = transport(net, id)
            val log = ArrayList<RemoteInbound>().also { collecting(j, it) }
            j.joinByHash()
            out += Triple(j, log, id)
        }
        return out
    }

    @Test fun firstFrameBindsEndpointsToSessionIdsNotEndpointIds() = runTest {
        val s = session("b")
        val (host, _, _) = s[0]; val (joiner, _, _) = s[1]
        assertTrue(joiner.linked.isCompleted)
        assertEquals(setOf("m", "b"), host.participants.value)
        assertEquals(setOf("m", "b"), joiner.participants.value)
        assertTrue(host.participants.value.none { it.startsWith("ep-") })
    }

    @Test fun theHandshakeFrameIsTheFirstFrameEachSideSends() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val jt = transport(net, "b"); jt.joinByHash()
        for (c in net.clients) {
            val first = NearbyFrames.decode(c.sentFrames.first().second)
            assertTrue("first frame must be hi, was $first", first is NearbyFrame.Hi)
        }
        assertEquals("m", (NearbyFrames.decode(net.clients[0].sentFrames.first().second) as NearbyFrame.Hi).id)
        assertEquals("b", (NearbyFrames.decode(net.clients[1].sentFrames.first().second) as NearbyFrame.Hi).id)
    }

    @Test fun aWrongTokenHashIsRejectedAtTheConnectionRequest() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val intruder = transport(net, "x", hash = NearbyInvite.hash("ZZZZ9999"))
        intruder.joinEndpoint(net.clients[0].endpointId)
        assertTrue(intruder.linked.isCompleted && intruder.linked.isCancelled)
        assertEquals(setOf("m"), h.participants.value)
        assertTrue(net.clients[0].connected.isEmpty())
    }

    @Test fun openJoinIsAcceptedOnlyWhileTheHostAllowsIt() = runTest {
        val net = FakeNearbyNet()
        val closed = transport(net, "m", open = false); host(closed)
        val j1 = transport(net, "b", hash = NearbyInvite.OPEN_HASH)
        j1.joinEndpoint(net.clients[0].endpointId)
        assertTrue(j1.linked.isCancelled)

        val net2 = FakeNearbyNet()
        val open = transport(net2, "m", open = true); host(open)
        val j2 = transport(net2, "b", hash = NearbyInvite.OPEN_HASH)
        j2.joinEndpoint(net2.clients[0].endpointId)
        assertTrue(j2.linked.isCompleted && !j2.linked.isCancelled)
        assertEquals(setOf("m", "b"), open.participants.value)
    }

    @Test fun hostRelaysParticipantToParticipantAndNeverEchoesToTheSender() = runTest {
        val s = session("b", "c")
        val (host, hostLog, _) = s[0]; val (b, bLog, _) = s[1]; val (c, cLog, _) = s[2]
        b.send(env("from-b"), RemoteRecipient.All, true)
        assertEquals(listOf("from-b"), hostLog.map { it.envelope.payload })
        assertEquals(listOf("from-b"), cLog.map { it.envelope.payload })
        assertEquals("b", cLog.single().from)
        assertTrue("no echo to the sender", bLog.isEmpty())

        host.send(env("from-host"), RemoteRecipient.All, true)
        assertEquals(listOf("from-host"), bLog.map { it.envelope.payload })
        assertEquals("m", bLog.single().from)
        assertEquals(listOf("from-b", "from-host"), cLog.map { it.envelope.payload })
        assertEquals(1, hostLog.size)
        assertNotNull(c)
    }

    @Test fun aDirectedMessageReachesOnlyItsRecipient() = runTest {
        val s = session("b", "c")
        val (_, hostLog, _) = s[0]; val (b, bLog, _) = s[1]; val (_, cLog, _) = s[2]
        b.send(env("psst"), RemoteRecipient.Participant("c"), true)
        assertEquals(listOf("psst"), cLog.map { it.envelope.payload })
        assertTrue(hostLog.isEmpty())
        assertTrue(bLog.isEmpty())
        // to the host itself:
        b.send(env("hi-host"), RemoteRecipient.Participant("m"), true)
        assertEquals(listOf("hi-host"), hostLog.map { it.envelope.payload })
        assertEquals(1, cLog.size)
        // to itself and to a stranger: nothing moves
        b.send(env("self"), RemoteRecipient.Participant("b"), true)
        b.send(env("nobody"), RemoteRecipient.Participant("zzz"), true)
        assertEquals(1, hostLog.size); assertEquals(1, cLog.size); assertTrue(bLog.isEmpty())
    }

    @Test fun theHostStampsTheSenderItselfAndIgnoresAClaimedFrom() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val hLog = ArrayList<RemoteInbound>().also { collecting(h, it) }
        val b = transport(net, "b"); b.joinByHash()
        val forged = NearbyFrames.encode(NearbyFrame.Message(from = "m", to = null, envelope = env("forged")))
        net.clients[1].send(net.clients[0].endpointId, forged)
        assertEquals("b", hLog.single().from)
    }

    @Test fun aMessageBeforeTheIdHandshakeIsIgnored() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val hLog = ArrayList<RemoteInbound>().also { collecting(h, it) }
        val raw = net.client()
        raw.listener = object : NearbyListener {
            override fun onEndpointFound(endpointId: String, endpointName: String) = Unit
            override fun onEndpointLost(endpointId: String) = Unit
            override fun onConnectionInitiated(endpointId: String, endpointName: String, authDigits: String, incoming: Boolean) { raw.acceptConnection(endpointId) }
            override fun onConnectionResult(endpointId: String, success: Boolean) = Unit
            override fun onDisconnected(endpointId: String) = Unit
            override fun onPayload(endpointId: String, bytes: ByteArray) = Unit
        }
        raw.requestConnection(NearbyInvite.endpointName("Raw", hash, null), net.clients[0].endpointId)
        raw.send(net.clients[0].endpointId, NearbyFrames.encode(NearbyFrame.Message(null, null, env("early"))))
        assertTrue(hLog.isEmpty())
        assertEquals(setOf("m"), h.participants.value)
    }

    @Test fun garbageAndUnknownFramesAreDroppedNotFatal() {
        assertNull(NearbyFrames.decode("not json".toByteArray()))
        assertNull(NearbyFrames.decode("""{"t":"future","x":1}""".toByteArray()))
        assertNull(NearbyFrames.decode("""{"t":"hi"}""".toByteArray()))
        assertNull(NearbyFrames.decode("""{"t":"m","e":{"v":"x"}}""".toByteArray()))
        assertNull(NearbyFrames.decode(ByteArray(0)))
    }

    @Test fun framesRoundTripAndKeepTheEnvelopeIntact() {
        val e = RemoteEnvelope(1, "state", "e30=")
        val m = NearbyFrames.decode(NearbyFrames.encode(NearbyFrame.Message("a", "b", e))) as NearbyFrame.Message
        assertEquals(NearbyFrame.Message("a", "b", e), m)
        assertEquals(NearbyFrame.Message(null, null, e), NearbyFrames.decode(NearbyFrames.encode(NearbyFrame.Message(null, null, e))))
        assertEquals(NearbyFrame.Roster(listOf("a", "b")), NearbyFrames.decode(NearbyFrames.encode(NearbyFrame.Roster(listOf("a", "b")))))
        assertEquals(NearbyFrame.Hi("uuid"), NearbyFrames.decode(NearbyFrames.encode(NearbyFrame.Hi("uuid"))))
    }

    @Test fun aMaximumStateEnvelopeFitsOneNearbyPayload() {
        val body = ByteArray(NearbyFrames.MAX_STATE_BYTES * 3 / 4 - 64) { 'a'.code.toByte() }
        val e = RemoteEnvelope(1, "state", java.util.Base64.getEncoder().encodeToString(body))
        assertTrue(e.encode().toByteArray().size <= NearbyFrames.MAX_STATE_BYTES)
        val frame = NearbyFrames.encode(NearbyFrame.Message("a-uuid-36-chars-long-aaaaaaaaaaaaaaaa", "b-uuid-36-chars-long-bbbbbbbbbbbbbbbb", e))
        assertTrue("frame ${frame.size} must fit ${NearbyFrames.MAX_PAYLOAD_BYTES}", frame.size <= NearbyFrames.MAX_PAYLOAD_BYTES)
    }

    @Test fun anOversizedFrameIsDroppedNotSent() = runTest {
        val s = session("b")
        val (host, _, _) = s[0]; val (_, bLog, _) = s[1]
        host.send(RemoteEnvelope(1, "state", "x".repeat(40_000)), RemoteRecipient.All, true)
        assertTrue(bLog.isEmpty())
    }

    @Test fun aJoinerLeavingShrinksTheRosterEverywhere() = runTest {
        val s = session("b", "c")
        val (host, _, _) = s[0]; val (b, _, _) = s[1]; val (c, _, _) = s[2]
        assertEquals(setOf("m", "b", "c"), c.participants.value)
        b.leave()
        assertEquals(setOf("m", "c"), host.participants.value)
        assertEquals(setOf("m", "c"), c.participants.value)
        assertTrue(b.participants.value.isEmpty())
    }

    @Test fun leavingTheHostMigratesToTheLowestRemainingId() = runTest {
        val s = session("b", "c")
        val (host, _, _) = s[0]; val (b, bLog, _) = s[1]; val (c, cLog, _) = s[2]
        host.leave()
        // b (lowest) now relays; c reconnects to it by the session's token hash.
        assertEquals(setOf("b", "c"), b.participants.value)
        assertEquals(setOf("b", "c"), c.participants.value)
        c.send(env("after"), RemoteRecipient.All, true)
        assertEquals(listOf("after"), bLog.map { it.envelope.payload })
        assertEquals("c", bLog.single().from)
        b.send(env("back"), RemoteRecipient.All, true)
        assertEquals(listOf("back"), cLog.map { it.envelope.payload })
    }

    @Test fun aMigratedRelayRefusesOpenJoins() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val b = transport(net, "b"); b.joinByHash()
        h.leave()
        val stranger = transport(net, "x", hash = NearbyInvite.OPEN_HASH)
        stranger.joinEndpoint(net.clients[1].endpointId)
        assertTrue(stranger.linked.isCancelled)
        assertEquals(setOf("b"), b.participants.value)
    }

    @Test fun migrationGivesUpAfterTheTimeoutWhenNobodyRelays() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val b = transport(net, "b"); b.joinByHash()
        val c = transport(net, "c", scope = backgroundScope); c.joinByHash()
        net.clients[1].vanish() // b dies without a word, so nobody advertises after the host leaves
        h.leave()
        assertEquals(setOf("b", "c"), c.participants.value) // waiting for b
        advanceTimeBy(14_000)
        assertFalse(c.participants.value.isEmpty())
        advanceTimeBy(2_000)
        assertTrue(c.participants.value.isEmpty())
    }

    @Test fun duplicateParticipantIdReplacesTheStaleLinkAndTheHostIdIsRefused() = runTest {
        val net = FakeNearbyNet()
        val h = transport(net, "m"); host(h)
        val b1 = transport(net, "b"); b1.joinByHash()
        val b2 = transport(net, "b"); b2.joinByHash()
        assertEquals(setOf("m", "b"), h.participants.value)
        assertEquals("the displaced twin is cut loose and re-forms alone", setOf("b"), b1.participants.value)
        val twin = transport(net, "m"); twin.joinByHash()
        assertEquals(setOf("m", "b"), h.participants.value)
    }
}
