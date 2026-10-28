package com.levi.pocketdj.data.jukebox

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class JoinedSessionsStoreTest {
    private class MemStorage(var raw: String? = null) : JoinedSessionsStorage {
        var writes = 0
        override suspend fun read() = raw
        override suspend fun write(json: String) { raw = json; writes++ }
    }

    private val base = "https://jukebox.pocket-dj.com"
    private fun link(id: String, b: String? = null) = JukeboxLink(id, b)

    private fun TestScope.store(storage: MemStorage) = JoinedSessionsStore(storage, this)

    @Test fun addIsIdempotentAndMovesToTop() = runTest {
        val st = store(MemStorage())
        st.addJoined(link("aaaa")); st.addJoined(link("bbbb")); st.addJoined(link("cccc"))
        st.addJoined(link("aaaa"))
        assertEquals(listOf("aaaa", "cccc", "bbbb"), st.sessions.value.map { it.id })
    }

    @Test fun readdKeepsKnownNameAndOrigin() = runTest {
        val st = store(MemStorage())
        st.addJoined(link("aaaa", base)); st.updateName("aaaa", "Friday")
        st.addJoined(link("aaaa", null))
        val e = st.sessions.value.single()
        assertEquals("Friday", e.name); assertEquals(base, e.guestBase)
    }

    @Test fun removeDropsEntryAndPersists() = runTest {
        val storage = MemStorage()
        val st = store(storage)
        st.addJoined(link("aaaa")); st.addJoined(link("bbbb"))
        st.remove("aaaa"); advanceUntilIdle()
        assertEquals(listOf("bbbb"), st.sessions.value.map { it.id })
        assertFalse(storage.raw!!.contains("aaaa"))
        assertFalse(st.contains("aaaa")); assertTrue(st.contains("bbbb"))
    }

    @Test fun updateNameIgnoresEmptyBlankNullAndUnchanged() = runTest {
        val storage = MemStorage()
        val st = store(storage)
        st.addJoined(link("aaaa")); advanceUntilIdle()
        val writes = storage.writes
        st.updateName("aaaa", ""); st.updateName("aaaa", "   "); st.updateName("aaaa", null)
        advanceUntilIdle()
        assertEquals(null, st.sessions.value.single().name)
        assertEquals(writes, storage.writes)
        st.updateName("aaaa", " Party "); advanceUntilIdle()
        assertEquals("Party", st.sessions.value.single().name)
        val w2 = storage.writes
        st.updateName("aaaa", "Party"); advanceUntilIdle()
        assertEquals(w2, storage.writes)
        st.updateName("zzzz", "Nope") // unknown id: no entry, no crash
        assertEquals(1, st.sessions.value.size)
    }

    @Test fun corruptJsonLoadsAsEmpty() = runTest {
        val st = store(MemStorage("{not json ["))
        st.load()
        assertTrue(st.sessions.value.isEmpty())
    }

    @Test fun roundTripsThroughStorage() = runTest {
        val storage = MemStorage()
        val a = store(storage)
        a.addJoined(link("aaaa", base)); a.updateName("aaaa", "N"); a.addJoined(link("bbbb"))
        advanceUntilIdle()
        val b = store(storage); b.load()
        assertEquals(a.sessions.value, b.sessions.value)
    }

    @Test fun iosShapedJsonLoads() = runTest {
        val st = store(MemStorage("""[{"id":"exmkrd5a","name":"Fri","guestBase":"$base"},{"id":"bbbb"}]"""))
        st.load()
        assertEquals(listOf("exmkrd5a", "bbbb"), st.sessions.value.map { it.id })
        assertEquals(base, st.sessions.value[0].guestBase)
        assertEquals(null, st.sessions.value[1].name)
    }

    @Test fun addBeforeLoadStaysOnTop() = runTest {
        val st = store(MemStorage("""[{"id":"old1"},{"id":"aaaa"}]"""))
        st.addJoined(link("aaaa"))
        st.load()
        assertEquals(listOf("aaaa", "old1"), st.sessions.value.map { it.id })
    }

    @Test fun encodedListIsAPlainArrayOfIdNameGuestBase() = runTest {
        val st = store(MemStorage())
        assertEquals("""[{"id":"q","name":"n","guestBase":"g"}]""", st.encode(listOf(JoinedSession("q", "n", "g"))))
    }
}
