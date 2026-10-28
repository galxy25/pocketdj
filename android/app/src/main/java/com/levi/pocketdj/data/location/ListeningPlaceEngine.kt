package com.levi.pocketdj.data.location

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.pockets.ListeningContextTag
import java.security.SecureRandom
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

// LISTENING PLACE ENGINE - the pure, platform-neutral core of the on-device location context
// (port of apple Location/ListeningPlaceEngine.swift). Plain doubles + epoch-ms in, opaque ids out:
// no Android location APIs here, so every rule (clustering, merge, trips, lookup, ranks, prune) is
// JVM-testable with synthetic visits. [ListeningLocationStore] persists one and feeds it from a
// [ListeningLocationSource].
//
// Privacy shape of the persisted state: place CENTROIDS (rounded to `centroidDecimals`) and raw
// visit samples (kept `rawRetentionDays`) are the ONLY coordinates. Timeline, trip table and
// aliases hold ids + times only. None of it leaves the device - only the opaque ids `lookup`
// hands out are stamped onto plays.
//
// Time is epoch milliseconds (Long). Durations in [Params] are seconds (Double), as on iOS.

/** One platform "visit" (arrival/departure at a place), de-platformed. */
@Serializable
data class LocationVisitSample(
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracy: Double,
    /** null = arrival unknown (distantPast). */
    val arrivalMs: Long? = null,
    /** null = still there (distantFuture). */
    val departureMs: Long? = null,
)

/** A coarse movement fix - used only as an early DEPARTURE hint. Never stored. */
@Serializable
data class LocationFixSample(
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracy: Double,
    val atMs: Long,
)

/** ONE place for every knob. Not persisted. */
data class ListeningPlaceParams(
    val maxAccuracyM: Double = 200.0,
    val maxMovementAccuracyM: Double = 3_000.0,
    val placeRadiusM: Double = 150.0,
    val mergeRadiusM: Double = 100.0,
    val minVisitDwellS: Double = 5.0 * 60,
    val minDwellForLabelS: Double = 60.0 * 60,
    val rankWindowDays: Double = 60.0,
    val maxTripDurationS: Double = 4.0 * 60 * 60,
    val minTripOccurrencesForLabel: Int = 2,
    val rawRetentionDays: Double = 30.0,
    val timelineRetentionDays: Double = 180.0,
    val placeRetentionDays: Double = 180.0,
    val centroidDecimals: Int = 4,
    val segmentMatchToleranceS: Double = 15.0 * 60,
)

/** A clustered dwell location. Id minted once; centroid drifts (dwell-weighted) and is stored ROUNDED. */
@Serializable
data class ListeningPlace(
    val id: String,
    var latitude: Double,
    var longitude: Double,
    /** Dwell seconds behind the centroid's weighted mean. */
    var weight: Double,
    var createdAtMs: Long,
    var lastSeenAtMs: Long,
)

/** One stay at a place. No coordinates. `endMs == null` = still there (runs to now). */
@Serializable
data class DwellSegment(
    var placeId: String,
    var startMs: Long,
    var endMs: Long? = null,
    /** `end` is a GUESS (next arrival clamped it, or a movement hint closed it); the real departure may move it earlier. */
    var endIsEstimate: Boolean? = null,
) {
    val endIsProvisional: Boolean get() = endMs == null || endIsEstimate == true
}

/** A raw visit as received, kept `rawRetentionDays` (dedupe of platform redeliveries). */
@Serializable
data class StoredVisit(val visit: LocationVisitSample, val receivedAtMs: Long)

class ListeningPlaceEngine(val params: ListeningPlaceParams = ListeningPlaceParams()) {

    private val _places = ArrayList<ListeningPlace>()
    private val _timeline = ArrayList<DwellSegment>()
    private val _rawVisits = ArrayList<StoredVisit>()
    private val _tripIds = LinkedHashMap<String, String>()
    private val _aliases = LinkedHashMap<String, String>()

