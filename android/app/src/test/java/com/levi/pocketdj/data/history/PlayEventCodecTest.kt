package com.levi.pocketdj.data.history

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.PlayContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayEventCodecTest {
    private val json = PdjJson.lenient

    @Test fun oldDocumentWithoutNewKeysDecodesUnchanged() {
        val old = """{"schemaVersion":1,"installId":"i1","events":[{"id":"a","songId":"s","playedAt":1.0,"source":"album","contextId":"c","contextName":"n","title":"t","artist":"x"}]}"""
        val doc = json.decodeFromString<PlayHistoryDocument>(old)
        val e = doc.events.single()
        assertNull(e.wasSkipped); assertNull(e.listenedFraction); assertNull(e.tzOffsetMin)
        assertNull(e.originInstallId); assertNull(e.originCollectionId)
        assertEquals(PlayOutcome.UNKNOWN, e.outcome)
    }

    @Test fun nullKeysOmittedOnEncode() {
        val s = json.encodeToString(PlayEvent.serializer(), PlayEvent("a", "s", 1.0))
        for (k in listOf("wasSkipped", "listenedFraction", "tzOffsetMin", "originInstallId", "originCollectionId", "carPlay", "listeningContext")) {
            assertFalse(k, s.contains(k))
        }
    }

    @Test fun additiveOptionalRoundTrip() {
        val e = PlayEvent("a", "s", 1.0, wasSkipped = true, listenedFraction = 0.25, tzOffsetMin = -420,
            originInstallId = "i", originCollectionId = "pl")
        val back = json.decodeFromString(PlayEvent.serializer(), json.encodeToString(PlayEvent.serializer(), e))
        assertEquals(e, back)
        assertTrue(json.encodeToString(PlayEvent.serializer(), e).contains("\"wasSkipped\":true"))
    }

    @Test fun outcomeDerivation() {
        assertEquals(PlayOutcome.SKIPPED, PlayEvent("a", "s", 1.0, wasSkipped = true, listenedFraction = 0.9).outcome)
        assertEquals(PlayOutcome.COMPLETED, PlayEvent("a", "s", 1.0, listenedFraction = 0.5).outcome)
        assertEquals(PlayOutcome.PARTIAL, PlayEvent("a", "s", 1.0, listenedFraction = 0.49).outcome)
        assertEquals(PlayOutcome.UNKNOWN, PlayEvent("a", "s", 1.0).outcome)
    }

    @Test fun gameAndMixTokens() {
        val ev = json.decodeFromString(PlayEvent.serializer(), """{"id":"a","songId":"s","playedAt":1,"source":"game","contextName":"Gem Collector"}""")
        assertEquals(PlaySource.GAME, ev.source)
        assertEquals("Game", ev.source.label)
        assertEquals("Mix", PlaySource.fromToken(PlayContext.SOURCE_MIX).label)
        val ctx = PlayContext.game("run1", "Gem Collector")
        assertEquals("game", ctx.source)
        assertEquals("Gem Collector", ctx.contextName)
        assertEquals("run1", ctx.runTag)
    }

    @Test fun unknownFutureSourceCoercesToBrowser() {
        val ev = json.decodeFromString(PlayEvent.serializer(), """{"id":"a","songId":"s","playedAt":1,"source":"hologram"}""")
        assertEquals(PlaySource.BROWSER, ev.source)
    }
}
