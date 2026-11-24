package com.levi.pocketdj.playback.sequencer

import kotlin.random.Random
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ReplaceUpcomingPropertyTest {
    private val allIds = (0 until 40).map { "s$it" }.toTypedArray()

    private fun TestScope.harness() = SequencerHarness(this, backgroundScope, allIds.toSet())

    private fun planned(id: String, slot: Int, pinned: Boolean = false, length: Long = 200_000) =
        QueueItem(id = id, title = id, lengthMs = length, plan = PlanTag("run1", slot, "col", 0.5, pinned))

    private fun SequencerHarness.uids() = seq.state.value.queue.map { it.uid }

    @Test
    fun randomQueuesAndEdits_protectedRowsNeverReplaced_uidsUnique() = runTest {
        val h = harness()
        val rnd = Random(20261123)
        var replacedTotal = 0
        repeat(2000) { iter ->
            val n = rnd.nextInt(3, 13)
            val index = rnd.nextInt(0, n)
            val shortRunway = rnd.nextBoolean()
            val items = (0 until n).map { i ->
                val id = "s${i}"
                val len = if (i == index && shortRunway) 10_000L else 200_000L
                when (rnd.nextInt(3)) {
                    0 -> QueueItem(id = id, title = id, lengthMs = len) // the listener's own row
                    1 -> planned(id, i, pinned = false, length = len)
                    else -> planned(id, i, pinned = true, length = len)
                }
            }
            h.seq.play(items, "pwr_run1", startIndex = index)
            h.settle()
            val before = h.seq.state.value.queue
            val gen0 = h.seq.queueGeneration

            val replacements = HashMap<String, QueueItem>()
            val removing = HashSet<String>()
            before.forEachIndexed { i, row ->
                when (rnd.nextInt(5)) {
                    0, 1 -> replacements[row.uid] = planned("s${20 + i}", i, length = 90_000)
                    2 -> removing += row.uid
                    else -> Unit
                }
            }
            replacements["stale-uid-1"] = planned("s39", 99) // never in the queue
            removing += "stale-uid-2"
            // sometimes a replacement reuses a uid already live in the queue (must be made unique)
            if (rnd.nextInt(4) == 0 && before.size > 2) {
                val victim = before[rnd.nextInt(before.size)]
                val key = before.firstOrNull { it.uid in replacements && it.uid != victim.uid }?.uid
                if (key != null) replacements[key] = replacements[key]!!.copy(uid = victim.uid)
            }

            val changed = h.seq.replaceUpcoming(replacements, removing)
            val after = h.seq.state.value.queue

            // played rows + the current row are never touched
            for (i in 0..index) assertEquals("iter $iter: row $i touched", before[i], after[i])
            // uids stay unique
            assertEquals("iter $iter: duplicate uids", after.size, after.map { it.uid }.toSet().size)

            // protection, evaluated against the BEFORE queue
            fun protectedRow(i: Int): Boolean {
                val r = before[i]
                if (i <= index) return true
                if (r.plan == null || r.plan!!.pinned) return true
                return i == index + 1 && shortRunway
            }
            var expectChanged = 0
            val survivors = ArrayList<QueueItem>()
            before.forEachIndexed { i, row ->
                val prot = protectedRow(i)
                when {
                    !prot && row.uid in replacements -> { expectChanged++; survivors += replacements[row.uid]!! }
                    !prot && row.uid in removing -> expectChanged++
                    else -> {
                        survivors += row
                        if (prot) assertTrue("iter $iter: protected row $i vanished", after.any { it.uid == row.uid })
                    }
                }
            }
            assertEquals("iter $iter: changed count", expectChanged, changed)
            // size and song order match the expectation (a replacement sits in the replaced row's slot)
            assertEquals("iter $iter: ids", survivors.map { it.id }, after.map { it.id })
            if (changed == 0) assertEquals("iter $iter: no-op must not bump the generation", gen0, h.seq.queueGeneration)
            else assertTrue(h.seq.queueGeneration > gen0)
            replacedTotal += changed
        }
        assertTrue("the generator must exercise real replacements", replacedTotal > 500)
    }

    @Test
    fun staleUids_areNoOps() = runTest {
        val h = harness()
        h.seq.play(listOf(planned("s0", 0), planned("s1", 1), planned("s2", 2)), "pwr_run1")
        h.settle()
        val gen = h.seq.queueGeneration
        assertEquals(0, h.seq.replaceUpcoming(mapOf("nope" to planned("s9", 9)), setOf("also-nope")))
        assertEquals(0, h.seq.replaceUpcoming(emptyMap(), emptySet()))
        assertEquals(gen, h.seq.queueGeneration)
        assertEquals(listOf("s0", "s1", "s2"), h.ids)
    }

    @Test
    fun nextRow_needsThirtySecondsOfRunway() = runTest {
        val h = harness()
        h.seq.play(listOf(planned("s0", 0, length = 31_000), planned("s1", 1), planned("s2", 2)), "pwr_run1")
        h.settle()
        val next = h.seq.state.value.queue[1].uid
        assertEquals("31 s left: replaceable", 1, h.seq.replaceUpcoming(mapOf(next to planned("s9", 9)), emptySet()))

        h.seq.play(listOf(planned("s0", 0, length = 29_000), planned("s1", 1), planned("s2", 2)), "pwr_run1")
        h.settle()
        val next2 = h.seq.state.value.queue[1].uid
        val third = h.seq.state.value.queue[2].uid
        assertEquals("29 s left: index+1 is protected", 0, h.seq.replaceUpcoming(mapOf(next2 to planned("s9", 9)), setOf(next2)))
        assertEquals("index+2 is not", 1, h.seq.replaceUpcoming(emptyMap(), setOf(third)))
        assertEquals(listOf("s0", "s1"), h.ids)
    }

    @Test
    fun pendingRip_onlyAnInstantOrOnDeviceReplacementMayTakeTheSlot() = runTest {
        val h = harness()
        h.seq.rowStartsInstantly = { it.id == "s7" }
        h.seq.rowOnDevice = { it.id == "s8" }
        h.seq.play(listOf(planned("s0", 0), planned("s1", 1), planned("s2", 2)), "pwr_run1")
        h.settle()
        h.seq.notePlaybackRipQueued("s1") // a capture is in flight for the next row
        val uid = h.seq.state.value.queue[1].uid
        assertEquals(0, h.seq.replaceUpcoming(mapOf(uid to planned("s5", 1)), emptySet()))
        assertEquals("an in-flight capture is not traded for another slow row", "s1", h.ids[1])
        assertEquals(1, h.seq.replaceUpcoming(mapOf(uid to planned("s7", 1)), emptySet()))
        assertEquals("s7", h.ids[1])

        h.seq.notePlaybackRipQueued("s2")
        val uid2 = h.seq.state.value.queue[2].uid
        assertEquals(1, h.seq.replaceUpcoming(mapOf(uid2 to planned("s8", 2)), emptySet()))
        assertEquals("s8", h.ids[2])
    }

    @Test
    fun replacementTakesTheCanonicalOrderSlot_soUnshuffleStaysCoherent() = runTest {
        val h = harness()
        h.seq.play((0..5).map { planned("s$it", it) }, "pwr_run1")
        h.settle()
        h.seq.setShuffle(true)
        val victim = h.seq.state.value.queue.first { it.id == "s3" }
        assertEquals(1, h.seq.replaceUpcoming(mapOf(victim.uid to planned("s30", 3)), emptySet()))
        assertTrue(h.ids.contains("s30"))
        assertFalse(h.ids.contains("s3"))
        h.seq.setShuffle(false)
        assertEquals("the replacement sits where s3 was before the shuffle", listOf("s0", "s1", "s2", "s30", "s4", "s5"), h.ids)
        assertEquals(h.uids().size, h.uids().toSet().size)
    }

    @Test
    fun replacingTheNextRow_reArmsThePreloadWindow() = runTest {
        val h = harness()
        h.seq.preloadEnabled = true
        h.seq.play((0..4).map { planned("s$it", it) }, "pwr_run1")
        h.settle()
        h.seq.onFirstAudio("s0")
        h.settle()
        assertEquals("s1", h.port.preloadedId)
        val next = h.seq.state.value.queue[1].uid
        assertEquals(1, h.seq.replaceUpcoming(mapOf(next to planned("s20", 1)), emptySet()))
        h.settle()
        assertEquals("slot 1 now holds the replacement", "s20", h.port.preloadedId)
        // a row outside index+1..+3 does not touch the window
        assertTrue(NextRowPreloader.inWindow(0, 3))
        assertFalse(NextRowPreloader.inWindow(0, 4))
        assertFalse(NextRowPreloader.inWindow(2, 2))
    }

    @Test
    fun replacementsAreEditionStampedLikePlay() = runTest {
        val h = harness()
        h.seq.editionDecider = object : EditionDecider {
            override fun isActive() = true
            override fun decide(item: QueueItem, cleanOnly: Boolean) = item.copy(variant = "clean", resolveId = "${item.id}_clean")
        }
        h.seq.play(listOf(planned("s0", 0), planned("s1", 1)), "pwr_run1", preStamped = true)
        h.settle()
        val next = h.seq.state.value.queue[1].uid
        h.seq.replaceUpcoming(mapOf(next to planned("s9", 1)), emptySet())
        assertEquals("s9_clean", h.seq.state.value.queue[1].resolveId)
    }

    @Test
    fun appendRunRows_isEditionStampedTaggedAndNotPinned() = runTest {
        val h = harness()
        h.seq.editionDecider = object : EditionDecider {
            override fun isActive() = true
            override fun decide(item: QueueItem, cleanOnly: Boolean) = item.copy(variant = "clean", resolveId = "${item.id}_clean")
        }
        h.seq.play(listOf(planned("s0", 0)), "pwr_run1", preStamped = true)
        h.settle()
        val rec = Recorder().also { h.seq.hooks.add(it) }
        h.seq.appendRunRows(listOf(planned("s5", 5), planned("s6", 6)), "pwr_run1")
        val q = h.seq.state.value.queue
        assertEquals(listOf("s0", "s5", "s6"), q.map { it.id })
        assertEquals(listOf("s5_clean", "s6_clean"), q.drop(1).map { it.resolveId })
        assertTrue(q.drop(1).all { it.runTag == "pwr_run1" && !it.pinned })
        assertFalse("a run's own top-up is not the listener's edit", rec.events.contains("user(EDIT)"))
        // idle: no-op
        h.seq.stop()
        h.seq.appendRunRows(listOf(planned("s7", 7)), "pwr_run1")
        assertTrue(h.seq.state.value.queue.isEmpty())
    }
}
