package com.levi.pocketdj.diag

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DiagLogTest {
    private class FakeScheduler(val clock: Clock) : DiagScheduler {
        class Task(val due: Long, val block: () -> Unit) { var cancelled = false }
        val tasks = mutableListOf<Task>()
        override fun schedule(delayMs: Long, block: () -> Unit): () -> Unit {
            val t = Task(clock.now + delayMs, block); tasks += t
            return { t.cancelled = true }
        }
        fun advance(ms: Long) {
            val target = clock.now + ms
            while (true) {
                val next = tasks.filter { !it.cancelled && it.due <= target }.minByOrNull { it.due } ?: break
                clock.now = maxOf(clock.now, next.due); tasks.remove(next); next.block()
            }
            clock.now = target
        }
    }

    private class Clock { var now = 1_800_000_000_000L }

    private class FakeUploader : DiagUploader {
        val puts = mutableListOf<Pair<String, String>>()
        var outcome: UploadOutcome = UploadOutcome.Ok
        var gate: CompletableDeferred<Unit>? = null
        override suspend fun put(key: String, body: ByteArray, creds: DiagCredentialStore.Credentials): UploadOutcome {
            gate?.await()
            puts += key to String(body)
            return outcome
        }
    }

    private class Rig(scope: TestScope, enabled: Boolean = true, withKey: Boolean = true) {
        val clock = Clock()
        val sched = FakeScheduler(clock)
        val up = FakeUploader()
        val secrets = InMemorySecretStore()
        val creds = DiagCredentialStore(secrets)
        val prefs = MemoryDiagPrefs()
        val settings = DiagSettings(prefs)
        val log: DiagLog

        init {
            if (withKey) creds.save("AKIAAAAAAAAAAAAAAAAA", "s")
            log = DiagLog(enabled, creds, settings, up, scope, sched, { clock.now }, "diag/android-abcd1234/stamp-b1")
        }
    }

    @Test fun lineFormatAndLaunchStatusLine() = runTest {
        val r = Rig(this)
        r.log.log("play", "hello")
        r.log.flushOnBackground(); advanceUntilIdle()
        val body = r.up.puts.single().second
        assertTrue(body.lines().first().matches(Regex("""\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \[diag] status key=present last-ok=never last-err=none""")))
        assertTrue(body.contains(" [play] hello\n"))
    }

    @Test fun debounceFlushIs15sAnd3sInTelemetry() = runTest {
        val r = Rig(this)
        r.log.log("a", "x")
        r.sched.advance(14_999); advanceUntilIdle(); assertTrue(r.up.puts.isEmpty())
        r.sched.advance(1); advanceUntilIdle(); assertEquals(1, r.up.puts.size)

        r.log.telemetryEnabled = true // logs "mode ON" -> arms 3 s timer
        r.sched.advance(2_999); advanceUntilIdle(); assertEquals(1, r.up.puts.size)
        r.sched.advance(1); advanceUntilIdle(); assertEquals(2, r.up.puts.size)
    }

    @Test fun errorCategoryFlushesImmediately() = runTest {
        val r = Rig(this)
        r.log.log("error", "boom"); advanceUntilIdle()
        assertEquals(1, r.up.puts.size)
        assertTrue(r.up.puts[0].second.contains("[error] boom"))
    }

    @Test fun flushAtTwentyFivePendingLines() = runTest {
        val r = Rig(this)
        // 1 launch status line already pending; 23 more stays under 25.
        repeat(23) { r.log.log("a", "$it") }; advanceUntilIdle(); assertTrue(r.up.puts.isEmpty())
        r.log.log("a", "last"); advanceUntilIdle()
        assertEquals(1, r.up.puts.size)
    }

    @Test fun rotationAtFiveHundredLinesWithContinuityMarker() = runTest {
        val r = Rig(this)
        repeat(520) { r.log.log("a", "$it") }; advanceUntilIdle()
        r.log.flushOnBackground(); advanceUntilIdle()
        val keys = r.up.puts.map { it.first }.distinct()
        assertTrue(keys.contains("diag/android-abcd1234/stamp-b1.log"))
        assertTrue(keys.contains("diag/android-abcd1234/stamp-b1-p2.log"))
        val p1 = r.up.puts.last { it.first.endsWith("b1.log") }.second.trimEnd().lines()
        assertEquals(500, p1.size)
        val p2 = r.up.puts.last { it.first.endsWith("-p2.log") }.second.lines()
        assertTrue(p2.first().endsWith("[rotate] continues in part 2"))
    }

    @Test fun sessionCapMutesAfterOneMarker() = runTest {
        val r = Rig(this)
        repeat(DiagLog.SESSION_LINE_LIMIT + 50) { r.log.log("a", "$it") }
        advanceUntilIdle(); r.log.flushOnBackground(); advanceUntilIdle()
        val all = r.up.puts.joinToString("\n") { it.second }
        assertEquals(1, Regex("session line cap reached").findAll(r.up.puts.last().second).count().coerceAtLeast(
            if (all.contains("session line cap reached")) 1 else 0))
        val lastKey = r.up.puts.last().first
        assertTrue(lastKey.contains("-p80") || lastKey.contains("-p81"))
        val before = r.up.puts.size
        r.log.log("a", "ignored"); r.log.flushOnBackground(); advanceUntilIdle()
        assertEquals(before, r.up.puts.size)
    }

    @Test fun keylessBuffersTo499PlusMarkerAndNeverUploads() = runTest {
        val r = Rig(this, withKey = false)
        repeat(700) { r.log.log("a", "$it") }
        r.log.log("error", "still nothing"); r.log.flushOnBackground(); advanceUntilIdle()
        assertTrue(r.up.puts.isEmpty())
        r.creds.save("AKIAAAAAAAAAAAAAAAAA", "s")
        r.log.reloadCredentials(); advanceUntilIdle()
        // 499 buffered + 1 overflow marker; the "key configured" line trips the 500-line seal.
        val body = r.up.puts.first().second.trimEnd().lines()
        assertEquals("diag/android-abcd1234/stamp-b1.log", r.up.puts.first().first)
        assertTrue(body.any { it.contains("keyless buffer full") })
        assertEquals(1, body.count { it.contains("keyless buffer full") })
        assertTrue(body.size in 500..501)
        assertFalse(body.any { it.contains("still nothing") })
    }

    @Test fun lateKeyUploadsBufferedLinesImmediately() = runTest {
        val r = Rig(this, withKey = false)
        r.log.log("early", "launch line")
        r.creds.save("AKIAAAAAAAAAAAAAAAAA", "s")
        r.log.reloadCredentials(); advanceUntilIdle()
        val body = r.up.puts.single().second
        assertTrue(body.contains("[early] launch line"))
        assertTrue(body.contains("key configured; late start"))
        assertTrue(r.log.uploadStatus.value.keyPresent)
    }

    @Test fun uploadsSerializedAndNewestBodyWins() = runTest {
        val r = Rig(this)
        r.up.gate = CompletableDeferred()
        r.log.log("error", "one"); advanceUntilIdle()      // first PUT starts, blocks on gate
        r.log.log("error", "two")
        r.log.log("error", "three"); advanceUntilIdle()    // coalesced behind the in-flight PUT
        assertTrue(r.up.puts.isEmpty())
        r.up.gate!!.complete(Unit); advanceUntilIdle()
        assertEquals(2, r.up.puts.size)                    // in-flight (one) + ONE coalesced newest
        assertTrue(r.up.puts[0].second.contains("[error] one"))
        assertFalse(r.up.puts[0].second.contains("[error] two"))
        assertTrue(r.up.puts[1].second.contains("[error] three"))
    }

    @Test fun statusTransitionsLoggedOnlyOnChangeAndPersist() = runTest {
        val r = Rig(this)
        r.up.outcome = UploadOutcome.Http(403)
        r.log.log("error", "a"); advanceUntilIdle()
        assertTrue(r.log.uploadStatus.value.failing)
        assertEquals("HTTP 403", r.log.uploadStatus.value.lastError)
        r.log.log("error", "b"); advanceUntilIdle()        // still failing: no second FAILED line
        r.log.flushOnBackground(); advanceUntilIdle()
        val tail = r.up.puts.last().second
        assertEquals(1, Regex("upload FAILED HTTP 403").findAll(tail).count())

        r.up.outcome = UploadOutcome.Ok
        r.log.log("error", "c"); advanceUntilIdle()
        assertFalse(r.log.uploadStatus.value.failing)
        r.log.log("error", "d"); advanceUntilIdle()
        assertEquals(1, Regex("upload recovered \\(was HTTP 403\\)").findAll(r.up.puts.last().second).count())

        // persisted across "launches"
        val s2 = DiagSettings(r.prefs).loadStatus(true, true)
        assertNotNull(s2.lastSuccessAt); assertEquals("HTTP 403", s2.lastError)
    }

    @Test fun statusSummaryWording() {
        val now = 1_000_000L
        assertEquals("off — release build (uploads disabled by design)", UploadStatus(false, false).summary(now))
        assertEquals("DISABLED — no diag key (last ok never)", UploadStatus(true, false).summary(now))
        assertEquals("ok — no upload yet this install", UploadStatus(true, true).summary(now))
        assertEquals("ok — last upload 30s ago", UploadStatus(true, true, lastSuccessAt = now - 30_000).summary(now))
        assertEquals("ok — last upload 5m ago", UploadStatus(true, true, lastSuccessAt = now - 300_000).summary(now))
        assertEquals("FAILING — HTTP 403 (last ok 3h ago)",
            UploadStatus(true, true, now - 3 * 3_600_000L, "HTTP 403", now - 1000).summary(now))
    }

    @Test fun telemetryIsNoopUnlessEnabled() = runTest {
        val r = Rig(this)
        r.log.telemetry("tap", "secret song"); r.log.flushOnBackground(); advanceUntilIdle()
        assertFalse(r.up.puts.single().second.contains("secret song"))
        r.log.telemetryEnabled = true
        r.log.telemetry("tap", "Song Title"); r.log.flushOnBackground(); advanceUntilIdle()
        assertTrue(r.up.puts.last().second.contains("[tap] Song Title"))
    }

    @Test fun disabledIsCompleteNoop() = runTest {
        val r = Rig(this, enabled = false)
        r.log.log("error", "x"); r.log.flushOnBackground(); r.log.reloadCredentials(); advanceUntilIdle()
        assertTrue(r.up.puts.isEmpty())
        assertTrue(r.sched.tasks.isEmpty())
        assertFalse(r.log.uploadStatus.value.channelEnabled)
    }

    @Test fun captureMirrorsOnlyWhenOnAndSavesSession() = runTest {
        val dir = File.createTempFile("cap", "").apply { delete(); mkdirs() }
        val cap = CaptureSessions(dir) { 42L }
        val r = Rig(this, enabled = false)
        r.log.capture = cap
        r.log.log("a", "before")                 // capture off -> nothing buffered
        assertNull(cap.stop())
        cap.start()
        r.log.log("a", "during")                 // mirrored even though uploads are off
        val f = cap.stop()!!
        assertTrue(f.readText().contains("[a] during"))
        assertFalse(f.readText().contains("before"))
        assertEquals(listOf(f), cap.sessions())
        assertTrue(cap.delete(f)); assertTrue(cap.sessions().isEmpty())
        dir.deleteRecursively()
    }

    @Test fun keyBaseFormat() {
        assertEquals("diag/android-abcd1234/2026-10-27T01-02-03Z-b7",
            DiagLog.keyBase("abcd1234-ffff", 1793062923000L, 7))
    }

    @Test fun jankDetectorFlagsGapsOver500ms() {
        val d = JankDetector(500)
        assertNull(d.onFrame(1_000_000_000))
        assertNull(d.onFrame(1_016_000_000))
        assertEquals(600L, d.onFrame(1_616_000_000))
        d.reset()
        assertNull(d.onFrame(9_000_000_000))
    }

    @Test fun npLogMirrorsNpLine() = runTest {
        val r = Rig(this)
        DiagLog.shared = r.log
        val seen = mutableListOf<String>()
        NPLog.logd = { tag, msg -> seen += "$tag|$msg" }
        try {
            NPLog.trace("card write")
            NPLog.lane(NPLog.DEADAIR, "gap 1200ms")
            r.log.flushOnBackground(); advanceUntilIdle()
        } finally { DiagLog.shared = null }
        assertEquals(listOf("PocketDJ.np|[app] card write"), seen)
        val body = r.up.puts.last().second
        assertTrue(body.contains("[np] [app] card write"))
        assertTrue(body.contains("[deadair] gap 1200ms"))
        assertEquals(11, NPLog.LANES.size)
    }
}
