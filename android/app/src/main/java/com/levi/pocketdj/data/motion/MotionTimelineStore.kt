package com.levi.pocketdj.data.motion

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.pockets.wheel.MotionToken
import kotlinx.serialization.Serializable
import java.io.File

/**
 * Device-local 7-day ring of [MotionSegment]s built from Activity Recognition ENTER/EXIT transitions
 * (`pocketdj-motion-timeline.json`, never synced, never uploaded). Android has no retroactive history query, so the
 * timeline is the retroactive source [MotionSettle] runs over. Transition events carry no confidence: segments are
 * stored as medium. At most one activity is open at a time (activities are mutually exclusive).
 */
class MotionTimelineStore(
    private val file: File,
    private val now: () -> Long = System::currentTimeMillis,
) {
    @Serializable
    data class Seg(val start: Long, val end: Long, val activity: String, val confidence: Int = MEDIUM)

    @Serializable
    data class Open(val activity: String, val since: Long)

    @Serializable
    data class Document(val segments: List<Seg> = emptyList(), val open: Open? = null)

    private val lock = Any()
    private var doc: Document = load()

    /** One transition. [entering] = ENTER, else EXIT. Unknown tokens ignored. */
    fun onTransition(activity: String, entering: Boolean, atMs: Long) {
        if (activity !in MotionToken.activityOrder) return
        synchronized(lock) {
            var segs = doc.segments
            var open = doc.open
            if (entering) {
                if (open != null && open.activity == activity) return
                if (open != null) { segs = segs + closed(open, atMs); open = null }   // missed EXIT: close at the new ENTER
                open = Open(activity, atMs)
            } else {
                if (open == null || open.activity != activity) return
                segs = segs + closed(open, atMs)
                open = null
            }
            doc = trim(Document(segs, open), now())
            save()
        }
    }

    /**
     * Close the open segment now (capped at [MAX_SEGMENT_MS]). Called when the registration may have been lost or the
     * opt-in/permission went away: Android has no retroactive query, so an unclosed segment would otherwise grow forever.
     */
    fun closeOpen(atMs: Long = now()) = synchronized(lock) {
        val o = doc.open ?: return@synchronized
        doc = trim(Document(doc.segments + closed(o, atMs), null), now())
        save()
    }

    /** Closed segments plus the open one clipped to now, overlapping [fromMs, toMs]. */
    fun segments(fromMs: Long, toMs: Long): List<MotionSegment> = synchronized(lock) {
        val all = doc.segments.map { MotionSegment(it.start, it.end, it.activity, it.confidence) } +
            listOfNotNull(doc.open?.let { MotionSegment(it.since, maxOf(it.since, minOf(now(), it.since + MAX_SEGMENT_MS)), it.activity, MEDIUM) })
        all.filter { it.endMs > fromMs && it.startMs < toMs }
    }

    fun clear() = synchronized(lock) { doc = Document(); runCatching { file.delete() } }

    private fun closed(o: Open, endMs: Long) = Seg(o.since, maxOf(o.since, minOf(endMs, o.since + MAX_SEGMENT_MS)), o.activity)

    private fun load(): Document = runCatching {
        if (!file.exists()) Document() else trim(PdjJson.lenient.decodeFromString(Document.serializer(), file.readText()), now())
    }.getOrDefault(Document())

    private fun save() {
        runCatching {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(PdjJson.lenient.encodeToString(Document.serializer(), doc))
            if (!tmp.renameTo(file)) { file.writeText(tmp.readText()); tmp.delete() }
        }
    }

    companion object {
        const val FILE_NAME = "pocketdj-motion-timeline.json"
        const val MEDIUM = 1
        const val RING_MS = 7L * 86_400_000
        /** No single activity (closed implicitly, or still open without a fresh transition) is credited beyond this. */
        const val MAX_SEGMENT_MS = 2L * 3_600_000

        internal fun trim(d: Document, nowMs: Long): Document {
            val floor = nowMs - RING_MS
            var segs = d.segments
            var open = d.open
            if (open != null && (open.since < floor || nowMs - open.since > MAX_SEGMENT_MS)) {
                // stale open (missed EXIT / lost registration): finalise it at the cap rather than let it grow
                if (open.since >= floor) segs = segs + Seg(open.since, open.since + MAX_SEGMENT_MS, open.activity)
                open = null
            }
            return Document(segs.filter { it.end >= floor }.sortedBy { it.start }, open)
        }
    }
}
