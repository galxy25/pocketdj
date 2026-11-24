package com.levi.pocketdj.remote

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.currentTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LoopbackHubTest {
    private fun env(tag: String) = RemoteEnvelope(1, RemoteMessageKind.COMMAND.wire, tag)

    private fun kotlinx.coroutines.test.TestScope.collect(t: LoopbackTransport): MutableList<RemoteInbound> {
        val out = mutableListOf<RemoteInbound>()
        backgroundScope.launch { t.inbound.collect { out += it } }
        return out
    }

    @Test fun broadcastReachesOthersNeverTheSender() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a"); val b = hub.join("b"); val c = hub.join("c")
        val ia = collect(a); val ib = collect(b); val ic = collect(c)
        a.send(env("hi"), RemoteRecipient.All, true)
        runCurrent()
        assertTrue(ia.isEmpty())
        assertEquals(listOf("a"), ib.map { it.from })
        assertEquals("hi", ic.single().envelope.payload)
        assertEquals(1, a.sent.size)
    }

    @Test fun directedSendAndSelfSendIgnored() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a"); val b = hub.join("b"); val c = hub.join("c")
        val ia = collect(a); val ib = collect(b); val ic = collect(c)
        a.send(env("only-b"), RemoteRecipient.Participant("b"), true)
        a.send(env("self"), RemoteRecipient.Participant("a"), true)
        a.send(env("ghost"), RemoteRecipient.Participant("zzz"), true)
        runCurrent()
        assertEquals(listOf("only-b"), ib.map { it.envelope.payload })
        assertTrue(ia.isEmpty() && ic.isEmpty())
    }

    @Test fun rosterUpdatesOnJoinAndLeave() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a")
        assertEquals(setOf("a"), a.participants.value)
        val b = hub.join("b")
        assertEquals(setOf("a", "b"), a.participants.value)
        assertEquals(setOf("a", "b"), b.participants.value)
        b.leave()
        assertEquals(setOf("a"), a.participants.value)
        assertTrue(b.participants.value.isEmpty())
        assertEquals(setOf("a"), hub.participantIds)
    }

    @Test fun leaveCompletesInboundAndEndEndsEveryone() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a"); val b = hub.join("b")
        var completedA = false
        backgroundScope.launch { a.inbound.toList(); completedA = true }
        runCurrent()
        hub.end()
        runCurrent()
        assertTrue(completedA)
        assertTrue(b.participants.value.isEmpty())
    }

    @Test fun latencyDelaysPerPairDeterministically() = runTest {
        val hub = LoopbackHub(this)
        hub.latency = { from, to -> if (from == "a" && to == "b") 0.3 else if (to == "c") 0.1 else 0.0 }
        val a = hub.join("a"); val b = hub.join("b"); val c = hub.join("c")
        val ib = collect(b); val ic = collect(c)
        a.send(env("m"), RemoteRecipient.All, true)
        runCurrent()
        assertTrue(ib.isEmpty() && ic.isEmpty())
        advanceTimeBy(100); runCurrent()
        assertEquals(1, ic.size); assertTrue(ib.isEmpty())
        advanceTimeBy(199); runCurrent()
        assertTrue(ib.isEmpty())
        advanceTimeBy(1); runCurrent()
        assertEquals(1, ib.size)
        assertEquals(300L, currentTime)
    }

    @Test fun uniformLatencyKeepsSendOrder() = runTest {
        val hub = LoopbackHub(this)
        hub.latency = { _, _ -> 0.05 }
        val a = hub.join("a"); val b = hub.join("b")
        val ib = collect(b)
        for (i in 0 until 5) a.send(env("$i"), RemoteRecipient.All, true)
        advanceTimeBy(60); runCurrent()
        assertEquals((0 until 5).map { "$it" }, ib.map { it.envelope.payload })
    }

    @Test fun dropInjectionIsAFunctionOfItsInputs() = runTest {
        val hub = LoopbackHub(this)
        hub.drop = { e, _, to -> e.payload.startsWith("lose") || (to is RemoteRecipient.Participant && to.id == "c") }
        val a = hub.join("a"); val b = hub.join("b"); val c = hub.join("c")
        val ib = collect(b); val ic = collect(c)
        a.send(env("lose-1"), RemoteRecipient.All, true)
        a.send(env("keep"), RemoteRecipient.All, true)
        a.send(env("to-c"), RemoteRecipient.Participant("c"), true)
        runCurrent()
        assertEquals(listOf("keep"), ib.map { it.envelope.payload })
        assertEquals(listOf("keep"), ic.map { it.envelope.payload })
        assertEquals(3, a.sent.size)     // sends are recorded even when lost
    }

    @Test fun injectDeliversRawEnvelopeAndStateCapIsConfigurable() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a", maxStateBytes = 1234)
        val ia = collect(a)
        a.inject(RemoteEnvelope(9, "future", "!!"), from = "x")
        runCurrent()
        assertEquals("x", ia.single().from)
        assertEquals(null, ia.single().envelope.knownKind)
        assertEquals(1234, a.maxStateBytes)
    }

    @Test fun sendQueueOverLoopbackEndToEnd() = runTest {
        val hub = LoopbackHub(this)
        val a = hub.join("a"); val b = hub.join("b")
        val ib = collect(b)
        val q = RemoteSendQueue<RemoteRecipient>(this, { it }) { e, r, rel -> a.send(e, r, rel) }
        q.enqueue(env("1"), RemoteRecipient.Participant("b"), true)
        q.enqueue(env("2"), RemoteRecipient.All, true)
        runCurrent()
        assertEquals(listOf("1", "2"), ib.map { it.envelope.payload })
    }
}
