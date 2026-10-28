package com.levi.pocketdj.assistant

import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.shell.DeepLink
import com.levi.pocketdj.shell.DeepLinkParser
import com.levi.pocketdj.shell.PlayKind
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ShortcutsPublisherTest {
    private fun c(kind: PlayKind, id: String, name: String, at: Double?) = ShortcutCandidate(kind, id, name, at)

    @Test
    fun ranksByLastPlayedAt_capsAndSkipsNeverPlayed() {
        val specs = ShortcutRanking.select(
            listOf(
                c(PlayKind.Playlist, "a", "A", 10.0),
                c(PlayKind.Pocket, "b", "B", 30.0),
                c(PlayKind.Playlist, "c", "C", 20.0),
                c(PlayKind.Pocket, "d", "D", null),
                c(PlayKind.Playlist, "e", "E", 5.0),
            ),
            cap = 3,
        )
        assertEquals(listOf("b", "c", "a"), specs.map { it.id.substringAfterLast('_') })
        assertEquals(listOf(0, 1, 2), specs.map { it.rank })
        assertEquals(emptyList<ShortcutSpec>(), ShortcutRanking.select(listOf(c(PlayKind.Pocket, "b", "B", 1.0)), cap = 0))
    }

    @Test
    fun neverPublishesTheReservedNowPlayingScratchSet() {
        val specs = ShortcutRanking.select(
            listOf(
                c(PlayKind.Playlist, NOW_PLAYING_PLAYLIST_ID, "Now Playing", 999.0),
                c(PlayKind.Playlist, NOW_PLAYING_SETLIST_ID, "Now Playing", 998.0),
                c(PlayKind.Pocket, "real", "Real", 1.0),
            ),
            cap = 5,
        )
        assertEquals(1, specs.size)
        assertTrue(specs.single().uri.endsWith("/real"))
    }

    @Test
    fun deepLink_roundTripsThroughTheParser_andLabelIsCapped() {
        val spec = ShortcutRanking.select(
            listOf(c(PlayKind.Pocket, "pkt 1/é", "x".repeat(60), 1.0)), cap = 1,
        ).single()
        assertEquals(ShortcutRanking.MAX_LABEL, spec.label.length)
        val link = DeepLinkParser.parse(spec.uri) as DeepLink.Play
        assertEquals(PlayKind.Pocket, link.kind)
        assertEquals("pkt 1/é", link.id)
    }

    private class Sink : ShortcutSink {
        val published = mutableListOf<List<ShortcutSpec>>()
        override suspend fun publish(shortcuts: List<ShortcutSpec>) { published += shortcuts }
    }

    @Test
    fun burstsCoalesce_withinTheDebounce_andLatestWins() = runTest {
        val src = MutableStateFlow(listOf(c(PlayKind.Pocket, "a", "A", 1.0)))
        val sink = Sink()
        val job = ShortcutsPublisher(TestScope(testScheduler), src, sink, cap = { 4 }, debounceMs = 1_000L).start()
        runCurrent()
        assertTrue(sink.published.isEmpty())
        advanceTimeBy(500)
        src.value = listOf(c(PlayKind.Pocket, "a", "A", 1.0), c(PlayKind.Pocket, "b", "B", 2.0))
        advanceTimeBy(500)
        src.value = listOf(c(PlayKind.Pocket, "a", "A", 1.0), c(PlayKind.Pocket, "b", "B", 2.0), c(PlayKind.Playlist, "c", "C", 3.0))
        advanceTimeBy(999)
        assertTrue("still inside the debounce window", sink.published.isEmpty())
        advanceTimeBy(2)
        runCurrent()
        assertEquals(1, sink.published.size)
        assertEquals(3, sink.published.single().size)
        assertEquals("c", sink.published.single().first().id.substringAfterLast('_'))
        job.cancel()
    }

    @Test
    fun unchangedSelection_isNotRepublished() = runTest {
        val src = MutableStateFlow(listOf(c(PlayKind.Pocket, "a", "A", 1.0)))
        val sink = Sink()
        val job = ShortcutsPublisher(TestScope(testScheduler), src, sink, cap = { 4 }, debounceMs = 1_000L).start()
        advanceTimeBy(1_001); runCurrent()
        assertEquals(1, sink.published.size)
        // A never-played pocket changes the source but not the selection.
        src.value = src.value + c(PlayKind.Pocket, "z", "Z", null)
        advanceTimeBy(1_001); runCurrent()
        assertEquals(1, sink.published.size)
        // Replaying "a" later changes nothing visible either; a NEW played pocket does.
        src.value = src.value + c(PlayKind.Pocket, "n", "N", 50.0)
        advanceTimeBy(1_001); runCurrent()
        assertEquals(2, sink.published.size)
        assertFalse(sink.published.last().any { it.id.endsWith("_z") })
        job.cancel()
    }
}
