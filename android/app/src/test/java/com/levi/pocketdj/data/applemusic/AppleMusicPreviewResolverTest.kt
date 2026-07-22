package com.levi.pocketdj.data.applemusic

import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Preview URL resolution — dev-token API primary, tokenless iTunes alt (specs/applemusic.md §6.3). */
class AppleMusicPreviewResolverTest {

    private fun resolver(
        server: MockWebServer,
        devToken: String?,
    ) = AppleMusicPreviewResolver(
        http = OkHttpClient(),
        developerTokenProvider = { devToken },
        catalogApiBase = server.url("/api").toString(),
        itunesLookupBase = server.url("/lookup").toString(),
    )

    @Test
    fun resolvesViaDeveloperTokenPreviews() = runTest {
        val server = MockWebServer()
        server.enqueue(
            MockResponse().setBody(
                """{"data":[{"attributes":{"previews":[{"url":"https://a.example/p.m4a"}]}}]}""",
            ),
        )
        server.start()
        try {
            val url = resolver(server, devToken = "devtok").previewUrl("12345")
            assertEquals("https://a.example/p.m4a", url)
            val req = server.takeRequest()
            assertEquals("Bearer devtok", req.getHeader("Authorization"))
            assertEquals("/api/v1/catalog/us/songs/12345", req.path)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun fallsBackToTokenlessItunesWhenNoDevToken() = runTest {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"results":[{"previewUrl":"https://b.example/it.m4a"}]}"""))
        server.start()
        try {
            val url = resolver(server, devToken = null).previewUrl("999")
            assertEquals("https://b.example/it.m4a", url)
            assertEquals("/lookup?id=999", server.takeRequest().path)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun cachesResolvedUrlPerAppleMusicId() = runTest {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"results":[{"previewUrl":"https://c.example/x.m4a"}]}"""))
        server.start()
        try {
            val r = resolver(server, devToken = null)
            assertEquals("https://c.example/x.m4a", r.previewUrl("55"))
            assertEquals("https://c.example/x.m4a", r.previewUrl("55")) // cache hit — no 2nd request
            assertEquals(1, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun blankIdAndFailedLookupReturnNull() = runTest {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(404))
        server.start()
        try {
            val r = resolver(server, devToken = null)
            assertNull(r.previewUrl(""))     // blank id — no network
            assertNull(r.previewUrl("nope"))  // 404 → null (graceful)
        } finally {
            server.shutdown()
        }
    }
}
