package com.levi.pocketdj.diag

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagUploaderTest {
    private val creds = DiagCredentialStore.Credentials("AKIAAAAAAAAAAAAAAAAA", "secret")

    private fun withServer(block: (MockWebServer, DiagUploader) -> Unit) {
        val s = MockWebServer(); s.start()
        try {
            block(s, OkHttpDiagUploader(OkHttpClient(), { s.url("/").toString() }, { 1369353600000L }))
        } finally { s.shutdown() }
    }

    @Test fun signedPutToKeyPath() = withServer { s, up ->
        s.enqueue(MockResponse().setResponseCode(200))
        val out = runBlocking { up.put("diag/android-abcd1234/2026-10-27T01-02-03Z-b1.log", "hello\n".toByteArray(), creds) }
        assertEquals(UploadOutcome.Ok, out)
        val req = s.takeRequest()
        assertEquals("PUT", req.method)
        assertEquals("/diag/android-abcd1234/2026-10-27T01-02-03Z-b1.log", req.path)
        assertEquals("hello\n", req.body.readUtf8())
        assertEquals("20130524T000000Z", req.getHeader("x-amz-date"))
        val auth = req.getHeader("Authorization")!!
        assertTrue(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIAAAAAAAAAAAAAAAAA/20130524/us-west-2/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="))
        assertEquals(com.levi.pocketdj.net.SigV4.sha256Hex("hello\n".toByteArray()), req.getHeader("x-amz-content-sha256"))
    }

    @Test fun httpErrorClassified() = withServer { s, up ->
        s.enqueue(MockResponse().setResponseCode(403))
        assertEquals(UploadOutcome.Http(403), runBlocking { up.put("diag/x.log", ByteArray(1), creds) })
    }

    @Test fun transportErrorClassified() = withServer { s, up ->
        s.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        val out = runBlocking { up.put("diag/x.log", ByteArray(1), creds) }
        assertTrue(out is UploadOutcome.Transport)
    }

    @Test fun credentialStoreRoundTrip() {
        val st = DiagCredentialStore(com.levi.pocketdj.data.credentials.InMemorySecretStore())
        assertEquals(null, st.load())
        st.save("AKIAAAAAAAAAAAAAAAAA", "s"); assertEquals("s", st.load()?.secret)
        st.clear(); assertEquals(null, st.load())
    }
}
