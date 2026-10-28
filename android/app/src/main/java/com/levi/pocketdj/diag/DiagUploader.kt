package com.levi.pocketdj.diag

import com.levi.pocketdj.net.SigV4
import java.io.IOException
import okhttp3.MediaType.Companion.toMediaType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** One PUT of a full part body. */
fun interface DiagUploader {
    suspend fun put(key: String, body: ByteArray, creds: DiagCredentialStore.Credentials): UploadOutcome
}

/**
 * SigV4 PUT to the logs bucket over OkHttp. [baseUrl] is read per request (the live
 * `diagLogsBase`) so signed Host == URL host and an account move needs no release.
 */
class OkHttpDiagUploader(
    private val http: OkHttpClient,
    private val baseUrl: () -> String,
    private val clock: () -> Long = System::currentTimeMillis,
    private val region: String = "us-west-2",
) : DiagUploader {
    override suspend fun put(key: String, body: ByteArray, creds: DiagCredentialStore.Credentials): UploadOutcome {
        val base = baseUrl().trimEnd('/')
        val url = base.toHttpUrl()
        val hostHeader = if (url.port == HttpUrl.defaultPort(url.scheme)) url.host else "${url.host}:${url.port}"
        val path = "/$key"
        val signed = SigV4.sign(
            method = "PUT", host = hostHeader, path = path, body = body, region = region, service = "s3",
            creds = SigV4.Creds(creds.accessKeyId, creds.secret), epochMs = clock(),
        )
        val req = Request.Builder()
            .url(url.newBuilder().encodedPath(SigV4.encode(path, true)).build())
            .put(body.toRequestBody("text/plain".toMediaType()))
            .apply { signed.headers.forEach { (k, v) -> header(k, v) } }
            .build()
        return try {
            // Blocking call: the pump runs on an IO dispatcher.
            withContext(Dispatchers.IO) {
                http.newCall(req).execute().use { resp ->
                    if (resp.code in 200..299) UploadOutcome.Ok else UploadOutcome.Http(resp.code)
                }
            }
        } catch (e: IOException) {
            UploadOutcome.Transport(e.javaClass.simpleName)
        }
    }
}
