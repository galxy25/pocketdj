package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JukeboxGuestStateDecodeTest {
    private fun decode(s: String) = JukeboxGuestState.decode(PdjJson.lenient, s)

    @Test fun emptyObjectDecodesToDefaults() {
        val s = decode("{}")
        assertTrue(s.upNext.isEmpty() && s.played.isEmpty() && s.requests.isEmpty())
        assertNull(s.apiBase); assertNull(s.nowPlaying); assertFalse(s.isEnded)
    }

    @Test fun fullBrokerPayload() {
        val s = decode(
            """{"v":1,"jukeboxId":"exmkrd5a","name":"Fri","updatedAt":1700000000000,"ended":false,
            "timeless":false,"expiresAt":5,"hear":true,
            "nowPlaying":{"title":"A","artist":"B","lengthMs":200000,"positionMs":1500,"streamUrl":"https://x/y.mp3"},
            "upNext":[{"title":"C","artist":"D"}],"apiBase":"https://api.test",
            "played":[{"title":"E","artist":"F","endedAt":12.5}],
            "requests":[{"id":"rq_1","title":"G","artist":"H","status":"queued"}]}""",
        )
        assertEquals("Fri", s.name)
        assertEquals(1700000000000.0, s.updatedAt!!, 0.0)
        assertEquals(1500L, s.nowPlaying!!.positionMs)
        assertTrue(s.canTuneIn)
        assertEquals("C", s.upNext.single().title)
        assertEquals("https://api.test", s.apiBase)
        assertEquals(12.5, s.played.single().endedAt!!, 0.0)
        assertEquals("queued", s.requests.single().status)
    }

    @Test fun unknownKeysIgnored() {
        val s = decode("""{"name":"X","futureField":{"a":1},"nowPlaying":{"title":"T","extra":1}}""")
        assertEquals("X", s.name); assertEquals("T", s.nowPlaying!!.title)
    }

    @Test fun nullAndMalformedArraysBecomeEmpty() {
        val s = decode("""{"upNext":null,"played":"nope","requests":[{"id":"r1"},7,"x"]}""")
        assertTrue(s.upNext.isEmpty()); assertTrue(s.played.isEmpty())
        assertEquals(listOf("r1"), s.requests.map { it.id })
    }

    @Test fun apiBaseAbsent() = assertNull(decode("""{"name":"n"}""").apiBase)

    @Test fun endedFlag() = assertTrue(decode("""{"ended":true}""").isEnded)

    @Test fun tuneInRequiresHearAndHttps() {
        assertFalse(decode("""{"hear":false,"nowPlaying":{"streamUrl":"https://x/a.mp3"}}""").canTuneIn)
        assertFalse(decode("""{"hear":true,"nowPlaying":{"streamUrl":"http://x/a.mp3"}}""").canTuneIn)
        assertFalse(decode("""{"hear":true,"nowPlaying":{"title":"t"}}""").canTuneIn)
        assertTrue(decode("""{"hear":true,"nowPlaying":{"streamUrl":"https://x/a.mp3"}}""").canTuneIn)
    }

    @Test fun mineByClientIdIdOrKey() {
        val s = JukeboxGuestState()
        val byClient = JukeboxGuestState.GuestRequest("r1", "T", "A", "pending", clientId = "me")
        val byId = JukeboxGuestState.GuestRequest("r2", "T2", "A2", "pending")
        val byKey = JukeboxGuestState.GuestRequest("r3", " Song ", "ARTIST", "queued")
        val other = JukeboxGuestState.GuestRequest("r4", "Z", "Z", "pending")
        val keys = setOf(JukeboxGuestState.requestKey("song", "artist"))
        assertTrue(s.isMine(byClient, "me", emptySet(), emptySet()))
        assertTrue(s.isMine(byId, "me", setOf("r2"), emptySet()))
        assertTrue(s.isMine(byKey, "me", emptySet(), keys))
        assertFalse(s.isMine(other, "me", setOf("r2"), keys))
        assertFalse(s.isMine(JukeboxGuestState.GuestRequest("r5", clientId = "someone"), "me", emptySet(), emptySet()))
    }
}