    val places: List<ListeningPlace> get() = _places
    /** Sorted by start, non-overlapping (see [normalizeTimeline]). */
    val timeline: List<DwellSegment> get() = _timeline
    val rawVisits: List<StoredVisit> get() = _rawVisits
    /** `"<origin>><destination>"` (or `"<origin>>?"`) -> `trp_...`; minted first time an ORDERED pair is seen. */
    val tripIds: Map<String, String> get() = _tripIds
    /** Merged-away id -> survivor id (places AND trips). */
    val aliases: Map<String, String> get() = _aliases
    /** Set when the user turns location on; lookups before it are unavailable. */
    var trackingStartedAtMs: Long? = null

    // MARK: - Ingest

    /** Fold one visit in: cluster, open/close its segment, merge drifted places, mint trip ids, prune. */
    fun ingest(v: LocationVisitSample, nowMs: Long, newId: () -> String = ::randomHex16) {
        if (!v.latitude.isFinite() || !v.longitude.isFinite()) return
        if (v.horizontalAccuracy < 0 || v.horizontalAccuracy > params.maxAccuracyM) return
        if (v.arrivalMs == null && v.departureMs == null) return
        var dwell = 0.0
        if (v.arrivalMs != null && v.departureMs != null) {
            dwell = (v.departureMs - v.arrivalMs) / 1000.0
            if (dwell < params.minVisitDwellS) return
        }
        // Redelivered identical sample is already counted - re-adding would double its weight.
        if (_rawVisits.any { it.visit == v }) return
        _rawVisits.add(StoredVisit(v, nowMs))

        val seen = v.departureMs ?: nowMs
        val placeId: String
        val i = nearestPlaceIndex(v.latitude, v.longitude, params.placeRadiusM)
        if (i != null) {
            val p = _places[i]
            if (dwell > 0) {
                val w = p.weight
                p.latitude = roundCoord((p.latitude * w + v.latitude * dwell) / (w + dwell))
                p.longitude = roundCoord((p.longitude * w + v.longitude * dwell) / (w + dwell))
                p.weight = w + dwell
            }
            p.lastSeenAtMs = max(p.lastSeenAtMs, seen)
            placeId = p.id
        } else {
            placeId = PLACE_PREFIX + newId()
            _places.add(
                ListeningPlace(placeId, roundCoord(v.latitude), roundCoord(v.longitude), dwell,
                    v.arrivalMs ?: nowMs, seen),
            )
        }
        upsertSegment(placeId, v.arrivalMs, v.departureMs)
        mergeNearbyPlaces()
        normalizeTimeline()
        ensureTripIds(newId)
        prune(nowMs)
    }

    /**
     * A coarse fix far enough from the open segment's place closes that segment at the fix time
     * (early departure hint; the real departure arrives later, back-dated, and overwrites it).
     */
    fun noteMovement(f: LocationFixSample, nowMs: Long, newId: () -> String = ::randomHex16) {
        if (!f.latitude.isFinite() || !f.longitude.isFinite()) return
        if (f.horizontalAccuracy < 0 || f.horizontalAccuracy > params.maxMovementAccuracyM) return
        val i = _timeline.lastIndex
        if (i < 0 || _timeline[i].endMs != null || f.atMs <= _timeline[i].startMs) return
        val place = _places.firstOrNull { it.id == _timeline[i].placeId } ?: return
        val d = distanceM(place.latitude, place.longitude, f.latitude, f.longitude)
        if (d <= params.placeRadiusM + f.horizontalAccuracy) return
        _timeline[i].endMs = f.atMs
        _timeline[i].endIsEstimate = true
        ensureTripIds(newId)
    }

    // MARK: - Lookup

