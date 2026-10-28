package com.levi.pocketdj.shell

import com.levi.pocketdj.navigation.PocketDjDestination
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ConsumeNavRequestsTest {
    @Before fun setUp() = NavRequestBus.reset()
    @After fun tearDown() = NavRequestBus.reset()

    @Test
    fun stagedPush_landsAfterDelay_despiteSignalClearing() = runTest {
        val pushed = mutableListOf<String>()
        val tabs = mutableListOf<PocketDjDestination>()
        val job = launch {
            consumeNavRequests(
                resolve = { NavCommand(PocketDjDestination.Playlists, ShellRoute.Pocket("p1")) },
                switchTab = { tabs += it },
                push = { pushed += it },
                showMessage = {},
                stagedDelayMs = 450,
                pushTarget = { "pocket/x" },
            )
        }
        runCurrent()
        NavRequestBus.post(ShellRoute.Pocket("p1"))
        runCurrent()
        assertEquals(listOf(PocketDjDestination.Playlists), tabs)
        assertTrue("not pushed before the settle delay", pushed.isEmpty())
        advanceTimeBy(451)
        runCurrent()
        assertEquals(1, pushed.size)
        job.cancel()
    }

    @Test
    fun missMessage_isShownToCompletion() = runTest {
        val shown = mutableListOf<String>()
        var finished = false
        val job = launch {
            consumeNavRequests(
                resolve = { RouteMessage("That album isn't in your library.") },
                switchTab = {},
                push = {},
                showMessage = { shown += it; kotlinx.coroutines.delay(5_000); finished = true },
            )
        }
        runCurrent()
        NavRequestBus.post(ShellRoute.Album("gone"))
        runCurrent()
        assertEquals(1, shown.size)
        advanceTimeBy(5_001)
        runCurrent()
        assertTrue("snackbar coroutine must not be cancelled by signal clearing", finished)
        job.cancel()
    }
}
