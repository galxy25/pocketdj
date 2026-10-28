package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.applemusic.AppleMusicResolution
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RecognitionAddControllerTest {
    private class FakePort(
        var addOk: Boolean = true,
        var start: () -> RipStart = { RipStart.REQUESTED },
    ) : AppleMusicRecognitionPort {
        val ripCalls = mutableListOf<List<String>>()
        var adds = 0
        override val available = true
        override suspend fun canContribute() = true
        override val canAdd = true
        override suspend fun resolve(storeId: String?, title: String?, artist: String?): AppleMusicResolution? = null
        override suspend fun addSongToLibrary(storeId: String): Boolean { adds++; return addOk }
        override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String): RipStart {
            ripCalls += listOf(songId, title, artist, storeId)
            return start()
        }
    }

    @Test fun addThenRipAndBurnRegistersTheBurnIntentForTheBurnId() = runTest {
        val port = FakePort()
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("123", "T", "A", null)
        assertEquals(listOf(listOf("amrec_123", "T", "A", "123")), port.ripCalls)
        val s = c.states.value.getValue("123")
        assertTrue(s.added); assertEquals("amrec_123", s.burnSongId); assertTrue(!s.adding); assertNull(s.burnError)
    }

    @Test fun catalogIdWinsOverAmrecId() = runTest {
        val port = FakePort()
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("123", "T", "A", "am:123")
        assertEquals("am:123", port.ripCalls.single().first())
    }

    @Test fun noRipServerSurfacesAnErrorUnderAdded() = runTest {
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), FakePort(start = { RipStart.NO_SERVER }))
        c.add("1", "T", "A", null)
        val s = c.states.value.getValue("1")
        assertTrue(s.added)
        assertTrue(s.burnError!!.contains("No rip server"))
    }

    @Test fun ripRequestFailureIsSurfacedNotSwallowed() = runTest {
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), FakePort(start = { error("boom") }))
        c.add("1", "T", "A", null)
        assertEquals("boom", c.states.value.getValue("1").burnError)
    }

    @Test fun rejectedAddReportsAndAllowsRetry() = runTest {
        val port = FakePort(addOk = false)
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("1", "T", "A", null)
        assertEquals("Couldn’t add to Apple Music", c.states.value.getValue("1").addError)
        assertTrue(port.ripCalls.isEmpty())
        port.addOk = true
        c.add("1", "T", "A", null)
        assertEquals(2, port.adds)
    }

    @Test fun addedLatchPreventsDuplicateAdd() = runTest {
        val port = FakePort()
        val c = RecognitionAddController(TestScope(UnconfinedTestDispatcher(testScheduler)), port)
        c.add("1", "T", "A", null)
        assertNull(c.add("1", "T", "A", null))
        assertEquals(1, port.adds)
    }

    @Test fun workRunsOnTheControllerScopeNotTheCaller() = runTest {
        val gate = CompletableDeferred<RipStart>()
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val port = FakePort(start = { error("unused") })
        val c = RecognitionAddController(scope, object : AppleMusicRecognitionPort by port {
            override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String) = gate.await()
        })
        c.add("1", "T", "A", null) // caller (a dismissed sheet) is gone; the job lives on the app scope
        assertTrue(c.states.value.getValue("1").added)
        gate.complete(RipStart.REQUESTED)
        assertNull(c.states.value.getValue("1").burnError)
    }
}
