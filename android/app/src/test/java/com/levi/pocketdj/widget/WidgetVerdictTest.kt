package com.levi.pocketdj.widget

import com.levi.pocketdj.data.recs.RecFeedbackStore.Verdict
import com.levi.pocketdj.widget.WidgetCommand.Kind
import java.io.File
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetVerdictTest {
    private var now = 5_000_000L
    private fun queue(): PendingWidgetCommands {
        val f = File.createTempFile("wvq", ".json").also { it.delete(); it.deleteOnExit() }
        return PendingWidgetCommands(f) { now }
    }

    private fun applyAll(cmds: List<WidgetCommand>): List<Triple<String, String, Verdict>> {
        val out = mutableListOf<Triple<String, String, Verdict>>()
        cmds.forEach { WidgetVerdicts.apply(it) { s, sc, v -> out += Triple(s, sc, v) } }
        return out
    }

    @Test fun drainAppliesToTheSnapshotSongNotTheCurrentOne() {
        val q = queue()
        // The user saw song "A" in scope "zone" and tapped 👎, then ⏭ (the app is now on "B").
        q.enqueue(WidgetCommand(Kind.VERDICT_REJECT, songId = "A", scope = "zone"))
        q.enqueue(WidgetCommand(Kind.NEXT))
        now += 60 * 60_000 // an hour later, cold launch
        val drained = q.drain()
        assertEquals(listOf(Kind.VERDICT_REJECT), drained.map { it.kind }) // stale ⏭ gone, verdict kept
        assertEquals(listOf(Triple("A", "zone", Verdict.REJECTED)), applyAll(drained))
    }

    @Test fun thumbsDownThenSkipKeepsTheVerdict() {
        val q = queue()
        q.enqueue(WidgetCommand(Kind.VERDICT_REJECT, songId = "A", scope = "s"))
        q.enqueue(WidgetCommand(Kind.NEXT))
        now += 5_000
        val d = q.drain()
        assertEquals(listOf(Kind.VERDICT_REJECT, Kind.NEXT), d.map { it.kind })
        assertEquals(1, applyAll(d).size)
    }

    @Test fun verdictsNeverExpireAndAcceptMapsToAccepted() {
        val q = queue()
        q.enqueue(WidgetCommand(Kind.VERDICT_ACCEPT, songId = "A", scope = "new"))
        now += 10L * 24 * 3_600_000
        assertEquals(listOf(Triple("A", "new", Verdict.ACCEPTED)), applyAll(q.drain()))
    }

    @Test fun verdictWithoutTargetIsDroppedNotRedirected() {
        val q = queue()
        q.enqueue(WidgetCommand(Kind.VERDICT_ACCEPT, songId = "A")) // no scope
        q.enqueue(WidgetCommand(Kind.VERDICT_REJECT, scope = "zone")) // no song
        q.enqueue(WidgetCommand(Kind.VERDICT_REJECT, songId = "", scope = "zone"))
        assertTrue(q.drain().isEmpty())
        assertFalse(WidgetVerdicts.apply(WidgetCommand(Kind.VERDICT_ACCEPT, songId = "A")) { _, _, _ -> })
        assertFalse(WidgetVerdicts.apply(WidgetCommand(Kind.NEXT, songId = "A", scope = "z")) { _, _, _ -> })
    }

    @Test fun oldQueueFilesWithoutScopeStillDecode() {
        val old = """[{"kind":"FAVORITE","songId":"a","value":"1","atMs":7},{"kind":"VERDICT_REJECT","songId":"a","atMs":8}]"""
        val f = File.createTempFile("wvold", ".json").also { it.deleteOnExit(); it.writeText(old) }
        val d = PendingWidgetCommands(f) { 9 }.drain()
        assertEquals(listOf(Kind.FAVORITE), d.map { it.kind }) // scope-less verdict dropped, favorite intact
        val c = Json { ignoreUnknownKeys = true }.decodeFromString(WidgetCommand.serializer(), """{"kind":"NEXT"}""")
        assertEquals(null, c.scope)
    }

    @Test fun scopeRoundTripsThroughTheQueueFile() {
        val q = queue()
        q.enqueue(WidgetCommand(Kind.VERDICT_ACCEPT, songId = "A", scope = "zone"))
        assertEquals("zone", q.drain().single().scope)
    }

    @Test fun snapshotThumbsShowOnlyWithScope() {
        val base = NowPlayingSnapshot(hasContent = true, songId = "A")
        assertFalse(base.showsFeedback)
        assertTrue(base.copy(recScope = "zone").showsFeedback)
        assertFalse(NowPlayingSnapshot(recScope = "zone").showsFeedback) // nothing playing
    }

    @Test fun optimisticTapTogglesLikeTheStore() {
        val s = NowPlayingSnapshot(hasContent = true, songId = "A", recScope = "zone")
        val up = s.afterVerdictTap(accept = true)
        assertEquals("accepted", up.recVerdict)
        assertEquals("", up.afterVerdictTap(accept = true).recVerdict) // second tap clears
        assertEquals("rejected", up.afterVerdictTap(accept = false).recVerdict) // switch
    }

    @Test fun legacySnapshotJsonWithoutRecKeysRoundTripsByteStable() {
        val text = NowPlayingSnapshotCodec.encode(NowPlayingSnapshot(hasContent = true, songId = "A", title = "T"))
        assertEquals(text, NowPlayingSnapshotCodec.encode(NowPlayingSnapshotCodec.decode(text)))
        assertTrue(text.contains("\"recScope\":\"\""))
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun syncPublishesVerdictOnlyForARecommendationScope() = kotlinx.coroutines.test.runTest {
        val dir = File.createTempFile("wvs", "").let { it.delete(); it.mkdirs(); it.deleteOnExit(); it }
        val store = NowPlayingSnapshotStore(dir)
        val sync = WidgetSync(this, kotlinx.coroutines.flow.emptyFlow(), store, { null }, { })
        val i = WidgetInputs(songId = "A", title = "T", recVerdict = "accepted", recScope = "zone")
        sync.onInputs(i)
        assertEquals("zone", store.read().recScope)
        assertEquals("accepted", store.read().recVerdict)
        sync.onInputs(i.copy(recScope = "")) // no longer a recommendation: no thumbs, no stale verdict
        assertEquals("", store.read().recScope)
        assertEquals("", store.read().recVerdict)
        sync.onInputs(i.copy(songId = null)) // nothing playing
        assertEquals("", store.read().recScope)
    }
}
