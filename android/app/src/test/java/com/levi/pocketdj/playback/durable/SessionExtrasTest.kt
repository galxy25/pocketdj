package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.playback.sequencer.SessionExtra
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import com.levi.pocketdj.playback.sequencer.rows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class SessionExtrasTest {
    @get:Rule val tmp = TemporaryFolder()

    private class MixFeature(var enabled: Boolean = false) : SessionExtra<SessionNpMixMode> {
        override val key = SessionExtraKey.NP_MIX_MODE
        var restored: SessionNpMixMode? = null
        var armed = false // must stay false: restore is HELD
        override fun write() = SessionNpMixMode(enabled)
        override fun restoreHeld(value: SessionNpMixMode) { restored = value; enabled = value.enabled }
    }

    private class DjFeature : SessionExtra<SessionDjMode> {
        override val key = SessionExtraKey.DJ_MODE
        var on = true
        override fun write() = SessionDjMode(on)
        override fun restoreHeld(value: SessionDjMode) = error("never")
    }

    private fun DurableHarness.extrasWriter() = SessionWriter(
        store = store, position = { pos }, isPlaying = { playing }, heldOffset = { seq.resumeOffsetMs },
        positionValid = { seq.currentRowLoaded }, consumedResumeOffset = { seq.lastResumeOffsetMs },
        sessionExtras = seq.sessionExtras,
    )

    private fun DurableHarness.observeWith(w: SessionWriter) {
        scope.backgroundScope.launch(kotlinx.coroutines.test.UnconfinedTestDispatcher(scope.testScheduler)) {
            seq.state.collect { w.onState(it) }
        }
    }

    @Test
    fun registeredFeature_isWrittenWithEverySnapshot_viaTheDataDtos() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        val feature = MixFeature(enabled = true)
        d.seq.sessionExtras.register(feature)
        d.observeWith(d.extrasWriter())
        d.seq.play(rows("a", "b")); d.h.settle()
        val disk = d.snapshotOnDisk()!!
        assertEquals(SessionNpMixMode(true), disk.npMixMode)
        assertNull("no feature registered for fxLock: nothing invented", disk.fxLock)
        assertNull(disk.djMode)
    }

    @Test
    fun toggling_persistsImmediately_andNeverWhileHeldOrIdle() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        val feature = MixFeature(enabled = false)
        d.seq.sessionExtras.register(feature)
        d.observeWith(d.extrasWriter())
        d.seq.sessionExtras.notifyChanged() // idle: nothing to write into
        assertFalse(d.file.exists())
        d.seq.play(rows("a", "b")); d.h.settle()
        assertEquals(SessionNpMixMode(false), d.snapshotOnDisk()!!.npMixMode)
        feature.enabled = true
        d.seq.sessionExtras.notifyChanged()
        assertEquals(SessionNpMixMode(true), d.snapshotOnDisk()!!.npMixMode)
    }

    @Test
    fun iosShapedFields_nobodyRegistered_roundTripUntouched() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        val ios = SessionSnapshot(
            sessionId = "pses_X", source = SessionSourceRef(kind = "setlist", id = "s"), queue = listOf(
                SessionRow(songId = "a", title = "a"), SessionRow(songId = "b", title = "b"),
            ), index = 0,
            fxLock = SessionFxLock(true, mapOf("echo" to SessionFxSetting(true, 0.5))),
            unknownKeys = JsonObject(mapOf("futureKey" to JsonPrimitive(7))),
        )
        d.file.writeText(SessionSnapshot.encode(ios))
        assertNotNull(d.store.load())
        d.observeWith(d.extrasWriter()) // no features registered
        // The iOS session is restored (same sessionId) and resumed: the Android write must carry what iOS wrote.
        SessionRestorer(d.store, d.seq).restore(ios)
        d.seq.resumeFromHold(); d.h.settle()
        val txt = d.file.readText()
        assertTrue("iOS key kept after an Android write", txt.contains("\"futureKey\""))
        assertTrue(txt.contains("\"fxLock\""))
    }

    @Test
    fun heldRestore_deliversStoredValue_andArmsNothingUntilFirstPlay() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        val feature = MixFeature()
        d.seq.sessionExtras.register(feature)
        val stored = SnapshotExtras(npMixMode = SessionNpMixMode(true), djMode = SessionDjMode(true))
        d.seq.restoreHeld(rows("a", "b"), 0, null, null, null, com.levi.pocketdj.playback.sequencer.RepeatMode.OFF, false, null, extras = stored)
        assertEquals(SessionNpMixMode(true), feature.restored)
        assertTrue(d.seq.isHeldForResume)
        assertTrue("nothing loaded: no audio before the first play", d.h.port.loads.isEmpty())
        assertFalse(feature.armed)
    }

    @Test
    fun lateRegistrant_getsTheHeldValue_andACrashingRestoreIsIsolated() = runTest {
        val d = DurableHarness(this, tmp.root, "a")
        val stored = SnapshotExtras(npMixMode = SessionNpMixMode(true), djMode = SessionDjMode(true))
        d.seq.restoreHeld(rows("a"), 0, null, null, null, com.levi.pocketdj.playback.sequencer.RepeatMode.OFF, false, null, extras = stored)
        d.seq.sessionExtras.register(DjFeature()) // its restoreHeld throws: must not escape
        val late = MixFeature()
        d.seq.sessionExtras.register(late)
        assertEquals(SessionNpMixMode(true), late.restored)
        d.seq.resumeFromHold(); d.h.settle()
        val later = MixFeature()
        d.seq.sessionExtras.register(later)
        assertNull("after the first play nothing is pending delivery", later.restored)
    }

    @Test
    fun throwingWrite_keepsTheStoredValue() {
        val reg = com.levi.pocketdj.playback.sequencer.SessionExtras()
        reg.register(object : SessionExtra<SessionNpMixMode> {
            override val key = SessionExtraKey.NP_MIX_MODE
            override fun write(): SessionNpMixMode = error("nope")
            override fun restoreHeld(value: SessionNpMixMode) = Unit
        })
        val base = SnapshotExtras(npMixMode = SessionNpMixMode(true))
        assertEquals(SessionNpMixMode(true), reg.collect(base).npMixMode)
        assertEquals(setOf("npMixMode"), reg.registeredKeys)
    }

    private fun assertNotNull(v: Any?) = org.junit.Assert.assertNotNull(v)
}