    /** Context at [tMs]. INVARIANT: a t older than the pending horizon before now is never Pending. */
    fun lookup(tMs: Long, nowMs: Long): ListeningContextLookup {
        val started = trackingStartedAtMs
        if (started == null || tMs < started) return ListeningContextLookup.Unavailable
        if (tMs < nowMs - days(params.timelineRetentionDays)) return ListeningContextLookup.Unavailable
        val recent = nowMs - tMs < ListeningContextConstants.PENDING_HORIZON_MS
        val unresolved: ListeningContextLookup =
            if (recent) ListeningContextLookup.Pending else ListeningContextLookup.Settled(ListeningContextTag.NONE)

        val i = lastSegmentIndex(tMs) ?: return unresolved
        val seg = _timeline[i]
        val end = seg.endMs
        if (end == null || tMs <= end) {
            // Inside a stay whose end isn't REPORTED yet: a late back-dated departure may move it.
            if (seg.endIsProvisional && recent) return ListeningContextLookup.Pending
            return ListeningContextLookup.Settled(ListeningContextTag.place(seg.placeId))
        }
        val sinceDepartureS = (tMs - end) / 1000.0
        fun trip(dest: String?): ListeningContextLookup =
            tripTag(seg.placeId, dest)?.let { ListeningContextLookup.Settled(it) } ?: unresolved

        if (i + 1 < _timeline.size) {
            val next = _timeline[i + 1]
            if ((next.startMs - end) / 1000.0 <= params.maxTripDurationS) return trip(next.placeId)
            if (sinceDepartureS <= params.maxTripDurationS) return trip(null)
            return unresolved
        }
        // Departed and not (yet) arrived anywhere.
        if ((nowMs - end) / 1000.0 < params.maxTripDurationS) {
            return if (recent) ListeningContextLookup.Pending else ListeningContextLookup.Settled(ListeningContextTag.NONE)
        }
        if (sinceDepartureS <= params.maxTripDurationS) return trip(null)
        return unresolved
    }

    // MARK: - Current context (a GUESS, never stamped onto a play)

    fun currentGuess(nowMs: Long): ListeningContextTag? {
        if (trackingStartedAtMs == null) return null
        val seg = _timeline.lastOrNull() ?: return null
        if (seg.startMs > nowMs) return null
        val end = seg.endMs
        if (end == null || end > nowMs) return ListeningContextTag.place(seg.placeId)
        if ((nowMs - end) / 1000.0 > params.maxTripDurationS) return null
        val prefix = seg.placeId + ">"
        val best = tripOccurrences(nowMs).entries
            .filter { it.key.startsWith(prefix) && !it.key.endsWith(">?") }
            .sortedWith { a, b -> if (a.value != b.value) b.value.compareTo(a.value) else a.key.compareTo(b.key) }
            .firstOrNull()
        if (best != null) {
            val (o, d) = splitKey(best.key)
            tripTag(o, d)?.let { return it }
        }
        return tripTag(seg.placeId, null)
    }

    // MARK: - Labels

    /** Places ranked by share of dwell over the rank window; only those with >= minDwellForLabel. */
    fun rankedPlaces(nowMs: Long): List<ListeningPlaceLabel> {
        val order = rankOrder(nowMs)
        return order.eligible.mapIndexed { idx, e ->
            ListeningPlaceLabel(e.first, idx + 1, "Location " + letters(idx + 1),
                if (order.total > 0) e.second / order.total else 0.0)
        }
    }

    /** Trips seen at least minTripOccurrencesForLabel times, most frequent first. */
    fun trips(nowMs: Long): List<ListeningTripLabel> {
        val ranks = rankOrder(nowMs).letterRank
        return tripOccurrences(nowMs).entries
            .filter { it.value >= params.minTripOccurrencesForLabel }
            .mapNotNull { (key, count) ->
                val id = _tripIds[key] ?: return@mapNotNull null
                val (o, d) = splitKey(key)
                ListeningTripLabel(id, o, d, tripLabel(o, d, ranks), count)
            }
            .sortedWith { a, b -> if (a.occurrences != b.occurrences) b.occurrences.compareTo(a.occurrences) else a.id.compareTo(b.id) }
    }

