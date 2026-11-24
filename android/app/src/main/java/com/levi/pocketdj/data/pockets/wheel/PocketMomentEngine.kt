package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.games.inthepocket.InThePocketContext
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.recs.SimilarityFamilies
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow

/**
 * The pure moment builder (iOS `PocketMomentEngine`): 168 hour-of-week cells x modes, decayed and smoothed.
 * O(events x kernel) + O(cells). No Android, no clock — `nowMs` is an input. Run off-main.
 */
object PocketMomentEngine {

    // Tuning (one place) — identical to iOS.
    const val HALF_LIFE_DAYS = 45.0
    const val RUN_PLAY_FACTOR = 0.5
    const val KERNEL_HOUR_1 = 0.5
    const val KERNEL_HOUR_2 = 0.15
    const val KERNEL_SAME_DAY_TYPE = 0.25
    const val KERNEL_RELATED_MODE = 0.3
    const val DOMINANT_MIN_SHARE = 0.25
    const val TOP_COLLECTIONS = 8
    const val TOP_FEATURES = 8
    const val TOP_SEEDS = 40
    const val FALLBACK_WEIGHT = 0.5
    const val MEGA_MAX_SONGS = 3_000
    const val MEGA_MAX_LIBRARY_SHARE = 0.25
    const val ADD_HALF_LIFE_DAYS = 45.0
    const val UNKNOWN_ADD_SCALE = 0.75

    private const val DAY_MS = 86_400_000.0

    // Input

    data class SongInfo(
        val artist: String,
        val genre: String? = null,
        val bpm: Double? = null,
        val year: Int? = null,
        val timbre: Map<String, Double>? = null,
    )

    data class CollectionInfo(
        val id: String,
        val name: String,
        val songIds: Set<String>,
        /** songId -> epoch ms last added (absent => unknown). */
        val addedAtMs: Map<String, Double> = emptyMap(),
    )

    data class CloudPatternRef(val id: String, val timeBucket: String? = null, val dayType: String? = null)

    data class Input(
        val events: List<PlayEvent>,
        val collections: List<CollectionInfo> = emptyList(),
        val songs: Map<String, SongInfo> = emptyMap(),
        /** Setlist id -> its playlist id (setlist origins resolve to their playlist). */
        val setlistToPlaylist: Map<String, String> = emptyMap(),
        /** Extra names (source playlists too big to carry membership, reserved ids ...). */
        val extraNames: Map<String, String> = emptyMap(),
        /** Playable library size — the mega-collection threshold's denominator. */
        val librarySize: Int = 0,
        val nowMs: Double,
        val historyRevision: Int = -1,
        val cloudPatterns: List<CloudPatternRef> = emptyList(),
    )

    /** Song -> hard memberships (id, add-time scale), with the mega flag precomputed. */
    class MembershipIndex(input: Input, wanted: Set<String>) {
        val bySong = HashMap<String, MutableList<Pair<String, Double>>>()
        val known = HashSet<String>()
        val mega = HashSet<String>()

        init {
            val libraryCap = if (input.librarySize > 0) input.librarySize.toDouble() * MEGA_MAX_LIBRARY_SHARE else Double.POSITIVE_INFINITY
            for (c in input.collections) {
                known.add(c.id)
                if (c.songIds.size > MEGA_MAX_SONGS || c.songIds.size.toDouble() > libraryCap) {
                    mega.add(c.id)
                    continue // mega collections never enter the fallback
                }
                for (s in c.songIds) if (s in wanted) {
                    bySong.getOrPut(s) { mutableListOf() }.add(c.id to membershipScale(c.addedAtMs[s], input.nowMs))
                }
            }
        }
    }

    /** Hard membership with add-time recency: 0.5 + 0.5*e^(-age/45 d); unknown add time => 0.75. */
    fun membershipScale(addedAtMs: Double?, nowMs: Double): Double {
        val t = addedAtMs ?: return UNKNOWN_ADD_SCALE
        val ageDays = max(0.0, nowMs - t) / DAY_MS
        return 0.5 + 0.5 * exp(-ageDays / ADD_HALF_LIFE_DAYS)
    }

    // Attribution

