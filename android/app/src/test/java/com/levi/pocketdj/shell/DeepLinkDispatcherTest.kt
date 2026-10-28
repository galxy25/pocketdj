package com.levi.pocketdj.shell

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DeepLinkDispatcherTest {
    private class FakeGate(complete: Boolean) : OnboardingGate {
        private val done = CompletableDeferred<Unit>().also { if (complete) it.complete(Unit) }
        override val isComplete get() = done.isCompleted
        override suspend fun waitUntilComplete() = done.await()
        fun finish() { done.complete(Unit) }
    }

    private val routes = mutableListOf<ShellRoute>()
    private val messages = mutableListOf<String>()
    private val seams = DeepLinkSeams()

    private fun TestScope.dispatcher(gate: OnboardingGate) =
        DeepLinkDispatcher(backgroundScope, gate, seams, postRoute = { routes += it }, postMessage = { messages += it })

    private val join = DeepLink.JukeboxJoin("exmkrd5a", "https://jukebox.pocket-dj.com")

    @Test fun parkedWhileIncomplete_drainedOnceOnCompletion() = runTest {
        val gate = FakeGate(false)
        val joined = mutableListOf<String>()
        seams.joinJukebox = { id, _ -> joined += id }
        val d = dispatcher(gate)
        assertTrue(d.handle(join))
        runCurrent()
        assertTrue(joined.isEmpty())
        gate.finish(); runCurrent()
        assertEquals(listOf("exmkrd5a"), joined)
        runCurrent()
        assertEquals(1, joined.size)
    }

    @Test fun duplicateTapsDuringOnboardingRunOnce() = runTest {
        val gate = FakeGate(false)
        val joined = mutableListOf<String>()
        seams.joinJukebox = { id, _ -> joined += id }
        val d = dispatcher(gate)
        repeat(3) { d.handle(join) }
        gate.finish(); runCurrent()
        assertEquals(1, joined.size)
    }

    @Test fun jukeboxWhenComplete_runsImmediately_defaultPostsRoute() = runTest {
        val d = dispatcher(FakeGate(true))
        assertTrue(d.handle(join))
        assertEquals(listOf<ShellRoute>(ShellRoute.JukeboxJoin("exmkrd5a")), routes)
    }

    @Test fun mwfParkedForGamesConsumer() = runTest {
        val d = dispatcher(FakeGate(false))
        val mwf = DeepLink.Mwf("abcd2345", null)
        d.handle(mwf)
        assertNull(d.pendingMwf.value)
        (d.let { }).also { }
        val gate = FakeGate(true)
        val d2 = dispatcher(gate)
        d2.handle(mwf)
        assertEquals(mwf, d2.pendingMwf.value)
        assertEquals(mwf, d2.takePendingMwf())
        assertNull(d2.takePendingMwf())
    }

    @Test fun mwfConsumerSeamReceivesLink() = runTest {
        val got = mutableListOf<DeepLink.Mwf>()
        seams.mwf = { got += it }
        val d = dispatcher(FakeGate(true))
        d.handle(DeepLink.Mwf("abcd2345", null))
        assertEquals(1, got.size)
        assertNull(d.pendingMwf.value)
    }

    @Test fun playRunsAfterOnboardingWithShuffle() = runTest {
        val gate = FakeGate(false)
        val plays = mutableListOf<Triple<PlayKind, String, Boolean>>()
        seams.playItem = { k, id, sh -> plays += Triple(k, id, sh); null }
        val d = dispatcher(gate)
        d.handle(DeepLinkParser.parse("pocketdj://play/playlist/p1?shuffle=1"))
        runCurrent()
        assertTrue(plays.isEmpty())
        gate.finish(); runCurrent()
        assertEquals(listOf(Triple(PlayKind.Playlist, "p1", true)), plays)
    }

    @Test fun playFailureMessageIsSurfaced() = runTest {
        seams.playItem = { _, _, _ -> "That playlist no longer exists." }
        dispatcher(FakeGate(true)).handle(DeepLink.Play(PlayKind.Playlist, "gone", false))
        assertEquals(listOf("That playlist no longer exists."), messages)
    }

    @Test fun playDefaultOpensItem() = runTest {
        val d = dispatcher(FakeGate(true))
        d.handle(DeepLink.Play(PlayKind.Setlist, "s", false))
        assertEquals(listOf<ShellRoute>(ShellRoute.Setlist("s", autoplay = true)), routes)
    }

    @Test fun collectionFile_defaultIsComingSoonNotCrash() = runTest {
        dispatcher(FakeGate(true)).handle(DeepLink.CollectionFile("content://x/1"))
        assertEquals(listOf("Import coming soon"), messages)
    }

    @Test fun collectionFile_seamReceivesUri() = runTest {
        val uris = mutableListOf<String>()
        seams.importCollection = { uris += it }
        dispatcher(FakeGate(true)).handle(DeepLink.CollectionFile("content://x/1"))
        assertEquals(listOf("content://x/1"), uris)
        assertTrue(messages.isEmpty())
    }

    @Test fun noneAndDiagKeyAreNotConsumed() = runTest {
        val d = dispatcher(FakeGate(true))
        assertFalse(d.handle(DeepLink.None))
        assertFalse(d.handle(DeepLink.DiagKey("content://x/2")))
        assertTrue(routes.isEmpty() && messages.isEmpty())
    }

    @Test fun navigateRoutes() = runTest {
        dispatcher(FakeGate(true)).handle(DeepLinkParser.parse("pocketdj://album/a1"))
        assertEquals(listOf<ShellRoute>(ShellRoute.Album("a1")), routes)
    }
}
