package com.levi.pocketdj.playback

import com.levi.pocketdj.playback.sequencer.SequencerHarness
import com.levi.pocketdj.playback.sequencer.Rung
import org.junit.Test
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest

private fun items(vararg ids: String) = ids.map { RunItem(it, "T $it", "A") }

/** The ownership contract every [GameRunPlayer] must honour (fake and sequencer-backed). */
@OptIn(ExperimentalCoroutinesApi::class)
class GameRunPlayerContractTest {

    // ---- fake ------------------------------------------------------------------------------
    @Test fun fake_ownsOnlyWhileItsTagRuns() {
        val p = FakeGameRunPlayer()
        assertFalse(p.ownsRun("puzzle_A"))
        p.playRun(items("a", "b"), "puzzle_A", "Gem Collector")
        assertTrue(p.ownsRun("puzzle_A"))
        assertFalse(p.ownsRun("puzzle_B"))
        p.foreignPlay()
        assertFalse(p.ownsRun("puzzle_A"), "a foreign play steals ownership")
        assertTrue(p.isRunning)
    }

    @Test fun fake_appendSkipStopRefusedWhenNotOwned() {
        val p = FakeGameRunPlayer()
        p.playRun(items("a"), "puzzle_A", "G")
        p.foreignPlay()
        assertFalse(p.appendRun(items("x"), "puzzle_A"))
        assertFalse(p.skipNext("puzzle_A"))
        assertFalse(p.stopRun("puzzle_A"))
        assertTrue(p.appended.isEmpty())
        assertEquals(0, p.skips)
        assertTrue(p.isRunning, "the foreign run keeps sounding")
    }

    // ---- sequencer-backed --------------------------------------------------------------------
    private fun TestHarnessPlayer(h: SequencerHarness, scope: kotlinx.coroutines.CoroutineScope, local: Set<String>, am: Map<String, String> = emptyMap(), previews: Map<String, String> = emptyMap()) =
        SequencerGameRunPlayer(
            h.seq,
            GamePreviewResolver(
                localPlayable = { it in local },
                appleMusicId = { am[it] },
                previewUrl = { previews[it] },
            ),
            scope,
        )

    @Test fun sequencer_playRunTagsTheRunAndOwnsIt() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "c"))
        val p = TestHarnessPlayer(h, backgroundScope, setOf("a", "b", "c"))
        assertNull(p.runningTag)
        p.playRun(items("a", "b", "c"), "puzzle_R1", "Gem Collector")
        h.settle()
        assertTrue(p.ownsRun("puzzle_R1"))
        val st = h.seq.state.value
        assertEquals("puzzle_R1", st.sourceSetlistId)
        assertEquals("game", st.capturedContext?.source)
        assertEquals("Gem Collector", st.capturedContext?.contextName)
        assertEquals("puzzle_R1", st.capturedContext?.contextId)
        assertEquals(0, p.position)
    }

    @Test fun sequencer_appendRowsAreStampedAndOnlyWhenOwned() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "c", "x"))
        val p = TestHarnessPlayer(h, backgroundScope, setOf("a", "b", "c", "x"))
        p.playRun(items("a", "b"), "puzzle_R1", "G")
        h.settle()
        assertTrue(p.appendRun(items("c"), "puzzle_R1"))
        assertEquals(listOf("a", "b", "c"), h.ids)
        assertEquals("puzzle_R1", h.seq.state.value.queue.last().runTag)
        assertFalse(p.appendRun(items("x"), "puzzle_OTHER"), "wrong tag is refused")
        assertEquals(listOf("a", "b", "c"), h.ids)
    }

    @Test fun sequencer_foreignPlayStealsOwnershipAndIsNeverTouched() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "f1", "f2"))
        val p = TestHarnessPlayer(h, backgroundScope, setOf("a", "b", "f1", "f2"))
        p.playRun(items("a", "b"), "puzzle_R1", "G")
        h.settle()
        // Browse plays an album queue over it.
        h.seq.play(listOf(com.levi.pocketdj.playback.sequencer.QueueItem("f1"), com.levi.pocketdj.playback.sequencer.QueueItem("f2")), sourceSetlistId = "set_foreign")
        h.settle()
        assertFalse(p.ownsRun("puzzle_R1"))
        assertTrue(p.isRunning)
        assertFalse(p.skipNext("puzzle_R1"))
        assertFalse(p.stopRun("puzzle_R1"))
        assertFalse(p.appendRun(items("a"), "puzzle_R1"))
        assertEquals(listOf("f1", "f2"), h.ids)
        assertEquals(0, h.index, "the foreign cursor never moved")
    }

    @Test fun sequencer_skipAndStopOwnRun() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "c"))
        val p = TestHarnessPlayer(h, backgroundScope, setOf("a", "b", "c"))
        p.playRun(items("a", "b", "c"), "puzzle_R1", "G")
        h.settle()
        assertTrue(p.skipNext("puzzle_R1"))
        h.settle()
        assertEquals(1, p.position)
        assertTrue(p.stopRun("puzzle_R1"))
        h.settle()
        assertFalse(p.isRunning)
        assertNull(p.runningTag)
    }

    // ---- preview resolution --------------------------------------------------------------------
    @Test fun filterResolvable_dropsSongsWithNoAudio() = runTest {
        val h = SequencerHarness(this, backgroundScope, emptySet())
        val p = TestHarnessPlayer(
            h, backgroundScope, local = setOf("rip"),
            am = mapOf("am_ok" to "111", "am_dead" to "222"),
            previews = mapOf("111" to "https://p/111.m4a"),
        )
        val kept = p.filterResolvable(items("rip", "am_ok", "am_dead", "meta")).map { it.songId }
        assertEquals(listOf("rip", "am_ok"), kept, "unresolvable and metadata-only rows never reach the card stack")
    }

    @Test fun previewRung_onlyClaimsTaggedGameRows_asFallback() = runTest {
        val previews = GamePreviewResolver({ false }, { "9" }, { "https://p/9.m4a" })
        val rung = GamePreviewRowResolver(previews)
        assertEquals(Rung.FALLBACK, rung.rung)
        val ctx = com.levi.pocketdj.playback.sequencer.ResolveContext(PlaybackMode.CLOUD, false, false)
        val plain = com.levi.pocketdj.playback.sequencer.QueueItem("s1")
        assertNull(rung.resolve(plain, ctx), "an ordinary queue keeps its no-preview-in-a-set rule")
        val tagged = plain.copy(runTag = "puzzle_R1")
        val src = rung.resolve(tagged, ctx) as com.levi.pocketdj.playback.sequencer.StreamSource
        assertEquals("https://p/9.m4a", src.action.url)
    }

    @Test fun sequencer_previewOnlyRowPlaysThroughTheLadder() = runTest {
        val rung = GamePreviewRowResolver(GamePreviewResolver({ false }, { "9" }, { "https://p/9.m4a" }))
        val h = SequencerHarness(this, backgroundScope, emptySet(), extra = listOf(rung))
        val p = SequencerGameRunPlayer(h.seq, GamePreviewResolver({ false }, { "9" }, { "https://p/9.m4a" }), backgroundScope)
        p.playRun(items("am_only"), "puzzle_R1", "G")
        h.settle()
        assertEquals(listOf("am_only"), h.port.sounded, "the AM preview started through the ExoPlayer port")
    }
}
