package com.levi.pocketdj.data.sync

import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class CloudSyncServiceTest {
    @get:Rule val tmp = TemporaryFolder()

    private val localOld = 1_000_000_000_000L // 2001: far older than any "now" write

    private class Fixture(
        val dir: File,
        val db: InMemoryCloudDocDatabase,
        val svc: CloudSyncService,
        val file: File,
        val reloads: MutableList<String>,
    )

    private fun TestScope.fixture(
        enabled: Boolean = true,
        db: InMemoryCloudDocDatabase = InMemoryCloudDocDatabase(),
        clock: () -> Long = { 0L },
        reload: ((File) -> Unit)? = null,
        scope: CoroutineScope = backgroundScope,
    ): Fixture {
        val dir = tmp.newFolder()
        val svc = CloudSyncService(db, { enabled }, File(dir, "state.json"), scope, clock)
        val file = File(dir, "profile.json")
        val reloads = mutableListOf<String>()
        svc.register("profile", file, reload = { reloads += "profile"; reload?.invoke(file) })
        return Fixture(dir, db, svc, file, reloads)
    }

    private fun File.writeAt(text: String, mtime: Long) { writeText(text); assertTrue(setLastModified(mtime)) }

    private fun cloud(text: String, mtime: Long) = CloudDoc("profile", text.toByteArray(), mtime.toDouble(), "Mac")

    // ---- LWW matrix -------------------------------------------------------------------------

    @Test fun newerCloudIsPulled_backupTaken_watermarkEqualsPulledMtime() = runTest {
        val f = fixture()
        f.file.writeAt("old", localOld)
        f.db.put(cloud("new", localOld + 10_000))
        f.svc.syncNow()
        assertEquals("new", f.file.readText())
        assertEquals("old", File(f.dir, "profile.json.pre-cloud").readText())
        assertEquals(listOf("profile"), f.reloads)
        assertEquals(f.file.lastModified().toDouble(), f.svc.watermark("profile"))
        assertEquals("Pulled profile", f.svc.status.value.lastSummary)
        assertTrue(f.db.saved.isEmpty())
    }

    @Test fun pulledDocIsNotBouncedBackOnNextPass() = runTest {
        val f = fixture()
        f.file.writeAt("old", localOld)
        f.db.put(cloud("new", localOld + 10_000))
        f.svc.syncNow()
        f.svc.syncNow()
        assertTrue(f.db.saved.isEmpty())
        assertEquals("Everything in sync", f.svc.status.value.lastSummary)
    }

    @Test fun newerLocalIsPushed() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld + 50_000)
        f.db.put(cloud("theirs", localOld))
        f.svc.syncNow()
        assertEquals(listOf("profile"), f.db.saved)
        assertEquals("mine", String(f.db.get("profile")!!.payload))
        assertEquals((localOld + 50_000).toDouble(), f.db.get("profile")!!.modifiedAtMs, 0.0)
        assertEquals("Pushed profile", f.svc.status.value.lastSummary)
        assertEquals((localOld + 50_000).toDouble(), f.svc.watermark("profile"))
    }

    @Test fun localOnlyDocPushesWhenCloudAbsent() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld)
        f.svc.syncNow()
        assertEquals(listOf("profile"), f.db.saved)
    }

    @Test fun equalWithinSkewDoesNothing() = runTest {
        val f = fixture()
        f.file.writeAt("same", localOld)
        f.db.put(cloud("cloudcopy", localOld + 1_500)) // cloud newer, but inside the 2 s slack
        f.svc.syncNow()
        assertEquals("same", f.file.readText())
        assertTrue(f.db.saved.isEmpty())
        assertTrue(f.reloads.isEmpty())
        f.file.writeAt("same", localOld + 3_400) // local newer by 1.9 s: still the same write
        f.svc.syncNow()
        assertTrue(f.db.saved.isEmpty())
    }

    @Test fun justOutsideSkewPulls() = runTest {
        val f = fixture()
        f.file.writeAt("old", localOld)
        f.db.put(cloud("new", localOld + 2_001))
        f.svc.syncNow()
        assertEquals("new", f.file.readText())
    }

    // ---- watermark rules --------------------------------------------------------------------

    @Test fun mergeOnReloadClearsWatermarkAndSupersetPushesNextPass() = runTest {
        val f = fixture(reload = { file ->
            file.writeText("superset")
            file.setLastModified(file.lastModified() + 5_000)
        })
        f.file.writeAt("old", localOld)
        f.db.put(cloud("peer", localOld + 10_000))
        f.svc.syncNow()
        assertNull(f.svc.watermark("profile"))
        assertTrue(f.db.saved.isEmpty())
        f.svc.syncNow()
        assertEquals(listOf("profile"), f.db.saved)
        assertEquals("superset", String(f.db.get("profile")!!.payload))
    }

    @Test fun watermarkSurvivesRestartViaStateFile() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld + 50_000)
        f.svc.syncNow()
        val again = CloudSyncService(f.db, { true }, File(f.dir, "state.json"), backgroundScope)
        again.register("profile", f.file)
        assertEquals((localOld + 50_000).toDouble(), again.watermark("profile"))
        again.syncNow()
        assertEquals(1, f.db.saved.size) // not re-pushed
        assertNotNull(again.status.value.lastSyncAtMs)
    }

    // ---- push gate --------------------------------------------------------------------------

    @Test fun pushAllowedFalseBlocksPushesButNotPulls() = runTest {
        val f = fixture()
        f.svc.pushAllowed = { false }
        f.file.writeAt("mine", localOld + 50_000)
        f.svc.syncNow()
        assertTrue(f.db.saved.isEmpty())
        f.svc.pushDirty()
        assertTrue(f.db.saved.isEmpty())
        f.db.put(cloud("pulled", localOld + 90_000))
        f.svc.syncNow()
        assertEquals("pulled", f.file.readText())
        f.svc.pushAllowed = { true }
        f.file.writeAt("mine2", System.currentTimeMillis() + 60_000)
        f.svc.syncNow()
        assertEquals(listOf("profile"), f.db.saved)
    }

    // ---- pushDirty --------------------------------------------------------------------------

    @Test fun pushDirtyNeverUploadsOverStrictlyNewerCloud() = runTest {
        val f = fixture()
        f.file.writeAt("stale", localOld + 10_000)
        f.db.put(cloud("fresh", localOld + 60_000))
        f.svc.pushDirty()
        assertTrue(f.db.saved.isEmpty())
        assertEquals("fresh", String(f.db.get("profile")!!.payload))
    }

    @Test fun pushDirtyPushesWhenAbsentFromProbeOrNotNewer() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld + 10_000)
        f.svc.pushDirty()
        assertEquals(listOf("profile"), f.db.saved)
        assertEquals(1, f.db.fetchMetaCalls)
    }

    @Test fun pushDirtyMetaProbeFailureFallsBackToBlindPush() = runTest {
        val f = fixture()
        f.db.put(cloud("fresh", localOld + 60_000))
        f.db.metaFailure = java.io.IOException("offline")
        f.file.writeAt("offline-play", localOld + 10_000)
        f.svc.pushDirty()
        assertEquals(listOf("profile"), f.db.saved) // blind push: losing the offline set is worse
    }

    @Test fun pushDirtySkipsCleanFilesWithoutProbing() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld + 10_000)
        f.svc.pushDirty()
        f.svc.pushDirty()
        assertEquals(1, f.db.fetchMetaCalls)
        assertEquals(1, f.db.saved.size)
    }

    @Test fun pushOnBackgroundNoopWhenDisabledOrAccountMissing() = runTest {
        val off = fixture(enabled = false)
        off.file.writeAt("mine", localOld)
        assertNull(off.svc.pushOnBackground())
        val noAcct = fixture(db = InMemoryCloudDocDatabase(account = false))
        noAcct.file.writeAt("mine", localOld)
        noAcct.svc.pushDirty()
        assertTrue(noAcct.db.saved.isEmpty())
    }

    // ---- launch deadline / throttles --------------------------------------------------------

    @Test fun syncAtLaunchReturnsWithinDeadlineWhilePassContinues() = runTest {
        val db = InMemoryCloudDocDatabase().apply { latency = { delay(30_000) } }
        val f = fixture(db = db)
        f.file.writeAt("mine", localOld)
        f.svc.syncAtLaunch(deadlineMs = 8_000)
        assertEquals(8_000L, currentTime)
        assertTrue(db.saved.isEmpty())
        advanceTimeBy(200_000)
        runCurrent()
        assertEquals(listOf("profile"), db.saved) // the pass kept running in the background
    }

    @Test fun syncAtLaunchWaitsForAFastPass() = runTest {
        val f = fixture()
        f.file.writeAt("mine", localOld)
        f.svc.syncAtLaunch()
        assertEquals(0L, currentTime)
        assertEquals(listOf("profile"), f.db.saved)
    }

    @Test fun foregroundSyncIsThrottledToFiveMinutes() = runTest {
        var now = 10_000_000L
        val f = fixture(clock = { now })
        f.file.writeAt("mine", localOld)
        assertNotNull(f.svc.syncOnForeground()); runCurrent()
        now += 4 * 60_000
        assertNull(f.svc.syncOnForeground())
        now += 61_000
        assertNotNull(f.svc.syncOnForeground()); runCurrent()
    }

    @Test fun activeTickGapIsTwentySeconds() = runTest {
        var now = 10_000_000L
        val f = fixture(clock = { now })
        assertNotNull(f.svc.syncTick()); runCurrent()
        now += 19_000
        assertNull(f.svc.syncTick())
        now += 2_000
        assertNotNull(f.svc.syncTick()); runCurrent()
        assertEquals(2, f.db.fetchMetaCalls)
    }

    @Test fun launchSyncIgnoresThrottleAndDisabledNeverRuns() = runTest {
        val off = fixture(enabled = false)
        off.file.writeAt("mine", localOld)
        off.svc.syncAtLaunch()
        off.svc.syncNow()
        assertTrue(off.db.saved.isEmpty())
        assertEquals(0, off.db.fetchMetaCalls)
    }

    @Test fun accountUnavailablePassReportsAndDoesNothing() = runTest {
        val f = fixture(db = InMemoryCloudDocDatabase(account = false))
        f.file.writeAt("mine", localOld)
        f.svc.syncNow()
        assertEquals("Account unavailable", f.svc.status.value.lastSummary)
        assertEquals(false, f.svc.status.value.accountAvailable)
        assertEquals(0, f.db.fetchMetaCalls)
    }

    @Test fun passErrorSurfacesAsLastError() = runTest {
        val f = fixture()
        f.db.metaFailure = java.io.IOException("boom")
        f.svc.syncNow()
        assertEquals("boom", f.svc.status.value.lastError)
        assertFalse(f.svc.status.value.syncing)
    }

    // ---- onboarding: restore + probe --------------------------------------------------------

    @Test fun restoreForOnboardingPullsEveryDocRegardlessOfLocalMtimes() = runTest {
        val f = fixture()
        val second = File(f.dir, "collections.json")
        f.svc.register("collections", second)
        // Local files are NEWER than the cloud - an ordinary pass would push; restore must pull.
        val newer = System.currentTimeMillis()
        f.file.writeAt("junk-profile", newer)
        second.writeAt("junk-collections", newer)
        f.db.put(cloud("real-profile", localOld))
        f.db.put(CloudDoc("collections", "real-collections".toByteArray(), localOld.toDouble(), "Mac"))
        val pulled = f.svc.restoreForOnboarding()
        assertEquals(listOf("profile", "collections"), pulled)
        assertEquals("real-profile", f.file.readText())
        assertEquals("real-collections", second.readText())
        assertEquals("junk-profile", File(f.dir, "profile.json.pre-cloud").readText())
        assertTrue(f.db.saved.isEmpty())
        assertEquals("Restored profile, collections", f.svc.status.value.lastSummary)
    }

    @Test fun restoreSkipsKeysAbsentFromCloud() = runTest {
        val f = fixture()
        f.file.writeAt("keep", localOld)
        assertEquals(emptyList<String>(), f.svc.restoreForOnboarding())
        assertEquals("keep", f.file.readText())
        assertEquals("Nothing to restore", f.svc.status.value.lastSummary)
    }

    @Test fun restoreReturnsNullWhenDisabledOrNoAccount() = runTest {
        assertNull(fixture(enabled = false).svc.restoreForOnboarding())
        val f = fixture(db = InMemoryCloudDocDatabase(account = false))
        assertNull(f.svc.restoreForOnboarding())
    }

    @Test fun probeOutcomes() = runTest {
        assertEquals(CloudSyncService.ProfileProbe.Disabled, fixture(enabled = false).svc.probeCloudProfile())

        val noAcct = fixture(db = InMemoryCloudDocDatabase(account = false))
        assertEquals(CloudSyncService.ProfileProbe.NoAccount, noAcct.svc.probeCloudProfile())
        assertEquals(false, noAcct.svc.status.value.accountAvailable)

        val fresh = fixture()
        assertEquals(CloudSyncService.ProfileProbe.Fresh, fresh.svc.probeCloudProfile())
        assertEquals(true, fresh.svc.status.value.accountAvailable)

        val existing = fixture()
        existing.db.put(cloud("""{"schemaVersion":1,"id":"A","name":"DJ Levi","createdAtMs":1.0}""", 1))
        assertEquals(CloudSyncService.ProfileProbe.Existing("DJ Levi"), existing.svc.probeCloudProfile())

        val garbled = fixture()
        garbled.db.put(cloud("not json", 1))
        assertEquals(CloudSyncService.ProfileProbe.Existing(""), garbled.svc.probeCloudProfile())

        val failing = fixture()
        failing.db.fetchFailure = java.io.IOException("500")
        assertEquals(CloudSyncService.ProfileProbe.Unknown, failing.svc.probeCloudProfile())
    }

    @Test fun probeTimesOutToUnknownNeverFreshOnVirtualClock() = runTest {
        val db = InMemoryCloudDocDatabase().apply { latency = { delay(60_000) } }
        val f = fixture(db = db)
        val r = f.svc.probeCloudProfile(deadlineMs = 10_000)
        assertEquals(CloudSyncService.ProfileProbe.Unknown, r)
        assertEquals(10_000L, currentTime)
        assertNull(f.svc.status.value.accountAvailable) // nothing learned about the account
    }

    // ---- local reset ------------------------------------------------------------------------

    @Test fun clearLocalSyncStateDropsWatermarkStateFileAndBackups() = runTest {
        val f = fixture()
        f.file.writeAt("old", localOld)
        f.db.put(cloud("new", localOld + 10_000))
        f.svc.syncNow()
        val backup = File(f.dir, "profile.json.pre-cloud")
        assertTrue(backup.exists() && File(f.dir, "state.json").exists())
        f.svc.clearLocalSyncState()
        assertFalse(backup.exists())
        assertFalse(File(f.dir, "state.json").exists())
        assertNull(f.svc.watermark("profile"))
        assertNull(f.svc.status.value.lastSummary)
        // The erased doc re-pushes only because the local file is newer than cloud again.
        f.file.writeAt("fresh", System.currentTimeMillis() + 60_000)
        f.svc.syncNow()
        assertEquals(listOf("profile"), f.db.saved)
    }

    @Test fun summaryFormatting() {
        assertEquals("Everything in sync", CloudSyncService.summary(emptyList(), emptyList()))
        assertEquals("Pulled a, b · pushed c", CloudSyncService.summary(listOf("a", "b"), listOf("c")))
    }

    @Test fun applyPayloadSeamReceivesBytesInsteadOfDirectWrite() = runTest {
        val f = fixture()
        val seam = File(f.dir, "seam.json")
        var got: String? = null
        f.svc.register("seam", seam, applyPayload = { bytes -> got = String(bytes); seam.writeBytes(bytes) })
        seam.writeAt("old", localOld)
        f.db.put(CloudDoc("seam", "queued".toByteArray(), (localOld + 10_000).toDouble(), "Mac"))
        f.svc.syncNow()
        assertEquals("queued", got)
        assertEquals("queued", seam.readText())
    }
}