    /** "Location A" / "A -> B" / "A loop" / "Leaving A"; null for kind none/unknown or a forgotten id. Follows aliases. */
    fun label(tag: ListeningContextTag, nowMs: Long): String? {
        val ranks = rankOrder(nowMs).letterRank
        return when (tag.kind) {
            ListeningContextTag.KIND_PLACE -> {
                val raw = tag.placeId ?: return null
                val rank = ranks[resolve(raw)] ?: return null
                "Location " + letters(rank)
            }
            ListeningContextTag.KIND_TRIP -> {
                val raw = tag.tripId ?: return null
                val id = resolve(raw)
                val key = _tripIds.entries.firstOrNull { it.value == id }?.key ?: return null
                val (o, d) = splitKey(key)
                if (ranks[o] == null) return null
                tripLabel(o, d, ranks)
            }
            else -> null
        }
    }

    // MARK: - Prune

    /** Retention: raw visits, dwell segments, and places (with their trip pairs + aliases) unseen too long. */
    fun prune(nowMs: Long) {
        val rawCutoff = nowMs - days(params.rawRetentionDays)
        _rawVisits.removeAll { (it.visit.departureMs ?: it.visit.arrivalMs ?: it.receivedAtMs) < rawCutoff }

        val timelineCutoff = nowMs - days(params.timelineRetentionDays)
        _timeline.removeAll { (it.endMs ?: nowMs) < timelineCutoff }

        val placeCutoff = nowMs - days(params.placeRetentionDays)
        val gone = _places.filter { it.lastSeenAtMs < placeCutoff }.map { it.id }.toSet()
        if (gone.isNotEmpty()) {
            _places.removeAll { it.id in gone }
            _timeline.removeAll { it.placeId in gone }
            val keep = _tripIds.filter { (key, _) ->
                val (o, d) = splitKey(key)
                o !in gone && !(d != null && d in gone)
            }
            _tripIds.clear(); _tripIds.putAll(keep)
        }
        val live = _places.map { it.id }.toSet() + _tripIds.values
        val kept = _aliases.filter { (k, _) -> resolve(k) in live }
        _aliases.clear(); _aliases.putAll(kept)
    }

    // MARK: - Internals

    private fun days(d: Double): Long = (d * 86_400_000.0).toLong()

    private fun roundCoord(x: Double): Double {
        val m = 10.0.pow(params.centroidDecimals)
        return (x * m).roundToLong() / m
    }

    private fun nearestPlaceIndex(lat: Double, lon: Double, radius: Double): Int? {
        var best: Pair<Int, Double>? = null
        for ((i, p) in _places.withIndex()) {
            val d = distanceM(p.latitude, p.longitude, lat, lon)
            if (d <= radius && d < (best?.second ?: Double.POSITIVE_INFINITY)) best = i to d
        }
        return best?.first
    }

    private fun upsertSegment(placeId: String, arrivalMs: Long?, departureMs: Long?) {
        if (arrivalMs != null) {
            val i = _timeline.indexOfLast {
                it.placeId == placeId && abs(it.startMs - arrivalMs) / 1000.0 <= params.segmentMatchToleranceS
            }
            if (i >= 0) {
                _timeline[i].startMs = arrivalMs
                if (departureMs != null) { _timeline[i].endMs = departureMs; _timeline[i].endIsEstimate = null }
            } else {
                _timeline.add(DwellSegment(placeId, arrivalMs, departureMs))
            }
        } else if (departureMs != null) {
            // Arrival unknown: the departure closes (or corrects the guessed end of) the stay we have.
            val i = _timeline.indexOfLast { it.placeId == placeId && it.endIsProvisional }
            if (i >= 0) {
                _timeline[i].endMs = max(departureMs, _timeline[i].startMs)
                _timeline[i].endIsEstimate = null
            }
        }
    }

