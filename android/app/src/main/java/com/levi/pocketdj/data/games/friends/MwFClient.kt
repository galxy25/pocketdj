package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.data.PdjJson
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

/** [code] is the HTTP status (null for local/transport/decoding failures). */
class MwFException(val code: Int?, message: String, val decoding: Boolean = false) : Exception(message)

/**
 * Client for the broker's Music with Friends routes (`/mwf/...` on the SAME jukebox server).
 * Mirrors [com.levi.pocketdj.data.jukebox.JukeboxClient]: 12 s default, 30 s create/end, 6 s
 * unregister; `X-PocketDJ-Device` on every call; `Authorization` omitted when the bearer is empty.
 */
class MwFClient(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    private val configProvider: suspend () -> Config,
) {
    data class Config(val baseUrl: String, val token: String, val installId: String) {
        val normalizedBase: String get() = baseUrl.trim().trimEnd('/')
    }

    private val shortClient = http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build()
    private val longClient = http.newBuilder().callTimeout(30, TimeUnit.SECONDS).build()
    private val quickClient = http.newBuilder().callTimeout(6, TimeUnit.SECONDS).build()

    suspend fun create(
        name: String, theme: String, leaderName: String, clientId: String,
        joinSecret: String, settings: MwFSettings,
    ): MwFCreateResult {
        val cfg = configProvider()
        val body = obj(
            "name" to JsonPrimitive(name), "theme" to JsonPrimitive(theme),
            "leaderName" to JsonPrimitive(leaderName), "clientId" to JsonPrimitive(clientId),
            "joinSecret" to JsonPrimitive(joinSecret),
            "settings" to json.encodeToJsonElement(MwFSettings.serializer(), settings),
        )
        return run(longClient, cfg, cfg.normalizedBase, "/mwf", "POST", cfg.token, body, MwFCreateResult.serializer())
    }

    suspend fun join(
        apiBase: String?, sessionId: String, name: String, clientId: String,
        joinSecret: String, memberKey: String? = null,
    ): MwFJoinResult {
        val cfg = configProvider()
        val body = obj(
            "name" to JsonPrimitive(name), "clientId" to JsonPrimitive(clientId),
            "joinSecret" to JsonPrimitive(joinSecret),
        )
        return run(shortClient, cfg, base(cfg, apiBase), "/mwf/$sessionId/join", "POST", memberKey, body, MwFJoinResult.serializer())
    }

    suspend fun state(entry: MwFSessionEntry): MwFState {
        val cfg = configProvider()
        return run(shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/state", "GET", entry.memberKey, null, MwFState.serializer())
    }

    /** Public state.json (no auth, cache-busting). [url] is absolute. */
    suspend fun publicState(url: String): MwFState {
        val cfg = configProvider()
        val req = Request.Builder().url(url).header("X-PocketDJ-Device", cfg.installId)
            .header("Cache-Control", "no-cache").get().build()
        return exec(shortClient, req, MwFState.serializer())
    }

    suspend fun suggest(entry: MwFSessionEntry, title: String, artist: String): MwFSuggestResult {
        val cfg = configProvider()
        val body = obj("title" to JsonPrimitive(title), "artist" to JsonPrimitive(artist))
        return run(shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/suggest", "POST", entry.memberKey, body, MwFSuggestResult.serializer())
    }

    /** Leader verdict (`accepted` carries the match). */
    suspend fun decide(entry: MwFSessionEntry, suggestionId: String, action: String, match: MwFMatch?) {
        val leaderKey = entry.leaderKey ?: throw MwFException(401, "Not the leader")
        val cfg = configProvider()
        val fields = mutableListOf<Pair<String, kotlinx.serialization.json.JsonElement>>("action" to JsonPrimitive(action))
        if (match != null) fields += "match" to json.encodeToJsonElement(MwFMatch.serializer(), match)
        runAck(shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/suggestions/$suggestionId/decision", "POST", leaderKey, obj(*fields.toTypedArray()))
    }

    suspend fun plusOne(entry: MwFSessionEntry, suggestionId: String) {
        val cfg = configProvider()
        runAck(shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/suggestions/$suggestionId/plusone", "POST", entry.memberKey, null)
    }

    /** Leader-only partial settings update; returns the server-confirmed settings (else [settings]). */
    suspend fun configure(entry: MwFSessionEntry, settings: MwFSettings): MwFSettings {
        val leaderKey = entry.leaderKey ?: throw MwFException(401, "Not the leader")
        val cfg = configProvider()
        val reply = run(
            shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/config", "POST", leaderKey,
            json.encodeToJsonElement(MwFSettings.serializer(), settings) as JsonObject,
            ConfigReply.serializer(),
        )
        return reply.settings ?: settings
    }

    suspend fun registerDevice(entry: MwFSessionEntry, platform: String, token: String) {
        val cfg = configProvider()
        runAck(shortClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/register-device", "POST", entry.memberKey,
            obj("platform" to JsonPrimitive(platform), "token" to JsonPrimitive(token)))
    }

    /** Account deletion: withdraw this device's push token. 6 s so deletion never hangs on it. */
    suspend fun unregisterDevice(entry: MwFSessionEntry) {
        val cfg = configProvider()
        runAck(quickClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/register-device", "DELETE", entry.memberKey, null)
    }

    suspend fun end(entry: MwFSessionEntry) {
        val leaderKey = entry.leaderKey ?: throw MwFException(401, "Not the leader")
        val cfg = configProvider()
        runAck(longClient, cfg, base(cfg, entry.apiBase), "/mwf/${entry.id}/end", "POST", leaderKey, null)
    }

    /** `GET /health` against [baseOverride] (else the configured base): the older-server probe. */
    suspend fun health(baseOverride: String?): MwFHealth {
        val cfg = configProvider()
        return run(shortClient, cfg, base(cfg, baseOverride), "/health", "GET", cfg.token, null, MwFHealth.serializer())
    }

    @kotlinx.serialization.Serializable
    private data class ConfigReply(val settings: MwFSettings? = null)

    @kotlinx.serialization.Serializable
    private data class Ack(val ok: Boolean? = null)

    private fun base(cfg: Config, apiBase: String?): String {
        val trimmed = (apiBase ?: "").trim().trimEnd('/')
        return trimmed.ifEmpty { cfg.normalizedBase }
    }

    private fun obj(vararg fields: Pair<String, kotlinx.serialization.json.JsonElement>) = JsonObject(mapOf(*fields))

    private suspend fun runAck(
        client: OkHttpClient, cfg: Config, base: String, path: String, method: String,
        bearer: String?, body: JsonObject?,
    ) { run(client, cfg, base, path, method, bearer, body, Ack.serializer()) }

    private suspend fun <T> run(
        client: OkHttpClient, cfg: Config, base: String, path: String, method: String,
        bearer: String?, body: JsonObject?, serializer: KSerializer<T>,
    ): T {
        if (base.isEmpty()) throw MwFException(null, "Jukebox server URL is not set — check Settings.")
        val builder = Request.Builder().url("$base$path".let {
            it.toHttpUrlOrNull()
                ?: throw MwFException(null, "Jukebox server URL is invalid — check Settings.")
        }).header("X-PocketDJ-Device", cfg.installId)
        if (!bearer.isNullOrEmpty()) builder.header("Authorization", "Bearer $bearer")
        val requestBody: RequestBody? = when {
            body != null -> body.toString().toRequestBody(JSON)
            method == "POST" -> ByteArray(0).toRequestBody(JSON)
            else -> null
        }
        builder.method(method, requestBody)
        return exec(client, builder.build(), serializer)
    }

    private suspend fun <T> exec(client: OkHttpClient, request: Request, serializer: KSerializer<T>): T =
        withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response ->
                    val text = response.body?.string().orEmpty()
                    if (!response.isSuccessful) throw MwFException(response.code, errorMessage(response.code, text))
                    runCatching { json.decodeFromString(serializer, text) }.getOrElse {
                        throw MwFException(null, "Undecodable server response", decoding = true)
                    }
                }
            } catch (e: MwFException) {
                throw e
            } catch (e: java.io.IOException) {
                throw MwFException(null, e.message ?: "Network error")
            }
        }

    private fun errorMessage(code: Int, body: String): String {
        val serverError = runCatching { json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull()
        return serverError ?: when (code) {
            401, 403 -> "Unauthorized — check the jukebox token in Settings"
            404, 410 -> "This session has ended."
            409 -> "Not your turn yet."
            else -> "Server error ($code)"
        }
    }

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}