    /**
     * The sparse collection weights of one play: its ORIGIN at 1.0, else 0.5 spread over its hard (non-mega)
     * memberships proportional to m(s). Soft membership is never used for colour.
     */
    fun attribution(e: PlayEvent, input: Input, index: MembershipIndex): Map<String, Double> {
        origin(e, input, index)?.let { return mapOf(it to 1.0) }
        val ms = index.bySong[SongVariant.baseId(e.songId)]
        if (ms.isNullOrEmpty()) return emptyMap()
        val total = ms.sumOf { it.second }
        if (total <= 0) return emptyMap()
        val out = LinkedHashMap<String, Double>()
        for ((id, m) in ms) out[id] = (out[id] ?: 0.0) + FALLBACK_WEIGHT * m / total
        return out
    }

    /** First real collection among the run row's collection, the captured origin, and the context id. */
    fun origin(e: PlayEvent, input: Input, index: MembershipIndex): String? {
        fun resolve(id: String?): String? {
            if (id.isNullOrEmpty()) return null
            input.setlistToPlaylist[id]?.let { return it }
            if (id in index.known || id in input.extraNames) return id
            if (id == PocketWheelIds.FAVORITES) return id
            return null
        }
        e.pocketRun?.rowCollectionId?.let { r -> (resolve(r) ?: r.ifEmpty { null })?.let { return it } }
        e.originCollectionId?.let { o -> (resolve(o) ?: o.ifEmpty { null })?.let { return it } }
        return resolve(e.contextId)
    }

    // Build

    private class Acc {
        var plays = 0.0
        var skips = 0.0
        var directPlays = 0
        var directSkips = 0
        val days = HashSet<Int>()
        val collections = HashMap<String, Double>()
        val artists = HashMap<String, Double>()
        val genres = HashMap<String, Double>()
        val bpms = ArrayList<Pair<Double, Double>>()
        val bpmSongs = HashSet<String>()
        val years = ArrayList<Double>()
        val timbre = HashMap<String, Pair<Map<String, Double>, Double>>()
        val ctx = HashMap<String, Double>()
        val seeds = HashMap<String, Double>()
        var lastSeen = 0.0
    }

    private val MODE_COUNT = PocketMode.precedence.size
    private fun cellIndex(howIndex: Int, mode: PocketMode) = howIndex * MODE_COUNT + mode.rank

