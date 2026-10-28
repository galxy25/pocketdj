package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.CatalogService
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Port of iOS `TimbreCatalog`: song id → 14-axis vector from the published `timbre.json`
 * (own vectors + one-hop same-recording aliases). Offline-first via [CatalogService.loadDocument]
 * (conditional GET, cache only after a valid decode, 304 serves cache, failure serves last good,
 * cold offline ⇒ empty map ⇒ the timbre term is dead this round). The decoded map is memoized
 * for [REFRESH_INTERVAL_MS] so a For You refresh minutes later costs no network trip.
 */
class TimbreCatalog(
    private val service: CatalogService,
    private val urlProvider: () -> String,
) {
    private val mutex = Mutex()
    private var memo: Map<String, Map<String, Double>>? = null
    private var fetchedAtMs: Long = 0

    /** NEVER throws: memo, disk cache, or empty. */
    suspend fun vectors(nowMs: Long = System.currentTimeMillis()): Map<String, Map<String, Double>> =
        mutex.withLock {
            val m = memo
            if (m != null && nowMs - fetchedAtMs < REFRESH_INTERVAL_MS) return@withLock m
            val result = try {
                service.loadDocument(urlProvider(), ::decode)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            val loaded = result?.value
            if (loaded != null) {
                memo = loaded
                // Only a server-validated answer (2xx / 304) restarts the 6 h clock; a failure that
                // fell back to the disk cache is served but retried on the very next call.
                if (result.validated) fetchedAtMs = nowMs
                loaded
            } else {
                memo ?: emptyMap()
            }
        }

    companion object {
        /** Re-ask the CDN at most this often (6 h). */
        const val REFRESH_INTERVAL_MS: Long = 6L * 3_600_000

        private val json = Json { isLenient = true }

        /**
         * fold-timbre.mjs shape:
         * `{ "v":1, "timbreVersion":1, "songs": { "sng_a": {"v":1,"f":{…}}, "sng_b": {"alias":"sng_a"} } }`.
         * Null = undecodable (never cached). A document at another calibration decodes to an EMPTY
         * map (refuse to mix calibrations; fail open) — and IS cacheable, matching iOS.
         */
        fun decode(bytes: ByteArray): Map<String, Map<String, Double>>? {
            val root = runCatching { json.parseToJsonElement(bytes.decodeToString()) }.getOrNull() as? JsonObject
                ?: return null
            val songs = root["songs"] as? JsonObject ?: return null
            val docVersion = (root["timbreVersion"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull ?: 1
            if (docVersion != SimilarityFamilies.TIMBRE_VERSION) return emptyMap()

            val own = HashMap<String, Map<String, Double>>(songs.size)
            for ((id, rowEl) in songs) {
                val row = rowEl as? JsonObject ?: continue
                val f = row["f"] as? JsonObject ?: continue
                val rowVersion = (row["v"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull
                if (rowVersion != null && rowVersion != docVersion) continue
                // A PRESENT-but-null/non-numeric known axis ⇒ failed capture, drop the row.
                val broken = SimilarityFamilies.TIMBRE_AXES.any { axis ->
                    f.containsKey(axis) && !isFinite(f[axis])
                }
                if (broken) continue
                val clean = HashMap<String, Double>()
                for ((k, v) in f) {
                    val d = (v as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull
                    if (d != null && d.isFinite()) clean[k] = d
                }
                if (SimilarityFamilies.isUsableTimbreRow(clean)) own[id] = clean
            }
            // Aliases resolve against OWN vectors only: exactly one hop, deterministic.
            val out = HashMap(own)
            for ((id, rowEl) in songs) {
                if (out.containsKey(id)) continue
                val alias = ((rowEl as? JsonObject)?.get("alias") as? JsonPrimitive)
                    ?.takeIf { it !is JsonNull && it.isString }?.content ?: continue
                own[alias]?.let { out[id] = it }
            }
            return out
        }

        private fun isFinite(el: JsonElement?): Boolean =
            (el as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull?.isFinite() == true
    }
}
