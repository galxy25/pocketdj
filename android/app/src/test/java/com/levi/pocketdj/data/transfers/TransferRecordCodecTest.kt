package com.levi.pocketdj.data.transfers

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferRecordCodecTest {
    private val json = PdjJson.lenient

    /** Shape written by iOS `TransferDoc` (JSONEncoder, Data as base64, no workId). */
    private val iosFixture = """
        {"schemaVersion":1,"tasks":[{
          "taskIdentifier":42,"songId":"sng_1","kind":"burn",
          "audioFileName":"A-B-sng_1.mp3","sidecarFileName":"A-B-sng_1.txt","sidecarText":"BPM: 120\n",
          "wasAppStorage":false,"burnFolderBookmark":"AAECAw==","expectedBytes":123456,
          "manifestKey":"rips/sng_1.mp3","source":"analog","bpm":121.5,"musicalKey":"A minor","camelot":"8A",
          "durationMs":200000,"startMs":60000,"rippedAt":771234567.5,"title":"T","artist":"A","createdAt":771234999.25
        },{"taskIdentifier":7,"songId":"sng_2","kind":"download","audioFileName":"x.mp3","sidecarFileName":"",
          "sidecarText":"","wasAppStorage":true,"manifestKey":"k","source":"digital","title":"U","artist":"B","createdAt":1}]}
    """.trimIndent()

    @Test fun iosTransferDocFixtureDecodes() {
        val doc = json.decodeFromString(TransferDoc.serializer(), iosFixture)
        assertEquals(2, doc.tasks.size)
        val a = doc.tasks[0]
        assertEquals(42, a.taskIdentifier)
        assertEquals(TransferKind.BURN, a.kind)
        assertFalse(a.wasAppStorage)
        assertEquals("AAECAw==", a.burnFolderBookmark)
        assertEquals(123456L, a.expectedBytes)
        assertEquals(60000L, a.startMs)
        assertEquals(121.5, a.bpm!!, 0.0)
        assertNull(a.workId)
        assertEquals(TransferKind.DOWNLOAD, doc.tasks[1].kind)
        assertNull(doc.tasks[1].bpm)
    }

    @Test fun workIdIsAdditiveAndRoundTrips() {
        val doc = TransferDoc(tasks = listOf(rec("s1").copy(workId = "11111111-1111-1111-1111-111111111111")))
        val text = json.encodeToString(TransferDoc.serializer(), doc)
        assertTrue(text.contains("\"workId\""))
        assertTrue(text.contains("\"kind\":\"burn\""))
        assertEquals(doc, json.decodeFromString(TransferDoc.serializer(), text))
    }

    @Test fun unknownKeysAndFutureFieldsAreIgnored() {
        val doc = json.decodeFromString(
            TransferDoc.serializer(),
            """{"schemaVersion":2,"tasks":[{"songId":"s","audioFileName":"a.mp3","futureField":{"x":1}}],"extra":true}""",
        )
        assertEquals("s", doc.tasks.single().songId)
    }

    @Test fun stableTaskIdIsDeterministicNonNegative() {
        assertEquals(stableTaskId("sng_1"), stableTaskId("sng_1"))
        assertTrue(stableTaskId("zzzzzzzzzzzzzzzzzzzzzzzzzz") >= 0)
    }
}
