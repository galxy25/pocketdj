package com.levi.pocketdj.onboarding

import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.data.settings.SourceConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingStoreTest {
    private class FakeStorage(var json: String? = null) : OnboardingMarkerStorage {
        val writes = mutableListOf<String>()
        override suspend fun read() = json
        override suspend fun write(json: String) { this.json = json; writes += json }
    }

    private val scopes = mutableListOf<CoroutineScope>()
    private fun scope() = CoroutineScope(Dispatchers.Unconfined + Job()).also { scopes += it }

    @After fun tearDown() = scopes.forEach { it.cancel() }

    private fun marker(s: FakeStorage) = OnboardingMarkerCodec.decode(s.json)

    private fun store(
        s: FakeStorage = FakeStorage(),
        had: Boolean = false,
        env: Map<String, String> = emptyMap(),
    ) = OnboardingStore(s, had, scope(), env)

    // ---- decision table -------------------------------------------------

    @Test fun decide_decisionTable() {
        val none = emptyMap<String, String>()
        val d = OnboardingStore.Companion::decide
        assertEquals(OnboardingDecision.Show(OnboardingStage.Profile), d(null, false, none))
        assertEquals(OnboardingDecision.SkipAndStamp, d(null, true, none))
        assertEquals(OnboardingDecision.Skip, d(OnboardingMarker.Completed, false, none))
        assertEquals(OnboardingDecision.Skip, d(OnboardingMarker.Completed, true, none))
        assertEquals(OnboardingDecision.Show(OnboardingStage.Profile), d(OnboardingMarker.Pending, true, none))
        assertEquals(
            OnboardingDecision.Show(OnboardingStage.Sources),
            d(OnboardingMarker.Started(OnboardingStage.Sources), true, none),
        )
    }

    @Test fun decide_forceSeamWinsOverEverything() {
        val force = mapOf("PDJ_SHOW_ONBOARDING" to "1", "PDJ_USE_FIXTURE" to "x")
        for (m in listOf(null, OnboardingMarker.Completed, OnboardingMarker.Pending, OnboardingMarker.Started(OnboardingStage.Sources))) {
            for (had in listOf(true, false)) {
                assertEquals(OnboardingDecision.Show(OnboardingStage.Profile), OnboardingStore.decide(m, had, force))
            }
        }
    }

    @Test fun decide_fixtureSeamSkips() {
        assertEquals(
            OnboardingDecision.Skip,
            OnboardingStore.decide(null, false, mapOf("PDJ_USE_FIXTURE" to "1")),
        )
    }

    // ---- store behaviour ------------------------------------------------

    @Test fun freshInstall_showsProfile_andStampsStarted() {
        val s = FakeStorage()
        val st = store(s, had = false)
        assertEquals(OnboardingStore.State(loaded = true, complete = false, stage = OnboardingStage.Profile), st.state.value)
        assertEquals(OnboardingMarker.Started(OnboardingStage.Profile), marker(s))
        assertFalse(st.isComplete)
    }

    @Test fun upgrade_withSettingsAndNoMarker_stampsCompletedSilently() {
        val s = FakeStorage()
        val st = store(s, had = true)
        assertTrue(st.isComplete)
        assertEquals(OnboardingMarker.Completed, marker(s))
    }

    @Test fun resumesAtStartedStage_evenWithSettingsBlob() {
        val s = FakeStorage("""{"version":1,"state":"started","stage":1}""")
        val st = store(s, had = true)
        assertEquals(OnboardingStage.AppleMusic, st.state.value.stage)
        assertFalse(st.isComplete)
    }

    @Test fun completedMarker_neverShows_andWritesNothing() {
        val s = FakeStorage("""{"version":1,"state":"completed","completedAtMs":1}""")
        val st = store(s, had = false)
        assertTrue(st.isComplete)
        assertTrue(s.writes.isEmpty())
    }

    @Test fun pendingMarker_showsProfileEvenWithSettings() {
        val st = store(FakeStorage("""{"version":1,"state":"pending"}"""), had = true)
        assertEquals(OnboardingStage.Profile, st.state.value.stage)
        assertFalse(st.isComplete)
    }

    @Test fun forceEnvironment_showsOnExistingCompletedInstall() {
        val s = FakeStorage("""{"version":1,"state":"completed"}""")
        val st = store(s, had = true, env = mapOf("PDJ_SHOW_ONBOARDING" to "1"))
        assertFalse(st.isComplete)
        assertEquals(OnboardingMarker.Started(OnboardingStage.Profile), marker(s))
    }

    @Test fun forceShow_afterLoad_reopensTheFlow() {
        val st = store(FakeStorage("""{"version":1,"state":"completed"}"""), had = true)
        assertTrue(st.isComplete)
        st.forceShow()
        assertFalse(st.isComplete)
        assertEquals(OnboardingStage.Profile, st.state.value.stage)
    }

    @Test fun advanceBackComplete_persistMarker() {
        val s = FakeStorage()
        val st = store(s)
        st.advance()
        assertEquals(OnboardingStage.AppleMusic, st.state.value.stage)
        assertEquals(OnboardingMarker.Started(OnboardingStage.AppleMusic), marker(s))
        st.advance()
        assertEquals(OnboardingMarker.Started(OnboardingStage.Sources), marker(s))
        st.back()
        assertEquals(OnboardingStage.AppleMusic, st.state.value.stage)
        assertEquals(OnboardingMarker.Started(OnboardingStage.AppleMusic), marker(s))
        st.back()
        st.back() // never past the first
        assertEquals(OnboardingStage.Profile, st.state.value.stage)
        st.advance(); st.advance()
        st.advance() // past the last stage finishes
        assertTrue(st.isComplete)
        assertEquals(OnboardingMarker.Completed, marker(s))
        assertTrue(s.json!!.contains("completedAtMs"))
    }

    @Test fun mutatorsAfterComplete_areNoOps() {
        val s = FakeStorage()
        val st = store(s)
        st.complete()
        val writes = s.writes.size
        st.advance(); st.back(); st.complete()
        assertEquals(writes, s.writes.size)
    }

    @Test fun completeFiresHookExactlyOnce() {
        val st = store()
        var fired = 0
        st.onComplete = { fired++ }
        st.complete(); st.complete()
        assertEquals(1, fired)
    }

    @Test fun waitUntilComplete_releasesAllWaitersOnComplete() = runTest {
        val st = store()
        var released = 0
        val jobs = List(3) { launch(Dispatchers.Unconfined) { st.waitUntilComplete(); released++ } }
        assertEquals(0, released)
        st.complete()
        jobs.forEach { it.join() }
        assertEquals(3, released)
    }

    @Test fun waitUntilComplete_returnsImmediatelyWhenNeverShown() = runTest {
        store(FakeStorage("""{"version":1,"state":"completed"}"""), had = true).waitUntilComplete()
    }

    @Test fun waitUntilComplete_waitsForMarkerLoad() = runTest {
        // Storage that never answers read(): the store must not report complete.
        val hang = object : OnboardingMarkerStorage {
            override suspend fun read(): String? = kotlinx.coroutines.awaitCancellation()
            override suspend fun write(json: String) {}
        }
        val st = OnboardingStore(hang, hadPersistedSettings = true, scope = scope())
        assertFalse(st.state.value.loaded)
        assertFalse(st.isComplete)
        assertThrows(OnboardingIncompleteException::class.java) { st.vetoIfIncomplete() }
    }

    @Test fun veto_throwsWhileIncomplete_passesAfter() {
        val st = store()
        assertThrows(OnboardingIncompleteException::class.java) { st.vetoIfIncomplete() }
        st.complete()
        st.vetoIfIncomplete()
    }

    @Test fun forcePending_writesPendingWithoutChangingLiveState() = runTest {
        val s = FakeStorage()
        val st = store(s, had = true) // completes silently
        assertTrue(st.isComplete)
        st.forcePending()
        assertEquals(OnboardingMarker.Pending, marker(s))
        assertTrue(st.isComplete)
        // ...and the NEXT launch shows the flow even though settings exist.
        val next = store(s, had = true)
        assertFalse(next.isComplete)
        assertEquals(OnboardingStage.Profile, next.state.value.stage)
    }

    @Test fun forcePending_suspendsUntilWritten() = runTest {
        val s = FakeStorage("""{"version":1,"state":"completed"}""")
        val st = store(s, had = true)
        st.forcePending()
        // Returned => already applied, so a following wipe-ordering decision is deterministic.
        assertEquals(OnboardingMarker.Pending, marker(s))
    }

    @Test fun vetoAwaitingLoad_doesNotVetoOnboardedColdStart() = runTest {
        val gate = CompletableDeferred<Unit>()
        val s = object : OnboardingMarkerStorage {
            override suspend fun read(): String { gate.await(); return """{"version":1,"state":"completed"}""" }
            override suspend fun write(json: String) {}
        }
        val st = OnboardingStore(s, true, scope())
        assertThrows(OnboardingIncompleteException::class.java) { st.vetoIfIncomplete() } // not loaded yet
        val job = launch(Dispatchers.Default) { st.vetoIfIncompleteAwaitingLoad() }
        gate.complete(Unit)
        job.join() // no exception
        assertTrue(st.isComplete)
    }

    @Test fun vetoAwaitingLoad_vetoesIncompleteAfterLoad() = runTest {
        val st = store()
        assertThrows(OnboardingIncompleteException::class.java) { runBlocking { st.vetoIfIncompleteAwaitingLoad() } }
    }

    @Test fun markPendingAfterReset_static() = runTest {
        val s = FakeStorage("""{"version":1,"state":"completed"}""")
        OnboardingStore.markPendingAfterReset(s)
        assertEquals(OnboardingMarker.Pending, marker(s))
    }

    @Test fun killAtStageTwo_relaunchResumesAtStageTwo() {
        val s = FakeStorage()
        val first = store(s)
        first.advance()
        first.advance()
        val relaunched = store(s, had = true) // the settings blob exists by now
        assertEquals(OnboardingStage.Sources, relaunched.state.value.stage)
        assertFalse(relaunched.isComplete)
    }

    // ---- stubs / sources ------------------------------------------------

    @Test fun stubLinkProbe_isUnavailable() = runTest {
        assertTrue(StubLinkDeviceProbe.probe() is LinkProbeResult.Unavailable)
    }

    @Test fun applyOnboardingSources_allThree_fromDefault() {
        val out = applyOnboardingSources(AppSettings.defaultSources(), vinyl = true, digital = true, streaming = true)
        assertEquals(
            listOf(Endpoints.SOURCE_NAME_VINYL, Endpoints.SOURCE_NAME_DIGITAL, Endpoints.SOURCE_NAME_APPLE_MUSIC),
            out.map { it.name },
        )
        assertTrue(out.all { it.enabled })
    }

    @Test fun applyOnboardingSources_vinylAndDigitalOnly() {
        val out = applyOnboardingSources(AppSettings.defaultSources(), vinyl = true, digital = true, streaming = false)
        assertEquals(listOf(Endpoints.SOURCE_NAME_VINYL, Endpoints.SOURCE_NAME_DIGITAL), out.map { it.name })
    }

    @Test fun applyOnboardingSources_zeroPicksIsLegitimate_andKeepsCustomSources() {
        val custom = SourceConfig("c1", "Mine", "https://example.com/i.json")
        val out = applyOnboardingSources(AppSettings.defaultSources() + custom, vinyl = false, digital = false, streaming = false)
        assertEquals(listOf(custom), out)
    }

    @Test fun applyOnboardingSources_matchesByUrl_andIsIdempotent() {
        val renamed = SourceConfig("x", "Renamed vinyl", Endpoints.VINYL_INDEX_URL)
        val out = applyOnboardingSources(listOf(renamed), vinyl = true, digital = false, streaming = false)
        assertEquals(listOf(renamed), out)
        val removed = applyOnboardingSources(listOf(renamed), vinyl = false, digital = false, streaming = false)
        assertTrue(removed.isEmpty())
        val again = applyOnboardingSources(out, vinyl = true, digital = false, streaming = false)
        assertEquals(out, again)
        assertNull(again.firstOrNull { it.name == Endpoints.SOURCE_NAME_DIGITAL })
    }
}
