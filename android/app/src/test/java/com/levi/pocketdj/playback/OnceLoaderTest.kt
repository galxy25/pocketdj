package com.levi.pocketdj.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

/** The Apple Music native-lib gate: load once, cache a failure, never retry dlopen. */
class OnceLoaderTest {
    @Test fun successLoadsExactlyOnce() {
        val calls = AtomicInteger()
        val l = OnceLoader { calls.incrementAndGet() }
        repeat(5) { l.ensure() }
        assertEquals(1, calls.get())
    }

    @Test fun failureIsCachedAndRethrownWithoutRetry() {
        val calls = AtomicInteger()
        val boom = UnsatisfiedLinkError("dlopen failed: library \"libappleMusicSDK.so\" not found")
        val l = OnceLoader { calls.incrementAndGet(); throw boom }
        repeat(3) {
            try {
                l.ensure()
                fail("expected the cached load failure")
            } catch (t: Throwable) {
                assertSame(boom, t)
            }
        }
        assertEquals(1, calls.get())
    }

    @Test fun concurrentFirstUseLoadsOnce() {
        val calls = AtomicInteger()
        val l = OnceLoader { calls.incrementAndGet(); Thread.sleep(20) }
        val start = CountDownLatch(1)
        val threads = List(8) { Thread { start.await(); l.ensure() }.apply { start() } }
        start.countDown()
        threads.forEach { it.join() }
        assertEquals(1, calls.get())
    }
}