    /** Sorted by start; a stay ends no later than the next starts; adjacent same-place stays fuse. */
    private fun normalizeTimeline() {
        val sorted = _timeline.sortedWith { a, b ->
            if (a.startMs != b.startMs) a.startMs.compareTo(b.startMs) else a.placeId.compareTo(b.placeId)
        }
        val out = ArrayList<DwellSegment>()
        for (seg in sorted) {
            seg.endMs?.let { if (it < seg.startMs) seg.endMs = seg.startMs }
            val prev = out.lastOrNull()
            if (prev != null) {
                // An open stay ends when the next one starts - a GUESS.
                if (prev.endMs == null) { prev.endMs = seg.startMs; prev.endIsEstimate = true }
                if (prev.endMs!! > seg.startMs) prev.endMs = seg.startMs
                val pe = prev.endMs
                if (prev.placeId == seg.placeId && pe != null &&
                    (seg.startMs - pe) / 1000.0 <= params.minVisitDwellS
                ) {
                    val se = seg.endMs
                    if (se != null && se >= pe) {
                        prev.endMs = se; prev.endIsEstimate = seg.endIsEstimate
                    } else if (se == null) {
                        prev.endMs = null; prev.endIsEstimate = null
                    }
                    continue
                }
            }
            out.add(seg)
        }
        _timeline.clear(); _timeline.addAll(out)
    }

    /** Merge places whose centroids drifted within mergeRadiusM; the OLDER id survives, the younger aliases to it. */
    private fun mergeNearbyPlaces() {
        var merged = true
        while (merged) {
            merged = false
            search@ for (i in _places.indices) {
                for (j in i + 1 until _places.size) {
                    val d = distanceM(_places[i].latitude, _places[i].longitude, _places[j].latitude, _places[j].longitude)
                    if (d <= params.mergeRadiusM) { merge(i, j); merged = true; break@search }
                }
            }
        }
    }

    private fun merge(i: Int, j: Int) {
        val pi = _places[i]; val pj = _places[j]
        val iOlder = if (pi.createdAtMs != pj.createdAtMs) pi.createdAtMs < pj.createdAtMs else pi.id < pj.id
        val si = if (iOlder) i else j
        val vi = if (iOlder) j else i
        val s = _places[si]
        val v = _places[vi]
        val w = s.weight + v.weight
        if (w > 0) {
            s.latitude = roundCoord((s.latitude * s.weight + v.latitude * v.weight) / w)
            s.longitude = roundCoord((s.longitude * s.weight + v.longitude * v.weight) / w)
        }
        s.weight = w
        s.createdAtMs = min(s.createdAtMs, v.createdAtMs)
        s.lastSeenAtMs = max(s.lastSeenAtMs, v.lastSeenAtMs)
        _places.removeAt(vi)

        for (seg in _timeline) if (seg.placeId == v.id) seg.placeId = s.id
        addAlias(v.id, s.id)

        // Re-key the trip table; a re-keyed pair colliding with an existing one aliases to it.
        val rekeyed = LinkedHashMap<String, String>()
        val moved = ArrayList<Pair<String, String>>()
        for ((key, tid) in _tripIds) {
            val (o, d) = splitKey(key)
            if (o == v.id || d == v.id) {
                moved.add(tripKey(if (o == v.id) s.id else o, if (d == v.id) s.id else d) to tid)
            } else {
                rekeyed[key] = tid
            }
        }
        for ((key, tid) in moved.sortedBy { it.second }) {
            val existing = rekeyed[key]
            if (existing != null) addAlias(tid, existing) else rekeyed[key] = tid
        }
        _tripIds.clear(); _tripIds.putAll(rekeyed)
    }

    private fun addAlias(old: String, new: String) {
        if (old == new) return
        for ((k, value) in _aliases.entries.toList()) if (value == old) _aliases[k] = new
        _aliases[old] = new
    }

