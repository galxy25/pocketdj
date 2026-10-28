package com.levi.pocketdj.playback.health

import com.levi.pocketdj.diag.NPLog
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * DEAD-AIR METER - the key playback-health number (iOS `DeadAirMeter`): of the time the listener wanted the
 * set playing, how many seconds were SILENT, and where did they come from. Two complementary feeds, rolled up
 * per local calendar day and persisted (survives relaunch):
 *
 *  1. CONTINUOUS (1 Hz, from the supervisor): `activeSeconds` vs `deadSeconds`, split into TRANSITION dead air
 *     (a start window open / the track already ended) and MID-SONG dead air.
 *  2. PER TRANSITION (precise, from the sequencer): the gap from the moment a start began (auto-advance at a
 *     track's end, a skip, a cold start) to the first proof of audio, keyed by `from->to` backend. A start that
 *     hops rows stays ONE transition, measured from its original start - that is the silence heard.
 *
 * The document shape (`{"days":{"YYYY-MM-DD":{...}}}`) and every log line are iOS-identical so
 * `scripts/deadair-report.py` reads Android logs unchanged. Not thread-safe by design: callers are the
 * sequencer's single (Main) dispatcher; the ticker is the only other caller and runs on the same one.
 */
class DeadAirMeter(
    private val file: File? = null,
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
    var log: (String) -> Unit = { NPLog.lane(NPLog.DEADAIR, it) },
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    @Serializable
    data class Pair(var n: Int = 0, var seconds: Double = 0.0, var max: Double = 0.0)

    @Serializable
    data class Day(
        var activeSeconds: Double = 0.0,
        var deadSeconds: Double = 0.0,
        var transitionDeadSeconds: Double = 0.0,
        var midSongDeadSeconds: Double = 0.0,
        /** Measured transitions (closed by first audio). */
        var transitions: Int = 0,
        var transitionGapSeconds: Double = 0.0,
        var gapsOver1s: Int = 0,
        var gapsOver3s: Int = 0,
        var gapsOver10s: Int = 0,
        /** "appleMusic->burned" etc. - `cause` is folded in for non-advance starts ("start:..."). */
        var byPair: MutableMap<String, Pair> = linkedMapOf(),
    ) {
        /** Dead share of active time, 0..1 (0 when nothing was active). */
        val deadRatio: Double get() = if (activeSeconds > 0) deadSeconds / activeSeconds else 0.0
    }

    @Serializable
    data class Document(var days: MutableMap<String, Day> = linkedMapOf())

    private data class Open(val atMs: Long, val from: String, val cause: String)

    @get:Synchronized var document: Document = load()
        private set

    private var open: Open? = null
    private var openTo: String? = null

    /** The backend that last produced audio - the `from` of the next transition. */
    var lastAudibleBackend: String? = null
        private set
    private var activeSinceSummary = 0.0
    private var dirty = false
    private var lastSaveMs = Long.MIN_VALUE

    val hasOpenTransition: Boolean get() = open != null

    private fun load(): Document {
        val f = file ?: return Document()
        return try {
            if (f.isFile) JSON.decodeFromString(Document.serializer(), f.readText()) else Document()
        } catch (_: Exception) {
            Document()
        }
    }

    fun dayKey(ms: Long): String {
        val d = Instant.ofEpochMilli(ms).atZone(zone()).toLocalDate()
        return String.format(Locale.US, "%04d-%02d-%02d", d.year, d.monthValue, d.dayOfMonth)
    }

    @Synchronized fun day(ms: Long = nowMs()): Day = document.days[dayKey(ms)] ?: Day()

    // ---- per-transition (sequencer) --------------------------------------------------------

    /**
     * A start began. If a transition is already open (a hop / retry / dead-source advance inside the same
     * silence), it keeps its original start and cause.
     */
    @Synchronized fun transitionBegan(cause: String, ms: Long = nowMs()) {
        if (open != null) return
        open = Open(ms, lastAudibleBackend ?: "none", cause)
        openTo = null
    }

    /** The open transition is now trying [backend] (called at each track start). */
    @Synchronized fun trackStarting(backend: String) {
        if (open != null) openTo = backend
    }

    /** First proof of audio: close the open transition and record its gap. */
    @Synchronized fun firstAudio(backend: String? = null, ms: Long = nowMs()) {
        val to = backend ?: openTo ?: "?"
        lastAudibleBackend = to
        val o = open ?: return
        open = null
        openTo = null
        val gap = maxOf(0L, ms - o.atMs) / 1000.0
        val key = if (o.cause == "advance") "${o.from}→$to" else "${o.cause}:${o.from}→$to"
        mutate(ms) { d ->
            d.transitions += 1
            d.transitionGapSeconds += gap
            if (gap >= 1) d.gapsOver1s += 1
            if (gap >= 3) d.gapsOver3s += 1
            if (gap >= 10) d.gapsOver10s += 1
            val p = d.byPair.getOrPut(key) { Pair() }
            p.n += 1
            p.seconds += gap
            p.max = maxOf(p.max, gap)
        }
        log(String.format(Locale.US, "gap=%.2fs from=%s to=%s cause=%s", gap, o.from, to, o.cause))
    }

    /** The listener stopped / paused / took a call mid-transition: that silence is theirs - drop it unrecorded. */
    @Synchronized fun transitionAbandoned(reason: String) {
        val o = open ?: return
        open = null
        openTo = null
        log("abandoned cause=${o.cause} from=${o.from} reason=$reason")
    }

    // ---- continuous (supervisor, 1 Hz) ------------------------------------------------------

    @Synchronized fun accumulate(active: Double, dead: Double, transitionDead: Double, nowMs: Long = this.nowMs()) {
        if (active <= 0 && dead <= 0) return
        mutate(nowMs) { d ->
            d.activeSeconds += active
            d.deadSeconds += dead
            d.transitionDeadSeconds += transitionDead
            d.midSongDeadSeconds += maxOf(0.0, dead - transitionDead)
        }
        activeSinceSummary += active
        if (activeSinceSummary >= summaryEveryActiveSeconds) {
            activeSinceSummary = 0.0
            logSummary(nowMs)
        }
    }

    // ---- reporting + persistence --------------------------------------------------------------

    /** The `day=... active=...s dead=...s ratio=...%` line (iOS format, parsed by deadair-report.py). */
    @Synchronized fun summaryLine(ms: Long = nowMs()): String {
        val d = day(ms)
        return String.format(
            Locale.US,
            "day=%s active=%.0fs dead=%.0fs ratio=%.2f%% transitionDead=%.0fs midSongDead=%.0fs transitions=%d gap≥3s=%d gap≥10s=%d",
            dayKey(ms), d.activeSeconds, d.deadSeconds, d.deadRatio * 100,
            d.transitionDeadSeconds, d.midSongDeadSeconds, d.transitions, d.gapsOver3s, d.gapsOver10s,
        )
    }

    @Synchronized fun logSummary(ms: Long = nowMs()) = log(summaryLine(ms))

    /** Persist now (backgrounding) and log the day's summary. */
    @Synchronized fun flush(ms: Long = nowMs()) {
        if (day(ms).activeSeconds > 0) logSummary(ms)
        save(force = true, ms = ms)
    }

    private fun mutate(ms: Long, body: (Day) -> Unit) {
        val d = document.days.getOrPut(dayKey(ms)) { Day() }
        body(d)
        dirty = true
        save(force = false, ms = ms)
    }

    private fun save(force: Boolean, ms: Long) {
        val f = file ?: return
        if (!dirty) return
        if (!force && lastSaveMs != Long.MIN_VALUE && ms - lastSaveMs < SAVE_THROTTLE_MS) return
        prune(ms)
        try {
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(JSON.encodeToString(Document.serializer(), document))
            if (!tmp.renameTo(f)) {
                f.writeText(tmp.readText())
                tmp.delete()
            }
        } catch (_: Exception) {
            // a full disk must not break playback
        }
        dirty = false
        lastSaveMs = ms
    }

    private fun prune(ms: Long) {
        if (document.days.size <= RETENTION_DAYS) return
        val cutoff = Instant.ofEpochMilli(ms).atZone(zone()).toLocalDate().minusDays(RETENTION_DAYS.toLong())
        val keep = String.format(Locale.US, "%04d-%02d-%02d", cutoff.year, cutoff.monthValue, cutoff.dayOfMonth)
        document.days = document.days.filterTo(linkedMapOf()) { it.key >= keep }
    }

    companion object {
        /** Days kept on disk. */
        const val RETENTION_DAYS = 60

        /** Disk writes are throttled to one per 30 s (flush forces). */
        const val SAVE_THROTTLE_MS = 30_000L

        /** A summary line is logged after this many ACTIVE seconds (and on [flush]). */
        @Volatile var summaryEveryActiveSeconds: Double = 600.0

        const val FILE_NAME = "pocketdj-dead-air.json"

        private val JSON = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    }
}
