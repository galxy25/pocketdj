package com.levi.pocketdj.data.reset

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingCloudErasureTest {
    @Test fun tombstone_survivesUntilTheServerConfirms() = runBlocking {
        val store = InMemorySecretStore()
        val t = PendingCloudErasure(store)
        t.save("ABC", "s3cret")
        assertEquals(PendingCloudErasure.Target("abc", "s3cret"), t.load())

        // Offline / 5xx: the delete throws -> tombstone kept for the next launch.
        assertFalse(t.retry { _, _ -> throw java.io.IOException("offline") })
        assertEquals("abc", PendingCloudErasure(store).load()?.profileId)

        // Next launch succeeds with the OLD credential -> cleared.
        var seen: Pair<String, String>? = null
        assertTrue(t.retry { id, sec -> seen = id to sec; true })
        assertEquals("abc" to "s3cret", seen)
        assertNull(t.load())
    }

    @Test fun nothingToDo_withoutATombstone() = runBlocking {
        assertFalse(PendingCloudErasure(InMemorySecretStore()).retry { _, _ -> error("must not be called") })
    }

    @Test fun emptyCredential_isNotStored() {
        val t = PendingCloudErasure(InMemorySecretStore())
        t.save("abc", "")
        assertNull(t.load())
    }
}
