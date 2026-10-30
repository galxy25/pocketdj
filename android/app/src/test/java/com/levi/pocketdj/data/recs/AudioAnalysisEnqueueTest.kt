package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The shortlist PRODUCER: ranking committed -> ids -> enqueueAudioAnalysis (iOS ForYouView.scheduleAudioAnalysis). */
class AudioAnalysisEnqueueTest {
    @get:Rule val tmp = TemporaryFolder()
    private val server = MockWebServer().apply { enqueue(MockResponse().setBody("{}")); start() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @After fun tearDown() { scope.cancel(); server.shutdown() }

    private fun svc(enabled: Boolean): RecommendationService {
        val client = RecEngineClient(OkHttpClient(), base = { server.url("/").toString() }, enrollSecret = { "E" }, deviceId = { "d" })
        return RecommendationService(
            client = client, scope = scope, enabled = { enabled }, shareLifetimePlayCounts = { true },
            profileId = { "p" }, deviceId = { "d" },
            keyFile = File(tmp.root, "k.json"), stateFile = File(tmp.root, "s.json"),
            pendingDeleteFile = File(tmp.root, "pd.json"),
            playsProvider = { emptyList() }, favoritesProvider = { emptyList() },
            collectionsProvider = { emptyList() }, recommendationsEnabledFor = { true },
            clock = { 1_800_000_000_000L }, autoFlushDelayMs = 600_000L,
        )
    }

    private val ranked = ForYouFeedSnapshot(refreshedAtMs = 1.0, zoneIds = listOf("a"))
    private val inputs = ForYouFeedInputs(songs = emptyList(), tracks = emptyList())

    @Test fun enabledRankingEnqueuesSelectedIdsMinusPending() {
        val s = svc(true)
        s.enqueueAudioAnalysis(listOf("held"))
        var sawPending: Set<String>? = null
        val out = s.scheduleAudioAnalysis(ranked, inputs) { _, _, pending ->
            sawPending = pending; listOf("held", "n1", "n2")
        }
        assertEquals(setOf("held"), sawPending)
        assertEquals(listOf("held", "n1", "n2"), out)
        // "held" was already pending -> not double-queued; new ids appended in order.
        assertEquals(listOf("held", "n1", "n2"), s.syncState.audioPendingUpload)
    }

    @Test fun disabledEngineNeverRunsSelectorOrQueues() {
        val s = svc(false)
        var ran = false
        assertTrue(s.scheduleAudioAnalysis(ranked, inputs) { _, _, _ -> ran = true; listOf("x") }.isEmpty())
        assertTrue(!ran)
        assertTrue(s.syncState.audioPendingUpload.isEmpty())
    }

    @Test fun noRankingYetEnqueuesNothing() {
        val s = svc(true)
        var ran = false
        s.scheduleAudioAnalysis(ForYouFeedSnapshot(), inputs) { _, _, _ -> ran = true; listOf("x") }
        assertTrue(!ran)
        assertTrue(s.syncState.audioPendingUpload.isEmpty())
    }

    @Test fun secondRefreshSpendsBudgetOnNewSongsOnly() {
        val s = svc(true)
        s.scheduleAudioAnalysis(ranked, inputs) { _, _, _ -> listOf("a", "b") }
        s.scheduleAudioAnalysis(ranked, inputs) { _, _, pending -> listOf("a", "b", "c").filter { it !in pending } }
        assertEquals(listOf("a", "b", "c"), s.syncState.audioPendingUpload)
    }
}
