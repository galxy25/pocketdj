package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * v3: the timbre fit's e-fold moved to the instrument's measured error bar and the genre table
 * stopped dropping one catalog row in ten. Both change the ORDER of a cached feed, so a snapshot
 * written before them reads as NO cache (see [ForYouFeedSnapshot.isCurrent]).
 */
const val FOR_YOU_FEED_SCHEMA_VERSION = 3

/**
 * The frozen For You result (wire-compatible with iOS `pocketdj-foryou-feed.json`). Everything is
 * recomputed ONLY on menu Refresh / first build / schedule due; 👍/👎 re-derive cards from this
 * without re-ranking. Decoding is LENIENT per field: missing zoneSourceRaw -> onDevice, missing
 * reasons -> null (never an empty map), a malformed crates array -> no crates.
 */
data class ForYouFeedSnapshot(
    val schemaVersion: Int = FOR_YOU_FEED_SCHEMA_VERSION,
    val refreshedAtMs: Double = 0.0,
    val zoneIds: List<String> = emptyList(),
    val zoneBuriedIds: List<String> = emptyList(),
    val zoneSourceRaw: String = ForYouTileSource.ON_DEVICE.raw,
    val zoneReasons: Map<String, String>? = null,
    val crates: List<Crate> = emptyList(),
) {
    data class Crate(
        val id: String,
        val kind: String,
        val name: String,
        val songIds: List<String>,
        val reasons: Map<String, String>? = null,
        val soundIds: List<String>? = null,
    )

    val zoneSource: ForYouTileSource get() = ForYouTileSource.fromRaw(zoneSourceRaw) ?: ForYouTileSource.ON_DEVICE

    val hasResult: Boolean get() = refreshedAtMs > 0

    /** A document older than the current engine is NOT a cache. */
    val isCurrent: Boolean get() = schemaVersion >= FOR_YOU_FEED_SCHEMA_VERSION

    /** Frozen ids for a tile id ("zone" or "col-<id>"); null when unknown / no result yet. */
    fun songIds(forTileId: String): List<String>? {
        if (forTileId == ForYouTileKind.ZONE.raw) return if (hasResult) zoneIds else null
        return crates.firstOrNull { "col-${it.id}" == forTileId }?.songIds
    }

    fun reasons(forTileId: String): Map<String, String> {
        if (forTileId == ForYouTileKind.ZONE.raw) return zoneReasons ?: emptyMap()
        return crates.firstOrNull { "col-${it.id}" == forTileId }?.reasons ?: emptyMap()
    }

    /** Rows admitted through the SOUND DOOR (badge set). Zone has none. */
    fun soundIds(forTileId: String): Set<String> {
        if (forTileId == ForYouTileKind.ZONE.raw) return emptySet()
        return crates.firstOrNull { "col-${it.id}" == forTileId }?.soundIds?.toSet() ?: emptySet()
    }

    fun encode(): String = buildJsonObject {
        put("schemaVersion", schemaVersion)
        put("refreshedAtMs", num(refreshedAtMs))
        put("zoneIds", strings(zoneIds))
        put("zoneBuriedIds", strings(zoneBuriedIds))
        put("zoneSourceRaw", zoneSourceRaw)
        zoneReasons?.let { put("zoneReasons", strMap(it)) }
        put("crates", buildJsonArray {
            for (c in crates) add(buildJsonObject {
                put("id", c.id)
                put("kind", c.kind)
                put("name", c.name)
                put("songIds", strings(c.songIds))
                c.reasons?.let { put("reasons", strMap(it)) }
                c.soundIds?.let { put("soundIds", strings(it)) }
            })
        })
    }.toString()

    companion object {
        private fun num(d: Double): JsonPrimitive =
            if (d == Math.floor(d) && Math.abs(d) < 9.0e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)

        private fun strings(l: List<String>): JsonArray = buildJsonArray { l.forEach { add(JsonPrimitive(it)) } }
        private fun strMap(m: Map<String, String>): JsonObject =
            JsonObject(m.mapValues { JsonPrimitive(it.value) })

        private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        private fun JsonElement?.strList(): List<String>? =
            (this as? JsonArray)?.map { it.str() ?: return null }

        private fun JsonElement?.strMap(): Map<String, String>? {
            val o = this as? JsonObject ?: return null
            val out = LinkedHashMap<String, String>()
            for ((k, v) in o) out[k] = v.str() ?: return null
            return out
        }

        private fun decodeCrate(el: JsonElement): Crate? {
            val o = el as? JsonObject ?: return null
            // Optional keys: absent/null -> null; present-but-wrong-type -> the whole crate fails
            // (synthesized Codable decodeIfPresent), which poisons the crates array like iOS.
            fun optMap(k: String): Pair<Boolean, Map<String, String>?> {
                val v = o[k]
                return if (v == null || v is JsonNull) true to null
                else (v.strMap()?.let { true to it } ?: (false to null))
            }
            fun optList(k: String): Pair<Boolean, List<String>?> {
                val v = o[k]
                return if (v == null || v is JsonNull) true to null
                else (v.strList()?.let { true to it } ?: (false to null))
            }
            val (rOk, reasons) = optMap("reasons")
            val (sOk, sound) = optList("soundIds")
            if (!rOk || !sOk) return null
            return Crate(
                id = o["id"].str() ?: return null,
                kind = o["kind"].str() ?: return null,
                name = o["name"].str() ?: return null,
                songIds = o["songIds"].strList() ?: return null,
                reasons = reasons,
                soundIds = sound,
            )
        }

        /** Lenient decode. Null only when [text] is not a JSON object. */
        fun decode(text: String, json: Json = PdjJson.lenient): ForYouFeedSnapshot? {
            val root = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            fun dbl(k: String) = (root[k] as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.doubleOrNull
            val crates = (root["crates"] as? JsonArray)?.let { arr ->
                val out = ArrayList<Crate>(arr.size)
                for (el in arr) out += decodeCrate(el) ?: return@let null // all-or-nothing, as iOS
                out
            } ?: emptyList()
            return ForYouFeedSnapshot(
                schemaVersion = (root["schemaVersion"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
                    ?: FOR_YOU_FEED_SCHEMA_VERSION,
                refreshedAtMs = dbl("refreshedAtMs") ?: 0.0,
                zoneIds = root["zoneIds"].strList() ?: emptyList(),
                zoneBuriedIds = root["zoneBuriedIds"].strList() ?: emptyList(),
                zoneSourceRaw = root["zoneSourceRaw"].str() ?: ForYouTileSource.ON_DEVICE.raw,
                zoneReasons = root["zoneReasons"].strMap(),
                crates = crates,
            )
        }
    }
}

/** One row of the Lambda's In-Da-Zone answer. */
data class ForYouCloudZoneRow(val songId: String, val why: String? = null)

/** Everything a refresh needs, captured on Main so the build can run off it. */
data class ForYouFeedInputs(
    val songs: List<IndexSong> = emptyList(),
    val tracks: List<ZoneEngine.Track> = emptyList(),
    val genreBySongId: Map<String, String> = emptyMap(),
    val plays: List<ZoneEngine.Play> = emptyList(),
    val playCount: Map<String, Int> = emptyMap(),
    val lastPlayedMs: Map<String, Double> = emptyMap(),
    /** Suggestible collections (members as ids). The zone pass sees ALL of them. */
    val crates: List<ForYouFeedSnapshot.Crate> = emptyList(),
    val zoneFeedback: ZoneEngine.Feedback = ZoneEngine.Feedback(),
    val crateFeedback: Map<String, ZoneEngine.Feedback> = emptyMap(),
    /** Collections with recs switched off: skipped BEFORE the per-crate catalog sweep. */
    val recsOffCrateIds: Set<String> = emptySet(),
    val timbre: Map<String, Map<String, Double>> = emptyMap(),
    val nowMs: Double = 0.0,
)

/** Pure, off-main builder (port of iOS `ForYouFeedBuilder`). */
object ForYouFeedBuilder {

    fun build(inputs: ForYouFeedInputs): ForYouFeedSnapshot {
        val counts = inputs.playCount
        val queue = ZoneEngine.inDaZone(
            songs = inputs.songs,
            genreBySongId = inputs.genreBySongId,
            otherCollections = inputs.crates.map { it.songIds },
            plays = inputs.plays,
            playCount = { counts[it] ?: 0 },
            lastPlayedMs = inputs.lastPlayedMs,
            feedback = inputs.zoneFeedback,
            timbre = inputs.timbre,
            nowMs = inputs.nowMs,
        )
        // The opt-out is applied BEFORE the work (each crate is a ~96k-row catalog sweep) and drops
        // the crate from the snapshot too, so a toggle-on cannot resurrect a stale frozen list.
        // The zone pass above still saw every crate (co-membership is a taste signal).
        // Version keys and the packed timbre corpus are computed ONCE for the whole refresh.
        val versions = ZoneEngine.versionKeys(inputs.tracks)
        val packed = SimilarityFamilies.pack(inputs.timbre)
        val crates = inputs.crates
            .filter { it.id !in inputs.recsOffCrateIds }
            .map { c ->
                val ranked = ZoneEngine.explainedSuggestions(
                    memberSongIds = c.songIds, tracks = inputs.tracks,
                    playCount = { counts[it] ?: 0 },
                    feedback = inputs.crateFeedback[c.id] ?: ZoneEngine.Feedback(),
                    versions = versions, timbre = inputs.timbre, packed = packed,
                )
                val rows = ranked.rows
                // An empty why is stored as ABSENCE ("no reason => no caption row").
                val reasons = LinkedHashMap<String, String>()
                for (r in rows) if (r.why.isNotEmpty()) reasons.putIfAbsent(r.songId, r.why)
                // Badge set frozen in EMITTED order so the document is stable across equal refreshes.
                val sound = rows.map { it.songId }.filter { it in ranked.soundAdmitted }
                ForYouFeedSnapshot.Crate(
                    id = c.id, kind = c.kind, name = c.name,
                    songIds = rows.map { it.songId },
                    reasons = reasons.ifEmpty { null },
                    soundIds = sound.ifEmpty { null },
                )
            }
        return ForYouFeedSnapshot(
            refreshedAtMs = inputs.nowMs,
            zoneIds = queue.songIds,
            zoneBuriedIds = queue.picks.filter { it.pool == ZoneEngine.Pool.REDISCOVERY }.map { it.songId },
            zoneSourceRaw = ForYouTileSource.ON_DEVICE.raw,
            crates = crates,
        )
    }

    /**
     * Fold the Lambda's zone into [snapshot]. Empty rows, or rows that all shape away, hand the
     * SAME snapshot back untouched. Reasons are kept only for survivors; none -> null.
     */
    fun applyingCloudZone(
        snapshot: ForYouFeedSnapshot,
        cloudZone: List<ForYouCloudZoneRow>,
        inputs: ForYouFeedInputs,
    ): ForYouFeedSnapshot {
        if (cloudZone.isEmpty()) return snapshot
        val queue = ZoneEngine.shapeCloudRanking(
            songIds = cloudZone.map { it.songId }, songs = inputs.songs, plays = inputs.plays,
            lastPlayedMs = inputs.lastPlayedMs, feedback = inputs.zoneFeedback, nowMs = inputs.nowMs,
        )
        if (queue.isEmpty) return snapshot
        val survivors = queue.songIds.toSet()
        val reasons = LinkedHashMap<String, String>()
        for (r in cloudZone) {
            val why = r.why
            if (r.songId in survivors && !why.isNullOrEmpty()) reasons.putIfAbsent(r.songId, why)
        }
        return snapshot.copy(
            zoneIds = queue.songIds,
            zoneBuriedIds = queue.picks.filter { it.pool == ZoneEngine.Pool.REDISCOVERY }.map { it.songId },
            zoneSourceRaw = ForYouTileSource.CLOUD.raw,
            zoneReasons = reasons.ifEmpty { null },
        )
    }

    /** The nightly audio-analysis shortlist: the zone first, then each crate's suggestions, deduped. */
    fun audioShortlist(
        snapshot: ForYouFeedSnapshot,
        inputs: ForYouFeedInputs,
        analysed: Set<String> = emptySet(),
        pending: Set<String> = emptySet(),
        perNight: Int = RecAudioShortlist.DEFAULT_PER_NIGHT,
    ): List<String> {
        val trackById = HashMap<String, ZoneEngine.Track>(inputs.tracks.size * 2)
        for (t in inputs.tracks) trackById.putIfAbsent(t.songId, t)
        if (trackById.isEmpty()) return emptyList()

        val seen = HashSet<String>()
        val candidates = ArrayList<RecAudioShortlist.Candidate>()
        val capKeyByArtist = HashMap<String, String>()
        fun capKey(t: ZoneEngine.Track): String =
            capKeyByArtist.getOrPut(t.artistKey) { RecNovelty.primaryArtistKey(t.artistName) }
        for (id in snapshot.zoneIds + snapshot.crates.flatMap { it.songIds }) {
            val t = trackById[id] ?: continue
            if (!seen.add(id)) continue
            candidates += RecAudioShortlist.Candidate(id, capKey(t), t.genre, t.bpm, t.camelot)
        }
        if (candidates.isEmpty()) return emptyList()

        val recent = inputs.plays.mapNotNull { trackById[it.songId] }
            .map { RecAudioShortlist.Candidate(it.songId, it.artistKey, it.genre, it.bpm, it.camelot) }
        val artistPlays = HashMap<String, Int>()
        for (t in inputs.tracks) {
            val n = inputs.playCount[t.songId] ?: 0
            if (n > 0) artistPlays.merge(capKey(t), n, Int::plus)
        }
        return RecAudioShortlist.select(
            RecAudioShortlist.Inputs(
                candidates = candidates,
                analysedIds = analysed,
                pendingIds = pending,
                recent = RecAudioShortlist.RecentProfile.from(recent),
                familiarity = RecNovelty.ArtistFamiliarity.of(artistPlays),
                perNight = perNight,
            ),
        )
    }
}