    fun build(input: Input): PocketWheelSnapshot {
        val events = input.events.filter { it.source != PlaySource.GAME }
        val wanted = events.mapTo(HashSet()) { SongVariant.baseId(it.songId) }
        val index = MembershipIndex(input, wanted)
        val defaultTz = mostCommonOffset(events)
        val acc = arrayOfNulls<Acc>(168 * MODE_COUNT)
        var totalDirect = 0

        for (e in events) {
            val mode = PocketMode.derive(e) ?: continue
            val local = PocketClock.local(e.playedAt, e.tzOffsetMin ?: defaultTz)
            val how = (local.dow - 1) * 24 + local.hour
            val ageDays = max(0.0, input.nowMs - e.playedAt) / DAY_MS
            val w = 0.5.pow(ageDays / HALF_LIFE_DAYS)
            val isRun = e.pocketRun != null
            val skipped = e.wasSkipped == true
            val song = SongVariant.baseId(e.songId)
            val info = input.songs[song]
            val attr = if (skipped) emptyMap() else attribution(e, input, index)
            val ctxKey = contextKey(e.listeningContext)
            if (!skipped) totalDirect += 1

            for (k in kernel(how, local.dow, local.hour, mode)) {
                val ci = cellIndex(k.how, k.mode)
                val a = acc[ci] ?: Acc().also { acc[ci] = it }
                val c = w * k.weight
                if (skipped) {
                    a.skips += c
                    if (k.direct) a.directSkips += 1
                } else {
                    val pc = c * (if (isRun) RUN_PLAY_FACTOR else 1.0)
                    a.plays += pc
                    for ((cid, aw) in attr) a.collections[cid] = (a.collections[cid] ?: 0.0) + pc * aw
                    if (info != null) {
                        val ak = info.artist.lowercase()
                        a.artists[ak] = (a.artists[ak] ?: 0.0) + pc
                        info.genre?.let { g -> a.genres[g] = (a.genres[g] ?: 0.0) + pc }
                        if (k.weight >= 0.25) {
                            InThePocketScorer.foldBpm(info.bpm)?.let { b ->
                                a.bpms.add(b to pc)
                                a.bpmSongs.add(song)
                            }
                            info.year?.let { y -> if (y > 0) a.years.add(y.toDouble()) }
                        }
                        if (k.weight >= 0.5 && info.timbre != null) {
                            a.timbre[song] = info.timbre to ((a.timbre[song]?.second ?: 0.0) + pc)
                        }
                    }
                    a.ctx[ctxKey] = (a.ctx[ctxKey] ?: 0.0) + pc
                    if (k.weight >= 0.5) a.seeds[song] = (a.seeds[song] ?: 0.0) + pc
                    if (k.direct) {
                        a.directPlays += 1
                        a.days.add(local.dayIndex)
                    }
                }
                if (k.direct) a.lastSeen = max(a.lastSeen, e.playedAt)
            }
        }

        // Finalise.
        val moments = ArrayList<PocketMoment>()
        val names = LinkedHashMap<String, String>(input.extraNames)
        for (c in input.collections) names[c.id] = c.name
        names[PocketWheelIds.FAVORITES] = names[PocketWheelIds.FAVORITES] ?: PocketWheelIds.FAVORITES_NAME
        val dominance = HashMap<String, Double>()
        val dominantPlays = HashMap<String, Double>()
        var totalPlays = 0.0
        for ((ci, a) in acc.withIndex()) {
            if (a == null || !(a.plays > 0 || a.skips > 0)) continue
            val how = ci / MODE_COUNT
            val mode = PocketMode.precedence[ci % MODE_COUNT]
            val key = PocketMomentKey.of(how % 24, how / 24 + 1, mode)
            val collections = topNormalized(a.collections, TOP_COLLECTIONS)
            var dominant: String? = null
            var best: Map.Entry<String, Double>? = null
            for (en in collections) {
                val b = best
                if (b == null || en.value > b.value || (en.value == b.value && en.key < b.key)) best = en
            }
            if (best != null && best.value >= DOMINANT_MIN_SHARE) {
                dominant = best.key
                dominance[best.key] = (dominance[best.key] ?: 0.0) + a.plays * best.value
                dominantPlays[best.key] = (dominantPlays[best.key] ?: 0.0) + a.plays
            }
            totalPlays += a.plays
            var bpmLo: Double? = null
            var bpmHi: Double? = null
            if (a.bpmSongs.size >= 3) {
                bpmLo = roundHalfAway(weightedPercentile(a.bpms, 0.25))
                bpmHi = roundHalfAway(weightedPercentile(a.bpms, 0.75))
            }
            val era = SimilarityFamilies.eraWindow(a.years)
            val tp = SimilarityFamilies.timbreProfile(a.timbre.values.map { SimilarityFamilies.TimbreMember(it.first, it.second) })
            moments.add(
                PocketMoment(
                    key = key,
                    plays = round6(a.plays),
                    skips = round6(a.skips),
                    distinctDays = a.days.size,
                    directPlays = a.directPlays,
                    directSkips = a.directSkips,
                    collections = collections,
                    dominantCollectionId = dominant,
                    artists = topNormalized(a.artists, TOP_FEATURES),
                    genres = topNormalized(a.genres, TOP_FEATURES),
                    bpmLo = bpmLo,
                    bpmHi = bpmHi,
                    eraLo = era?.lo,
                    eraHi = era?.hi,
                    timbreCentroid = tp?.centroid,
                    timbreSpread = tp?.spread,
                    timbreVectors = tp?.vectors,
                    ctx = topNormalized(a.ctx, TOP_FEATURES),
                    seeds = topRaw(a.seeds, TOP_SEEDS),
                    cloudPatternIds = cloudPatterns(key, input.cloudPatterns),
                    lastSeenMs = a.lastSeen,
                ),
            )
        }
        moments.sortWith(compareBy { it.key })
        val order = dominance.entries
            .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            .map { it.key }
        val share = LinkedHashMap<String, Double>()
        if (totalPlays > 0) for ((id, p) in dominantPlays) share[id] = round6(p / totalPlays)
        val referenced = HashSet(order)
        for (m in moments) referenced.addAll(m.collections.keys)
        return PocketWheelSnapshot(
            builtAtMs = input.nowMs,
            historyRevision = input.historyRevision,
            moments = moments,
            collectionNames = names.filterKeys { it in referenced },
            dominanceOrder = order,
            weekShare = share,
            totalDirectPlays = totalDirect,
        )
    }

