package com.levi.pocketdj.data.catalog

import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Cover-art fallback for albums that ship NO bundled art (`artCandidates()` empty) — the
 * entire "Apple Music (Local)" catalog (12.7k albums, 0 with coverArt). Port of iOS
 * `AlbumArtworkStore`: iOS asks MusicKit for a track's artwork; Android has no MusicKit, so it
 * asks the tokenless iTunes lookup (`itunes.apple.com/lookup?id=a,b,c`) with the album's
 * `appleMusicId` (a collection id) plus the first tracks' `appleMusicId`s as fallbacks.
 *
 * - ON-DEMAND: a cover asks via [request] only when it composes.
 * - BATCHED: requests within [batchWindowMs] share one lookup of up to [maxIdsPerLookup] ids
 *   (the lookup endpoint is rate limited to roughly 20 calls/min, so one call per tile would stall).
 * - MEMOIZED: hits persist to [cacheFile] (survive relaunch); misses retry after [missTtlMs].
 * - BACKOFF: a failed lookup (network, 403/429) re-queues its albums after [backoffMs].
 */
class AlbumArtworkStore(
    private val scope: CoroutineScope,
    /** GET a URL, body or null on any failure. Injected so the batching is JVM-testable. */
    private val fetch: suspend (String) -> String?,
    private val songAppleMusicId: (String) -> String?,
    private val cacheFile: File?,
    private val json: Json = Json { ignoreUnknownKeys = true; isLenient = true },
    private val lookupBase: String = "https://itunes.apple.com/lookup",
    private val batchWindowMs: Long = 250,
    private val maxIdsPerLookup: Int = 150,
    private val missTtlMs: Long = 10 * 60_000L,
    private val backoffMs: Long = 30_000L,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _resolved = MutableStateFlow<Map<String, String>>(emptyMap())
    /** albumId → resolved cover URL (600 px). */
    val resolved: StateFlow<Map<String, String>> = _resolved.asStateFlow()

    private val missedAt = ConcurrentHashMap<String, Long>()
    private val pending = LinkedHashMap<String, List<String>>() // albumId → candidate store ids
    private val inFlight = HashSet<String>()
    private var drainJob: Job? = null
    private var backoffUntil = 0L
    private val lock = Any()
    @Volatile private var loaded = false

    /** Candidate store ids for [album]: the album's own collection id, then up to 3 track ids. */
    fun candidateIds(album: IndexAlbum): List<String> =
        (listOfNotNull(album.appleMusicId) + album.trackList.asSequence().mapNotNull(songAppleMusicId).take(3).toList())
            .filter { it.isNotBlank() && it.all(Char::isDigit) }
            .distinct()

    /** The resolved fallback URL for [albumId], if known (no network). */
    fun cached(albumId: String): String? { ensureLoaded(); return _resolved.value[albumId] }

    /** Ask for [album]'s cover; no-op when it has bundled art, is resolved, missed recently or has no ids. */
    fun request(album: IndexAlbum) {
        ensureLoaded()
        if (album.artCandidates().isNotEmpty() || _resolved.value.containsKey(album.id)) return
        missedAt[album.id]?.let { if (now() - it < missTtlMs) return else missedAt.remove(album.id) }
        val ids = candidateIds(album)
        if (ids.isEmpty()) return
        synchronized(lock) {
            if (album.id in inFlight || pending.containsKey(album.id)) return
            pending[album.id] = ids
            if (drainJob?.isActive != true) drainJob = scope.launch { drain() }
        }
    }

    /** Bundled candidates, else the fallback (awaits a resolve up to [timeoutMs]). For playback/widget cards. */
    suspend fun artUrls(album: IndexAlbum, timeoutMs: Long = 4_000): List<String> {
        val bundled = album.artCandidates()
        if (bundled.isNotEmpty()) return bundled
        cached(album.id)?.let { return listOf(it) }
        request(album)
        val url = withTimeoutOrNull(timeoutMs) {
            resolved.first { it.containsKey(album.id) || missedAt.containsKey(album.id) }[album.id]
        }
        return listOfNotNull(url)
    }

    private suspend fun drain() {
        while (true) {
            delay(batchWindowMs)
            val wait = backoffUntil - now()
            if (wait > 0) delay(wait)
            val batch = LinkedHashMap<String, List<String>>()
            synchronized(lock) {
                var n = 0
                val it = pending.entries.iterator()
                while (it.hasNext()) {
                    val e = it.next()
                    if (n > 0 && n + e.value.size > maxIdsPerLookup) break
                    batch[e.key] = e.value; n += e.value.size; it.remove(); inFlight += e.key
                }
                if (batch.isEmpty()) { drainJob = null; return }
            }
            val ids = batch.values.flatten().distinct()
            val body = fetch("$lookupBase?id=${ids.joinToString(",")}")
            val art = body?.let { parseLookup(it) }
            synchronized(lock) {
                inFlight -= batch.keys
                if (art == null) {
                    // Transport failure / throttled: re-queue the whole batch after a backoff.
                    backoffUntil = now() + backoffMs
                    batch.forEach { (k, v) -> pending.putIfAbsent(k, v) }
                }
            }
            if (art != null) {
                val hits = HashMap<String, String>()
                for ((albumId, cands) in batch) {
                    val url = cands.firstNotNullOfOrNull { art[it] }
                    if (url != null) hits[albumId] = url else missedAt[albumId] = now()
                }
                if (hits.isNotEmpty()) {
                    _resolved.value = _resolved.value + hits
                    persist()
                } else if (batch.isNotEmpty()) {
                    _resolved.value = _resolved.value // wake artUrls() waiters on a miss
                }
            }
        }
    }

    private fun ensureLoaded() {
        if (loaded) return
        synchronized(lock) {
            if (loaded) return
            loaded = true
            val f = cacheFile ?: return
            val map = runCatching {
                if (!f.exists()) emptyMap() else json.parseToJsonElement(f.readText()).jsonObject
                    .mapValues { it.value.jsonPrimitive.content }
            }.getOrDefault(emptyMap())
            if (map.isNotEmpty()) _resolved.value = map + _resolved.value
        }
    }

    private fun persist() {
        val f = cacheFile ?: return
        val snapshot = _resolved.value
        scope.launch(Dispatchers.IO) {
            runCatching {
                val tmp = File(f.parentFile, f.name + ".tmp")
                tmp.writeText(JsonObject(snapshot.mapValues { JsonPrimitive(it.value) }).toString())
                tmp.renameTo(f)
            }
        }
    }

    companion object {
        /** iTunes lookup body → store id (collectionId for albums, trackId for songs) → 600 px art URL. Null when unparseable. */
        fun parseLookup(body: String, json: Json = Json { ignoreUnknownKeys = true; isLenient = true }): Map<String, String>? =
            runCatching {
                val results = json.parseToJsonElement(body).jsonObject["results"]?.jsonArray ?: return@runCatching null
                val out = HashMap<String, String>()
                for (r in results) {
                    val o = r.jsonObject
                    val art = (o["artworkUrl100"] ?: o["artworkUrl60"])?.jsonPrimitive?.content ?: continue
                    val big = upsize(art)
                    val wrapper = o["wrapperType"]?.jsonPrimitive?.content
                    val key = if (wrapper == "track") o["trackId"] else o["collectionId"]
                    key?.jsonPrimitive?.longOrNull?.let { out[it.toString()] = big }
                    // A track result also answers for its album's collection id.
                    o["collectionId"]?.jsonPrimitive?.longOrNull?.let { out.putIfAbsent(it.toString(), big) }
                }
                out
            }.getOrNull()

        /** mzstatic "…/100x100bb.jpg" → "…/600x600bb.jpg". */
        fun upsize(url: String): String = url.replace(Regex("/\\d+x\\d+bb\\.(jpg|png|webp)$"), "/600x600bb.$1")
    }
}
