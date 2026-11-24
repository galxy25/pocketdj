package com.levi.pocketdj.remote

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RemoteSendQueueTest {
    private fun env(kind: RemoteMessageKind, tag: String) = RemoteEnvelope(1, kind.wire, tag)
    private val all = RemoteRecipient.All
    private fun peer(id: String) = RemoteRecipient.Participant(id)

    @Test fun deliversInSendOrder() = runTest {
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> got += e.payload }
        q.enqueue(env(RemoteMessageKind.COMMAND, "1"), all, true)
        q.enqueue(env(RemoteMessageKind.COMMAND, "2"), all, true)
        q.enqueue(env(RemoteMessageKind.COMMAND, "3"), all, true)
        runCurrent()
        assertEquals(listOf("1", "2", "3"), got)
        assertEquals(3, q.deliveredCount)
    }

    @Test fun retryKeepsOrderAndUsesBackoff() = runTest {
        val got = mutableListOf<Pair<String, Long>>()
        var fails = 2
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ ->
            if (e.payload == "A" && fails > 0) { fails--; throw RuntimeException("boom") }
            got += e.payload to currentTime
        }
        q.enqueue(env(RemoteMessageKind.COMMAND, "A"), all, true)
        q.enqueue(env(RemoteMessageKind.COMMAND, "B"), all, true)
        runCurrent()
        assertTrue(got.isEmpty())              // A is retrying; B waits behind it (strict order)
        advanceTimeBy(250); runCurrent()
        assertTrue(got.isEmpty())              // second attempt failed too
        advanceTimeBy(1000); runCurrent()
        assertEquals(listOf("A", "B"), got.map { it.first })
        assertEquals(1250L, got[0].second)
        assertEquals(2, q.failureCount)
    }

    @Test fun reliableGivesUpAfterRetriesThenContinues() = runTest {
        val got = mutableListOf<String>()
        var attempts = 0
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ ->
            if (e.payload == "A") { attempts++; throw RuntimeException("no") }
            got += e.payload
        }
        q.enqueue(env(RemoteMessageKind.COMMAND, "A"), all, true)
        q.enqueue(env(RemoteMessageKind.COMMAND, "B"), all, true)
        advanceTimeBy(5000); runCurrent()
        assertEquals(3, attempts)               // 1 + two retries
        assertEquals(listOf("B"), got)
    }

    @Test fun unreliableNeverRetriedNorBlockedByReliableRetry() = runTest {
        val got = mutableListOf<String>()
        var unreliableAttempts = 0
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, rel ->
            when {
                e.payload == "R" && rel -> throw RuntimeException("stuck")
                e.payload == "U-fail" -> { unreliableAttempts++; throw RuntimeException("x") }
                else -> got += e.payload
            }
        }
        q.enqueue(env(RemoteMessageKind.COMMAND, "R"), all, true)
        q.enqueue(env(RemoteMessageKind.PING, "U-fail"), all, false)
        q.enqueue(env(RemoteMessageKind.PING, "U-ok"), all, false)
        runCurrent()
        assertEquals(listOf("U-ok"), got)       // reliable lane is mid-retry, unreliable flowed
        assertEquals(1, unreliableAttempts)
        advanceTimeBy(5000); runCurrent()
        assertEquals(1, unreliableAttempts)
    }

    @Test fun stateCoalescedPerRecipientLatestWins() = runTest {
        val gate = CompletableDeferred<Unit>()
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> if (e.payload == "block") gate.await(); got += e.payload }
        q.enqueue(env(RemoteMessageKind.COMMAND, "block"), all, true)
        runCurrent()                            // worker is suspended inside send
        q.enqueue(env(RemoteMessageKind.STATE, "s1"), peer("a"), true)
        q.enqueue(env(RemoteMessageKind.STATE, "s2"), peer("b"), true)
        q.enqueue(env(RemoteMessageKind.STATE, "s3"), peer("a"), true)   // supersedes s1 only
        q.enqueue(env(RemoteMessageKind.COMMAND, "c"), peer("a"), true)
        assertEquals(3, q.pendingReliable)
        assertEquals(1, q.droppedCount)
        gate.complete(Unit); runCurrent()
        assertEquals(listOf("block", "s2", "s3", "c"), got)
    }

    @Test fun heartbeatsCoalesceOnUnreliableLane() = runTest {
        val gate = CompletableDeferred<Unit>()
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> if (e.payload == "block") gate.await(); got += e.payload }
        q.enqueue(env(RemoteMessageKind.PING, "block"), all, false)
        runCurrent()
        repeat(5) { q.enqueue(env(RemoteMessageKind.HEARTBEAT, "h$it"), all, false) }
        assertEquals(1, q.pendingUnreliable)
        gate.complete(Unit); runCurrent()
        assertEquals(listOf("block", "h4"), got)
    }

    @Test fun reliableCapShedsCoalescibleFirstElseOldest() = runTest {
        val gate = CompletableDeferred<Unit>()
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> if (e.payload == "block") gate.await(); got += e.payload }
        q.enqueue(env(RemoteMessageKind.COMMAND, "block"), all, true)
        runCurrent()
        q.enqueue(env(RemoteMessageKind.STATE, "S"), peer("a"), true)
        for (i in 0 until RemoteSendQueue.RELIABLE_CAP) q.enqueue(env(RemoteMessageKind.COMMAND, "c$i"), all, true)
        assertEquals(RemoteSendQueue.RELIABLE_CAP, q.pendingReliable)   // S shed, not c0
        assertEquals(1, q.droppedCount)
        q.enqueue(env(RemoteMessageKind.COMMAND, "extra"), all, true)    // no coalescible left: oldest (c0) goes
        assertEquals(RemoteSendQueue.RELIABLE_CAP, q.pendingReliable)
        gate.complete(Unit); runCurrent()
        assertEquals("c1", got[1])
        assertEquals("extra", got.last())
        assertTrue("S" !in got && "c0" !in got)
    }

    @Test fun unreliableCapDropsOldest() = runTest {
        val gate = CompletableDeferred<Unit>()
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> if (e.payload == "block") gate.await(); got += e.payload }
        q.enqueue(env(RemoteMessageKind.PING, "block"), all, false)
        runCurrent()
        for (i in 0 until RemoteSendQueue.UNRELIABLE_CAP + 3) q.enqueue(env(RemoteMessageKind.PING, "p$i"), all, false)
        assertEquals(RemoteSendQueue.UNRELIABLE_CAP, q.pendingUnreliable)
        gate.complete(Unit); runCurrent()
        assertEquals("p3", got[1])
    }

    @Test fun unresolvedPeerIsBufferedThenFlushedInOrderOnRosterChange() = runTest {
        val known = mutableSetOf<String>()
        val got = mutableListOf<Pair<String, String>>()
        val q = RemoteSendQueue<String>(this, { r -> (r as? RemoteRecipient.Participant)?.id?.takeIf { it in known } }) { e, r, _ -> got += r to e.payload }
        q.enqueue(env(RemoteMessageKind.COMMAND, "1"), peer("j"), true)
        q.enqueue(env(RemoteMessageKind.COMMAND, "2"), peer("j"), true)
        runCurrent()
        assertTrue(got.isEmpty())
        assertEquals(2, q.buffered["j"]?.size)
        known += "j"
        q.participantsChanged(); runCurrent()
        assertEquals(listOf("j" to "1", "j" to "2"), got)
        assertTrue(q.buffered.isEmpty())
    }

    @Test fun departedPeerBufferDropped() = runTest {
        val q = RemoteSendQueue<String>(this, { null }) { _, _, _ -> }
        q.enqueue(env(RemoteMessageKind.COMMAND, "1"), peer("j"), true)
        runCurrent()
        q.participantsChanged(departed = setOf("j"))
        assertTrue(q.buffered.isEmpty())
    }

    @Test fun bufferCapsPerPeerAndPeerCount() = runTest {
        val q = RemoteSendQueue<String>(this, { null }) { _, _, _ -> }
        repeat(RemoteSendQueue.BUFFER_CAP + 5) { q.enqueue(env(RemoteMessageKind.COMMAND, "m$it"), peer("p0"), true) }
        runCurrent()
        assertEquals(RemoteSendQueue.BUFFER_CAP, q.buffered["p0"]?.size)
        assertEquals("m5", q.buffered["p0"]!!.first().envelope.payload)   // oldest dropped
        for (i in 1..RemoteSendQueue.BUFFERED_PEERS_CAP) q.enqueue(env(RemoteMessageKind.COMMAND, "x"), peer("p$i"), true)
        runCurrent()
        assertEquals(RemoteSendQueue.BUFFERED_PEERS_CAP, q.buffered.size)
        assertTrue("p0" !in q.buffered)                                    // oldest peer evicted
    }

    @Test fun unreliableToUnresolvedPeerIsDroppedNotBuffered() = runTest {
        val q = RemoteSendQueue<String>(this, { null }) { _, _, _ -> }
        q.enqueue(env(RemoteMessageKind.PING, "p"), peer("j"), false)
        runCurrent()
        assertTrue(q.buffered.isEmpty())
    }

    @Test fun finishStopsEverything() = runTest {
        val got = mutableListOf<String>()
        val q = RemoteSendQueue<String>(this, { "x" }) { e, _, _ -> got += e.payload }
        q.finish()
        q.enqueue(env(RemoteMessageKind.COMMAND, "late"), all, true)
        runCurrent()
        assertTrue(got.isEmpty())
    }
}