    /** Follows the alias chain (bounded so a corrupted cycle can't hang a lookup). */
    fun resolve(id: String): String {
        var cur = id
        repeat(16) { cur = _aliases[cur] ?: return cur }
        return cur
    }

    /** Mint an id for every ordered pair the timeline contains, and an `<origin>>?` for every departure. */
    private fun ensureTripIds(newId: () -> String) {
        fun mint(key: String) { if (_tripIds[key] == null) _tripIds[key] = TRIP_PREFIX + newId() }
        for ((k, seg) in _timeline.withIndex()) {
            val end = seg.endMs ?: continue
            if (k + 1 < _timeline.size) {
                val next = _timeline[k + 1]
                if ((next.startMs - end) / 1000.0 <= params.maxTripDurationS) {
                    mint(tripKey(seg.placeId, next.placeId))
                    continue
                }
            }
            mint(tripKey(seg.placeId, null))
        }
    }

    private fun tripOccurrences(nowMs: Long): Map<String, Int> {
        val counts = LinkedHashMap<String, Int>()
        for ((k, seg) in _timeline.withIndex()) {
            val end = seg.endMs ?: continue
            if (k + 1 < _timeline.size && (_timeline[k + 1].startMs - end) / 1000.0 <= params.maxTripDurationS) {
                counts.merge(tripKey(seg.placeId, _timeline[k + 1].placeId), 1, Int::plus)
            } else if (k + 1 < _timeline.size || (nowMs - end) / 1000.0 >= params.maxTripDurationS) {
                counts.merge(tripKey(seg.placeId, null), 1, Int::plus)
            }
        }
        return counts
    }

    private fun tripTag(origin: String, destination: String?): ListeningContextTag? {
        val id = _tripIds[tripKey(origin, destination)] ?: return null
        return ListeningContextTag.trip(id, origin, destination)
    }

