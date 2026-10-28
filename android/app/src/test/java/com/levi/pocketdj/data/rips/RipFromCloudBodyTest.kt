package com.levi.pocketdj.data.rips

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RipFromCloudBodyTest {
    @Test fun off_omitsKey() {
        val o = Json.parseToJsonElement(ripBody("s1", false)).jsonObject
        assertEquals("s1", o["songId"]!!.jsonPrimitive.content)
        assertFalse("ripFromCloud" in o)
    }

    @Test fun on_includesTrue() {
        val o = Json.parseToJsonElement(ripBody("s1", true)).jsonObject
        assertTrue(o["ripFromCloud"]!!.jsonPrimitive.boolean)
    }

    @Test fun requestRip_wireBodyFollowsConfig() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            for (flag in listOf(true, false)) {
                server.enqueue(MockResponse().setBody("""{"jobId":"j","phase":"queued"}"""))
                val client = RipServerClient(
                    http = OkHttpClient(),
                    configProvider = {
                        RipServerClient.Config(server.url("/").toString(), "", "dev", ripFromCloud = flag)
                    },
                )
                client.requestRip("song-1")
                val sent = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
                assertEquals(flag, "ripFromCloud" in sent)
            }
        } finally {
            server.shutdown()
        }
    }
}
