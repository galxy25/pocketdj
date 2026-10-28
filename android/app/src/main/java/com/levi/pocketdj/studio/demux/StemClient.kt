package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.stems.StemJob
import com.levi.pocketdj.data.stems.StemPhase
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody

/**
 * Demuxer stem client for CUSTOM (uploaded) audio: STREAM the local file to the rip server's
 * `/stemify-custom?id=&ext=`, then poll `/jobs/<id>` to a terminal phase (iOS `RipsStore.stemifyCustom`).
 * The catalog path (`/stemify` + manifest keys) lives in RipServerClient/RipJobTracker (SVC-11).
 *
 * Deliberately NOT behind the studio-id fence: the fence stops /stemify's rip chain from live-searching
 * a garbage title; here the audio is UPLOADED, so studio ids are exactly the intended clients. Only ids
 * matching [DemuxSource.isCustomStemId] reach the network. Returns name -> absolute stem URL, or null on
 * any failure (no server / upload rejected / job error / ineligible / timeout).
 */
class DemuxStemClient(
    http: OkHttpClient,
    private val configProvider: suspend () -> RipServerClient.Config,
    /** Rips public base; stem keys from the job are appended to it. */
    private val ripsBase: () -> String,
    private val json: Json = PdjJson.lenient,
    private val pollMs: Long = 3_000,
    private val maxWaitMs: Long = 4L * 60 * 60 * 1000,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val uploadClient: OkHttpClient = http.newBuilder().callTimeout(0, TimeUnit.MILLISECONDS).writeTimeout(5, TimeUnit.MINUTES).build()
    private val pollClient: OkHttpClient = http.newBuilder().callTimeout(15, TimeUnit.SECONDS).build()

    suspend fun stemifyCustom(id: String, file: File): Map<String, String>? {
        if (!DemuxSource.isCustomStemId(id) || !file.isFile) return null
        val config = configProvider()
        if (!config.configured) return null
        val base = config.normalizedBase.toHttpUrlOrNull() ?: return null
        val upload = base.newBuilder().addPathSegment("stemify-custom")
            .addQueryParameter("id", id).addQueryParameter("ext", file.extension.lowercase()).build()
        val view = try {
            val req = auth(config, Request.Builder().url(upload))
                .post(file.asRequestBody("application/octet-stream".toMediaType())).build()
            call(uploadClient, req) ?: return null
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return null }
        terminal(view)?.let { return it.getOrNull() }
        val jobId = view.jobId ?: return null
        val deadline = nowMs() + maxWaitMs
        while (nowMs() < deadline) {
            sleep(pollMs)
            val v = try {
                val req = auth(config, Request.Builder().url(base.newBuilder().addPathSegment("jobs").addPathSegment(jobId).build())).get().build()
                call(pollClient, req)
            } catch (e: CancellationException) { throw e } catch (_: Exception) { null } ?: continue
            terminal(v)?.let { return it.getOrNull() }
        }
        return null
    }

    /** ready+stems -> Success(urls); ready without stems / error / ineligible -> Failure; else null (keep polling). */
    private fun terminal(v: StemJob): Result<Map<String, String>>? = when (v.phase) {
        StemPhase.READY -> v.stems?.let { Result.success(urls(it)) } ?: Result.failure(IllegalStateException("ready without stems"))
        StemPhase.ERROR, StemPhase.INELIGIBLE -> Result.failure(IllegalStateException(v.error ?: v.phase.name))
        else -> null
    }

    private fun urls(keys: Map<String, String>): Map<String, String> =
        keys.mapValues { "${ripsBase().trimEnd('/')}/${it.value.trimStart('/')}" }

    private fun auth(config: RipServerClient.Config, b: Request.Builder): Request.Builder {
        b.header("X-PocketDJ-Device", config.installId)
        if (config.token.isNotEmpty()) b.header("Authorization", "Bearer ${config.token}")
        return b
    }

    private suspend fun call(client: OkHttpClient, req: Request): StemJob? = withContext(Dispatchers.IO) {
        client.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty()
            if (!r.isSuccessful) null else runCatching { json.decodeFromString<StemJob>(text) }.getOrNull()
        }
    }
}
