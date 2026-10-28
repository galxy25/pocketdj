package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixJukeboxSourceTest {
    private class FakeMix : MixJukeboxPort {
        override var autoMixing = true
        override var isRunning = true
        override var onAir: MixJukeboxPort.OnAir? = MixJukeboxPort.OnAir("on", "On Air", "Band", 12_000, 200_000, false)
        override var upcoming: List<MixLoadable> = listOf(MixLoadable("u1", "Up One", "A1"), MixLoadable("u2", "Up Two", "A2"))
        override var played: List<MixLoadable> = listOf(MixLoadable("p1", "Prev", "P"))
        val inserts = ArrayList<Pair<AutoMixItem, JukeboxDecisionAction>>()
        override fun insert(item: AutoMixItem, action: JukeboxDecisionAction) { inserts += item to action }
    }

    private fun song(id: String, length: Long? = 210_000) =
        IndexSong(id = id, name = "N-$id", artist = "Ar-$id", length = length, bpm = 120.0, camelot = "8A")

    private class Rig(val mix: FakeMix? = FakeMix()) {
        var clock = 0L
        val loadable = HashSet<String>()
        val burns = ArrayList<String>()
        val source = MixJukeboxSource(
            port = { mix }, isLoadable = { it in loadable },
            requestBurn = { burns += it.id }, nowMs = { clock },
        )
    }

    @Test fun snapshotCarriesOnAirDeckTrackAndAutoQueueTail() {
        val r = Rig()
        val s = r.source.snapshot()!!
        assertEquals("On Air", s.title)
        assertEquals("Band", s.artist)
        assertEquals(200_000L, s.durationMs)
        assertEquals(12_000L, s.positionMs)
        assertEquals(listOf("Up One", "Up Two"), s.upNext.map { it.title })
        assertEquals(listOf("A1", "A2"), s.upNext.map { it.artist })
        assertTrue(r.source.isLive)
    }

    @Test fun noSnapshotWithoutAMixOrWhenNotAutoMixing() {
        assertNull(Rig(mix = null).source.snapshot())
        val r = Rig().also { it.mix!!.autoMixing = false; it.mix.isRunning = false }
        assertNull(r.source.snapshot())
        assertFalse(r.source.isLive)
        val silent = Rig().also { it.mix!!.onAir = null }
        assertNull(silent.source.snapshot())
    }

    @Test fun bufferingFlagPassesThrough() {
        val r = Rig().also { it.mix!!.onAir = it.mix.onAir!!.copy(buffering = true) }
        assertTrue(r.source.snapshot()!!.buffering)
    }

    @Test fun handDrivenMixBroadcastsButIsNotAnAutoQueueOwner() = runTest {
        val r = Rig().also { it.mix!!.autoMixing = false; it.mix.isRunning = true }
        assertEquals("On Air", r.source.snapshot()!!.title)
        assertTrue(r.source.isLive)
        assertFalse(r.source.place(song("x"), JukeboxDecisionAction.NEXT))
        r.mix!!.isRunning = false
        assertNull(r.source.snapshot())
    }

    @Test fun throwingBurnKickDoesNotUnparkTheRequest() = runTest {
        val mix = FakeMix()
        val src = MixJukeboxSource(port = { mix }, isLoadable = { false }, requestBurn = { error("io") })
        assertTrue(src.place(song("x"), JukeboxDecisionAction.NEXT))
        assertEquals(1, src.pendingCount)
    }

    @Test fun placementInsertsLoadableSongForEachPlacementKind() = runTest {
        val r = Rig(); r.loadable += "x"
        for (a in listOf(JukeboxDecisionAction.NEXT, JukeboxDecisionAction.END, JukeboxDecisionAction.RANDOM)) {
            assertTrue(r.source.place(song("x"), a))
        }
        assertEquals(listOf(JukeboxDecisionAction.NEXT, JukeboxDecisionAction.END, JukeboxDecisionAction.RANDOM), r.mix!!.inserts.map { it.second })
        val item = r.mix.inserts.first().first
        assertEquals("x", item.loadable.songId)
        assertEquals("N-x", item.loadable.title)
        assertEquals(120.0, item.loadable.bpm!!, 0.0)
        assertEquals(210_000, item.durationMs)
        assertTrue(r.burns.isEmpty())
    }

    @Test fun unknownLengthUsesTheFallbackDuration() = runTest {
        val r = Rig(); r.loadable += "x"
        r.source.place(song("x", length = null), JukeboxDecisionAction.END)
        assertEquals(MixJukeboxSource.FALLBACK_LENGTH_MS, r.mix!!.inserts.single().first.durationMs)
    }

    @Test fun withoutAMixOrWhenDeniedPlacementIsNotHandled() = runTest {
        assertFalse(Rig(mix = null).source.place(song("x"), JukeboxDecisionAction.NEXT))
        val r = Rig().also { it.mix!!.autoMixing = false }
        assertFalse(r.source.place(song("x"), JukeboxDecisionAction.NEXT))
        val live = Rig().also { it.loadable += "x" }
        assertFalse(live.source.place(song("x"), JukeboxDecisionAction.DENIED))
        assertTrue(live.mix!!.inserts.isEmpty())
    }

    @Test fun unloadableMatchBurnsAndParksThenLandsWhenTheFileArrives() = runTest {
        val r = Rig()
        assertTrue(r.source.place(song("x"), JukeboxDecisionAction.NEXT))
        assertEquals(listOf("x"), r.burns)
        assertEquals(1, r.source.pendingCount)
        assertTrue(r.mix!!.inserts.isEmpty())
        r.source.drainPending()                  // still not on disk
        assertEquals(1, r.source.pendingCount)
        r.loadable += "x"
        r.source.drainPending()
        assertEquals(0, r.source.pendingCount)
        assertEquals(JukeboxDecisionAction.NEXT, r.mix.inserts.single().second)
    }

    @Test fun parkedInsertExpiresAfterFifteenMinutes() = runTest {
        val r = Rig()
        r.source.place(song("x"), JukeboxDecisionAction.END)
        r.clock = MixJukeboxSource.PENDING_TTL_MS + 1
        r.loadable += "x"
        r.source.drainPending()
        assertEquals(0, r.source.pendingCount)
        assertTrue(r.mix!!.inserts.isEmpty())
    }

    @Test fun parkedInsertIsHandedBackWhenTheMixEnded() = runTest {
        val r = Rig()
        r.source.place(song("x"), JukeboxDecisionAction.END)
        r.mix!!.autoMixing = false
        r.loadable += "x"
        val landed = r.source.drainPending()
        assertTrue(r.mix.inserts.isEmpty())
        assertEquals(0, r.source.pendingCount)
        assertEquals(listOf("x" to JukeboxDecisionAction.END), landed.map { it.song.id to it.action })
    }
}