    private fun lastSegmentIndex(tMs: Long): Int? {
        var lo = 0; var hi = _timeline.size   // first index with start > t
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (_timeline[mid].startMs <= tMs) lo = mid + 1 else hi = mid
        }
        return if (lo == 0) null else lo - 1
    }

    private class RankOrder(val eligible: List<Pair<String, Double>>, val total: Double, val letterRank: Map<String, Int>)

    private fun rankOrder(nowMs: Long): RankOrder {
        val windowStart = nowMs - days(params.rankWindowDays)
        val dwell = HashMap<String, Double>()
        for (seg in _timeline) {
            val s = max(seg.startMs, windowStart)
            val e = min(seg.endMs ?: nowMs, nowMs)
            if (e > s) dwell[seg.placeId] = (dwell[seg.placeId] ?: 0.0) + (e - s) / 1000.0
        }
        val total = dwell.values.sum()
        val sorted = _places.sortedWith { a, b ->
            val da = dwell[a.id] ?: 0.0; val db = dwell[b.id] ?: 0.0
            when {
                da != db -> db.compareTo(da)
                a.createdAtMs != b.createdAtMs -> a.createdAtMs.compareTo(b.createdAtMs)
                else -> a.id.compareTo(b.id)
            }
        }
        val eligible = sorted.filter { (dwell[it.id] ?: 0.0) >= params.minDwellForLabelS }
            .map { it.id to (dwell[it.id] ?: 0.0) }
        val eligibleIds = eligible.map { it.first }.toSet()
        val letterRank = LinkedHashMap<String, Int>()
        for ((i, e) in eligible.withIndex()) letterRank[e.first] = i + 1
        var next = eligible.size + 1
        for (p in sorted) if (p.id !in eligibleIds) { letterRank[p.id] = next; next += 1 }
        return RankOrder(eligible, total, letterRank)
    }

    // MARK: - Persistence shape

    /** The persisted engine state (lenient on read: a damaged field resets to empty). */
    fun toJson(): JsonObject {
        val j = PdjJson.lenient
        val m = linkedMapOf<String, JsonElement>()
        m["places"] = j.encodeToJsonElement(ListSerializer(ListeningPlace.serializer()), _places)
        m["timeline"] = j.encodeToJsonElement(ListSerializer(DwellSegment.serializer()), _timeline)
        m["rawVisits"] = j.encodeToJsonElement(ListSerializer(StoredVisit.serializer()), _rawVisits)
        m["tripIds"] = j.encodeToJsonElement(MapSerializer(String.serializer(), String.serializer()), _tripIds)
        m["aliases"] = j.encodeToJsonElement(MapSerializer(String.serializer(), String.serializer()), _aliases)
        trackingStartedAtMs?.let { m["trackingStartedAtMs"] = JsonPrimitive(it) }
        return JsonObject(m)
    }

    private fun loadFrom(o: JsonObject) {
        val j = PdjJson.lenient
        fun <T> field(key: String, ser: kotlinx.serialization.KSerializer<T>): T? {
            val e = o[key] ?: return null
            if (e is JsonNull) return null
            return runCatching { j.decodeFromJsonElement(ser, e) }.getOrNull()
        }
        _places.clear(); _places.addAll(field("places", ListSerializer(ListeningPlace.serializer())) ?: emptyList())
        _timeline.clear(); _timeline.addAll(field("timeline", ListSerializer(DwellSegment.serializer())) ?: emptyList())
        _rawVisits.clear(); _rawVisits.addAll(field("rawVisits", ListSerializer(StoredVisit.serializer())) ?: emptyList())
        _tripIds.clear(); _tripIds.putAll(field("tripIds", MapSerializer(String.serializer(), String.serializer())) ?: emptyMap())
        _aliases.clear(); _aliases.putAll(field("aliases", MapSerializer(String.serializer(), String.serializer())) ?: emptyMap())
        trackingStartedAtMs = (o["trackingStartedAtMs"] as? JsonPrimitive)?.longOrNull
        normalizeTimeline()
    }

    companion object {
        const val PLACE_PREFIX = "plc_"
        const val TRIP_PREFIX = "trp_"
        private val rng = SecureRandom()

        fun fromJson(o: JsonObject?, params: ListeningPlaceParams = ListeningPlaceParams()): ListeningPlaceEngine {
            val e = ListeningPlaceEngine(params)
            if (o != null) e.loadFrom(o)
            return e
        }

        /** 16 random lowercase hex - the opaque suffix of every place/trip id (prefix added by the engine). */
        fun randomHex16(): String = String.format("%016x", rng.nextLong())

        /** Great-circle distance in metres (haversine). */
        fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val r = 6_371_000.0
            val p1 = Math.toRadians(lat1); val p2 = Math.toRadians(lat2)
            val dp = Math.toRadians(lat2 - lat1); val dl = Math.toRadians(lon2 - lon1)
            val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
            return 2 * r * atan2(sqrt(a), sqrt(max(0.0, 1 - a)))
        }

        /** 1 -> "A" ... 26 -> "Z", 27 -> "AA" (bijective base-26). */
        fun letters(rank: Int): String {
            var n = max(1, rank)
            val sb = StringBuilder()
            while (n > 0) {
                n -= 1
                sb.insert(0, ('A'.code + n % 26).toChar())
                n /= 26
            }
            return sb.toString()
        }

        fun tripKey(origin: String, destination: String?): String = origin + ">" + (destination ?: "?")

        fun splitKey(key: String): Pair<String, String?> {
            val idx = key.indexOf('>')
            if (idx < 0) return key to null
            val d = key.substring(idx + 1)
            return key.substring(0, idx) to (if (d == "?") null else d)
        }

        fun tripLabel(origin: String, destination: String?, ranks: Map<String, Int>): String {
            val o = ranks[origin]?.let { letters(it) } ?: "?"
            if (destination == null) return "Leaving $o"
            if (destination == origin) return "$o ↺"
            return o + " → " + (ranks[destination]?.let { letters(it) } ?: "?")
        }
    }
}
