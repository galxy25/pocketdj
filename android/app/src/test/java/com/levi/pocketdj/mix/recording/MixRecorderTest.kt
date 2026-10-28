package com.levi.pocketdj.mix.recording

import com.levi.pocketdj.mix.store.MixRecording
import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

private class FakeWriter(val file: File) : TakeWriter {
    override var appendedSeconds = 0.0
    override var onWriterFailure: (() -> Unit)? = null
    override var failed = false
    var started = false; var stopped = false
    override fun start() { started = true; file.writeBytes(ByteArray(4)) }
    override fun stop() { stopped = true }
    fun die() { failed = true; onWriterFailure?.invoke() }
}

private class FakeSessions : RecordingSessions {
    override var currentId = "s1"
    val data = HashMap<String, MutableList<MixRecording>>()
    override fun recordings(sessionId: String) = data[sessionId].orEmpty()
    override fun addRecording(sessionId: String, fileName: String, startedAt: Double, durationMs: Int): String? {
        val l = data[sessionId] ?: return null
        l += MixRecording("rec${l.size + 1}", fileName, startedAt, durationMs); return "ok"
    }
    override fun recoverRecording(sessionId: String, name: String, fileName: String, startedAt: Double, durationMs: Int) {
        val l = data.getOrPut(sessionId) { mutableListOf() }
        l += MixRecording("rec${l.size + 1}", fileName, startedAt, durationMs)
    }
}

class MixRecorderTest {
    private val root = kotlin.io.path.createTempDirectory("mixrec").toFile()
    private val sessions = FakeSessions().also { it.data["s1"] = mutableListOf() }
    private val tap = RecordingTapSink(1024)
    private var audible = true
    private var now = 1_000_000L
    private val writers = ArrayList<FakeWriter>()
    private fun recorder(dur: (File) -> Int = { 1000 }) = MixRecorder(
        root, tap, sessions, { audible }, { f -> FakeWriter(f).also { writers += it } }, { now }, durationOf = dur,
    )

    @Test fun startStopGatesTapAndFilesToSessionCurrentAtStart() {
        val r = recorder()
        assertTrue(r.start())
        assertTrue(tap.isCapturing)
        assertEquals("recording-1.aac", r.activeTake!!.fileName)
        sessions.currentId = "s2" // Reset mid-capture
        writers[0].appendedSeconds = 12.5
        now += 20_000
        r.stop()
        assertFalse(tap.isCapturing)
        assertNull(r.activeTake)
        val rec = sessions.data["s1"]!!.single()
        assertEquals(12_500, rec.durationMs) // content clock, not the 20 s wall clock
        assertNull(sessions.data["s2"])
    }

    @Test fun wallClockOnlyWhenNoMediaAppended() {
        val r = recorder(); r.start(); now += 3_000; r.stop()
        assertEquals(3_000, sessions.data["s1"]!!.single().durationMs)
    }

    @Test fun deletedSessionIsRevivedOnStop() {
        val r = recorder(); r.start()
        sessions.data.remove("s1")
        writers[0].appendedSeconds = 2.0
        r.stop()
        assertEquals(2_000, sessions.data["s1"]!!.single().durationMs)
    }

    @Test fun secondStartWhileRecordingIsNoop() {
        val r = recorder(); assertTrue(r.start()); assertFalse(r.start()); assertEquals(1, writers.size)
    }

    @Test fun writerFailureAutoStopsFilesPartialAndMessagesOnce() {
        val r = recorder(); r.start()
        writers[0].appendedSeconds = 4.0
        writers[0].die()
        assertFalse(r.isRecording)
        assertEquals(1, sessions.data["s1"]!!.size)
        assertEquals(MixRecorder.FAILURE_MESSAGE, r.writerFailureMessage.value)
        writers[0].die() // one-shot at the writer; a second call must not refile
        assertEquals(1, sessions.data["s1"]!!.size)
        r.consumeWriterFailure()
        assertNull(r.writerFailureMessage.value)
    }

    @Test fun stallFlipsAfterFiveSecondsAudibleAndClearsOnRecovery() {
        val r = recorder(); r.start()
        val w = writers[0]
        w.appendedSeconds = 1.0; r.checkStall(now)          // progress
        now += 2_000; r.checkStall(now)                     // stagnant starts
        assertFalse(r.captureStalled)
        now += 4_000; r.checkStall(now)                     // 4 s stagnant
        assertFalse(r.captureStalled)
        now += 2_000; r.checkStall(now)                     // 6 s
        assertTrue(r.captureStalled)
        w.appendedSeconds = 2.0; now += 2_000; r.checkStall(now)
        assertFalse(r.captureStalled)
    }

    @Test fun silentMixNeverStalls() {
        val r = recorder(); r.start(); audible = false
        repeat(10) { now += 2_000; r.checkStall(now) }
        assertFalse(r.captureStalled)
    }

    @Test fun nextTakeBumpsPastExistingFile() {
        val r = recorder(); r.start(); r.stop()
        r.start()
        assertEquals("recording-2.aac", r.activeTake!!.fileName)
    }

    @Test fun recoverOrphansIsIdempotentRevivesSessionAndNeverAdoptsActiveTake() {
        val dirGone = SessionFolders.sessionFolder(root, "gone")!!
        File(dirGone, "recording-1.aac").writeBytes(ByteArray(8))
        val dirDead = SessionFolders.sessionFolder(root, "dead")!!
        File(dirDead, "recording-1.aac").writeBytes(ByteArray(0))
        val r = recorder { f -> if (f.parentFile.name == "dead") 0 else 1500 }
        r.start() // s1/recording-1.aac is live
        assertEquals(1, r.recoverOrphans())
        assertEquals(1500, sessions.data["gone"]!!.single().durationMs)
        assertEquals(0, r.recoverOrphans()) // idempotent
        assertEquals(1, sessions.data["gone"]!!.size)
        assertNull(sessions.data["dead"])
        assertTrue(sessions.data["s1"]!!.isEmpty())
        r.stop()
        assertNotNull(sessions.data["s1"]!!.singleOrNull())
        assertEquals(0, r.recoverOrphans())
    }
}