    /** One smoothing credit: the cell it lands in, its weight, and whether it is the play's own cell. */
    data class KernelCredit(val how: Int, val mode: PocketMode, val weight: Double, val direct: Boolean)

    /** The smoothing kernel: (hourOfWeek, mode, weight, isDirect) credits for one play. */
    fun kernel(how: Int, dow: Int, hour: Int, mode: PocketMode): List<KernelCredit> {
        val out = ArrayList<KernelCredit>()
        out.add(KernelCredit(how, mode, 1.0, true))
        for ((dh, k) in listOf(-1 to KERNEL_HOUR_1, 1 to KERNEL_HOUR_1, -2 to KERNEL_HOUR_2, 2 to KERNEL_HOUR_2)) {
            out.add(KernelCredit(((how + dh) % 168 + 168) % 168, mode, k, false))
        }
        val weekend = dow >= 6
        for (d in 1..7) if (d != dow && (d >= 6) == weekend) {
            out.add(KernelCredit((d - 1) * 24 + hour, mode, KERNEL_SAME_DAY_TYPE, false))
        }
        mode.related?.let { out.add(KernelCredit(how, it, KERNEL_RELATED_MODE, false)) }
        return out
    }

    fun cloudPatterns(key: PocketMomentKey, patterns: List<CloudPatternRef>): List<String> {
        if (patterns.isEmpty()) return emptyList()
        val bucket = InThePocketContext.timeBucket(key.hour.toDouble() + 0.5)
        val dayType = if (key.isWeekend) "weekend" else "weekday"
        return patterns
            .filter { (it.timeBucket == null || it.timeBucket == bucket) && (it.dayType == null || it.dayType == dayType) }
            .map { it.id }.sorted()
    }

    fun contextKey(tag: ListeningContextTag?): String {
        if (tag == null) return "none"
        if (tag.isTrip && tag.tripId != null) return "trip:${tag.tripId}"
        if (tag.isPlace && tag.placeId != null) return "place:${tag.placeId}"
        return "none"
    }

    /** Most common recorded offset; ties go to the smaller offset; none => 0. */
    fun mostCommonOffset(events: List<PlayEvent>): Int {
        val counts = HashMap<Int, Int>()
        for (e in events) e.tzOffsetMin?.let { counts[it] = (counts[it] ?: 0) + 1 }
        return counts.entries.minWithOrNull(compareByDescending<Map.Entry<Int, Int>> { it.value }.thenBy { it.key })?.key ?: 0
    }

    private val byValueDescThenKey = compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key }

    fun topNormalized(m: Map<String, Double>, n: Int): Map<String, Double> {
        val top = m.entries.filter { it.value > 0 }.sortedWith(byValueDescThenKey).take(n)
        val total = top.sumOf { it.value }
        if (!(total > 0)) return emptyMap()
        val out = LinkedHashMap<String, Double>()
        for (e in top) out[e.key] = round6(e.value / total)
        return out
    }

    fun topRaw(m: Map<String, Double>, n: Int): Map<String, Double> {
        val out = LinkedHashMap<String, Double>()
        for (e in m.entries.filter { it.value > 0 }.sortedWith(byValueDescThenKey).take(n)) out[e.key] = round6(e.value)
        return out
    }

    fun weightedPercentile(values: List<Pair<Double, Double>>, p: Double): Double {
        val sorted = values.sortedBy { it.first }
        val total = sorted.sumOf { it.second }
        if (!(total > 0)) return sorted.firstOrNull()?.first ?: 0.0
        var run = 0.0
        for ((v, w) in sorted) {
            run += w
            if (run >= p * total) return v
        }
        return sorted.last().first
    }

    /** Six-decimal rounding keeps cache bytes and the cross-platform goldens stable. */
    fun round6(x: Double): Double = roundHalfAway(x * 1_000_000) / 1_000_000

    /** Swift `.rounded()` (schoolbook: half away from zero). */
    private fun roundHalfAway(x: Double): Double = if (x < 0) -floor(-x + 0.5) else floor(x + 0.5)
}
