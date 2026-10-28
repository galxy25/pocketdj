package com.levi.pocketdj.data.games.friends

import kotlinx.serialization.encodeToString
import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MwFLinkTest {
    @Test fun customSchemeHost() {
        val l = MwFLink.parse("pocketdj://mwf/abcd2345")!!
        assertEquals("abcd2345", l.sessionId)
        assertNull(l.guestBase)
        assertEquals("https://jukebox.pocket-dj.com/mwf/abcd2345/state.json", l.stateUrl)
    }

    @Test fun customSchemeTripleSlash() {
        assertEquals("abcd2345", MwFLink.parse("pocketdj:///mwf/abcd2345")?.sessionId)
    }

    @Test fun universalLinkKeepsGuestBase() {
        val l = MwFLink.parse("https://jukebox.pocket-dj.com/mwf/abcd2345/extra/path")!!
        assertEquals("abcd2345", l.sessionId)
        assertEquals("https://jukebox.pocket-dj.com", l.guestBase)
        assertEquals("https://jukebox.pocket-dj.com/mwf/abcd2345/state.json", l.stateUrl)
    }

    @Test fun rejectsBadIdsJukeboxLinksAndOtherHosts() {
        assertNull(MwFLink.parse("pocketdj://mwf/ab1"))               // too short + '1' not base32
        assertNull(MwFLink.parse("pocketdj://mwf/ABCD2345"))          // uppercase
        assertNull(MwFLink.parse("pocketdj://mwf/" + "a".repeat(33))) // too long
        assertNull(MwFLink.parse("https://jukebox.pocket-dj.com/abcd2345/"))     // jukebox link
        assertNull(MwFLink.parse("pocketdj://abcd2345"))
        assertNull(MwFLink.parse("https://evil.example.com/mwf/abcd2345/"))
        assertNull(MwFLink.parse("ftp://jukebox.pocket-dj.com/mwf/abcd2345/"))
        assertNull(MwFLink.parse("https://jukebox.pocket-dj.com/mwf/"))
        assertNull(MwFLink.parse("not a url at all %%"))
    }

    @Test fun idShape() {
        assertTrue(MwFLink.isValidId("abcd"))
        assertTrue(MwFLink.isValidId("a".repeat(32)))
        assertFalse(MwFLink.isValidId("abc"))
        assertFalse(MwFLink.isValidId("abc0"))
    }

    @Test fun stateDecodesLeniently() {
        val st = PdjJson.lenient.decodeFromString(MwFState.serializer(),
            """{"sessionId":"s","future":1,"members":[{"memberId":"a","score":3},{"memberId":"b"}],"you":{"memberId":"a"},"turn":{"deadline":1.5e12}}""")
        assertEquals(3, st.score("a"))
        assertEquals(0, st.score("b"))
        assertEquals(0, st.score(null))
        assertEquals(0, st.score("zzz"))
        assertNull(st.ended)
    }

    @Test fun sessionEntryRoundTripAndMissingFields() {
        val e = MwFSessionEntry(id = "x", memberId = "m", memberKey = "k", leaderKey = "L", joinedAt = 5.0)
        assertTrue(e.isLeader)
        val back = PdjJson.lenient.decodeFromString(MwFSessionEntry.serializer(), PdjJson.lenient.encodeToString(e))
        assertEquals(e, back)
        val sparse = PdjJson.lenient.decodeFromString(MwFSessionEntry.serializer(), """{"id":"y","extra":true}""")
        assertFalse(sparse.isLeader)
    }

    @Test fun joinSecretMintsOnceAndResets() {
        val secret = MwFJoinSecret(InMemoryMwFKeyValue())
        val a = secret.current()
        assertEquals(32, a.length)
        assertTrue(a.all { it in "0123456789abcdef" })
        assertEquals(a, secret.current())
        secret.reset()
        assertTrue(secret.current() != a)
    }
}
