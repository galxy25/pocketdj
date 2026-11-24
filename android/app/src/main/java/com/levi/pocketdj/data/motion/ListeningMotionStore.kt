package com.levi.pocketdj.data.motion

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import kotlinx.serialization.Serializable
import java.io.File

/**
 * Port of iOS `ListeningMotionStore`: the per-device motion opt-in (`pocketdj-listening-motion.json {isEnabled}`,
 * never synced; default OFF) plus the settle pass. Inert without the ACTIVITY_RECOGNITION permission. No GPS; raw
 * motion never leaves the device.
 */
class ListeningMotionStore(
    private val file: File,
    private val timeline: MotionTimelineStore,
    private val hasPermission: () -> Boolean,
    private val source: Source,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** Registers/unregisters the transition updates (ActivityTransitionSource in production). */
    interface Source { fun register(); fun unregister() }

    @Serializable
    data class Document(val isEnabled: Boolean = false)

    @Volatile var isEnabled: Boolean = readEnabled(file); private set
    @Volatile var lastSettledCount: Int = 0; private set
    private val settleLock = Any()
    private var settleInFlight = false

    val isActive: Boolean get() = isEnabled && hasPermission()

    /** Turn the opt-in on/off. The caller has already obtained the runtime permission (after the disclosure). */
    fun setEnabled(on: Boolean) {
        isEnabled = on
        persist()
        if (on && hasPermission()) source.register() else if (!on) source.unregister()
    }

    /** App start / boot / package replace: (re)register when opted in and permitted. */
    fun ensureRegistered() { if (isActive) source.register() }

    /**
     * One settle pass over this install's unsettled plays; [stamp] is write-once ([PlayHistoryStore.stampMotion]).
     * Returns how many plays were stamped.
     */
    fun settle(
        events: List<PlayEvent>,
        isOwn: (PlayEvent) -> Boolean,
        lengthOf: (String) -> Int?,
        stamp: (Map<String, String>) -> Int,
    ): Int {
        if (!isActive) return 0
        synchronized(settleLock) { if (settleInFlight) return 0; settleInFlight = true }
        try {
            val nowMs = now().toDouble()
            val plays = ArrayList<MotionSettle.Play>()
            for (e in events.asReversed()) {
                if (nowMs - e.playedAt > MotionSettle.HORIZON_MS) break
                if (e.motion != null || !isOwn(e)) continue
                val d = MotionSettle.duration(lengthOf(SongVariant.baseId(e.songId)), e.listenedFraction)
                if (!MotionSettle.isEligible(e.playedAt, d, nowMs)) continue
                plays += MotionSettle.Play(e.id, e.playedAt, d)
            }
            val earliest = plays.minOfOrNull { it.playedAtMs } ?: return 0
            val segs = timeline.segments(earliest.toLong(), now())
            val tokens = MotionSettle.settle(plays, segs, nowMs)
            if (tokens.isNotEmpty()) stamp(tokens)
            lastSettledCount = tokens.size
            return tokens.size
        } finally {
            synchronized(settleLock) { settleInFlight = false }
        }
    }

    fun settle(history: PlayHistoryStore, lengthOf: (String) -> Int?): Int =
        settle(history.events, { !history.isFromAnotherDevice(it) }, lengthOf) { history.stampMotion(it) }

    /** Activity over the last [windowMs] (default 5 min): the centre play button's `mode_now` input. */
    fun currentActivity(windowMs: Long = 5 * 60_000L): String? {
        if (!isActive) return null
        val n = now()
        return MotionSettle.current(timeline.segments(n - windowMs, n))
    }

    /** Delete history / account deletion: opt out, drop the timeline and the registration. */
    fun clearLocal() {
        runCatching { source.unregister() }
        isEnabled = false
        timeline.clear()
        runCatching { file.delete() }
    }

    private fun persist() {
        runCatching { file.writeText(PdjJson.lenient.encodeToString(Document.serializer(), Document(isEnabled))) }
    }

    companion object {
        const val FILE_NAME = "pocketdj-listening-motion.json"
        /** SharedPreferences key of the Phase 5b "Adapt pocket runs to walking & running" toggle (default off). */
        const val ADAPT_TO_ACTIVITY_KEY = "pdj.wheel.adaptToActivity"

        fun readEnabled(file: File): Boolean = runCatching {
            file.exists() && PdjJson.lenient.decodeFromString(Document.serializer(), file.readText()).isEnabled
        }.getOrDefault(false)
    }
}
