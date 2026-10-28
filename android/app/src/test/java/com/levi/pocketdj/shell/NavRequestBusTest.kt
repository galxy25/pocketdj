package com.levi.pocketdj.shell

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class NavRequestBusTest {
    @Before fun setUp() = NavRequestBus.reset()
    @After fun tearDown() = NavRequestBus.reset()

    @Test
    fun postThenTake_returnsOnce() {
        NavRequestBus.post(ShellRoute.Pocket("p1"))
        assertEquals(ShellRoute.Pocket("p1"), NavRequestBus.signal.value)
        assertEquals(ShellRoute.Pocket("p1"), NavRequestBus.take())
        assertNull(NavRequestBus.take())
        assertNull("signal cleared by take", NavRequestBus.signal.value)
    }

    @Test
    fun postWhilePending_replaces_neverQueues() {
        NavRequestBus.post(ShellRoute.Album("a1"))
        NavRequestBus.post(ShellRoute.Playlist("pl"))
        assertEquals(ShellRoute.Playlist("pl"), NavRequestBus.take())
        assertNull("the superseded route must not surface later", NavRequestBus.take())
    }

    @Test
    fun concurrentConsumers_exactlyOneWins() {
        repeat(50) {
            NavRequestBus.reset()
            NavRequestBus.post(ShellRoute.Setlist("s", autoplay = true))
            val pool = Executors.newFixedThreadPool(8)
            val start = CountDownLatch(1)
            val winners = AtomicInteger()
            repeat(8) {
                pool.submit {
                    start.await()
                    if (NavRequestBus.take() != null) winners.incrementAndGet()
                }
            }
            start.countDown()
            pool.shutdown()
            assertTrue(pool.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(1, winners.get())
        }
    }

    @Test
    fun browseQuery_isTakenAtomically() {
        NavRequestBus.setPendingBrowseQuery("daft punk")
        assertEquals("daft punk", NavRequestBus.takePendingBrowseQuery())
        assertNull(NavRequestBus.takePendingBrowseQuery())
    }

    @Test
    fun routeMessage_setAndClear() {
        NavRequestBus.postMessage("That album isn't in your library.")
        assertEquals("That album isn't in your library.", NavRequestBus.routeMessage.value)
        NavRequestBus.clearMessage()
        assertNull(NavRequestBus.routeMessage.value)
    }
}
