package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningContextTag
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.floor

/**
 * Pocket Wheel shared value types (iOS `PocketWheelModels.swift`, design §10.2).
 * Pure Kotlin: no Android, no clock, no Calendar.
 */

/**
 * How a play was listened to — one per play, derived at aggregation time. The serial names are PERSISTED
 * tokens (cache, palette, run file): never rename. `COLLECTION` is labelled "Home".
 */
@Serializable
enum class PocketMode(val token: String, val label: String) {
    @SerialName("carPlay") CAR_PLAY("carPlay", "CarPlay"),
    @SerialName("running") RUNNING("running", "Run"),
    @SerialName("walking") WALKING("walking", "Walk"),
    @SerialName("trip") TRIP("trip", "Trip"),
    @SerialName("mix") MIX("mix", "Mix"),
    @SerialName("browse") BROWSE("browse", "Browse"),
    @SerialName("collection") COLLECTION("collection", "Home"),
    ;

    /** The related-mode pairs: carPlay<->trip, running<->walking, mix<->collection. */
    val related: PocketMode?
        get() = when (this) {
            CAR_PLAY -> TRIP
            TRIP -> CAR_PLAY
            RUNNING -> WALKING
            WALKING -> RUNNING
            MIX -> COLLECTION
            COLLECTION -> MIX
            BROWSE -> null
        }

    /** Precedence rank (0 = highest). */
    val rank: Int get() = ordinal // declaration order == precedence order (asserted in tests)

    companion object {
        /** Fixed precedence order — also the sliver order inside a wheel cell. */
        val precedence: List<PocketMode> = listOf(CAR_PLAY, RUNNING, WALKING, TRIP, MIX, BROWSE, COLLECTION)

        fun fromToken(token: String?): PocketMode? = entries.firstOrNull { it.token == token }

        /** The ONE mode derivation — first match wins. null => excluded (games). Cycling folds into trip. */
        fun derive(source: PlaySource, carPlay: Boolean?, motion: String?, context: ListeningContextTag?): PocketMode? {
            if (source == PlaySource.GAME) return null
            if (carPlay == true) return CAR_PLAY
            when (motion) {
                MotionToken.RUNNING -> return RUNNING
                MotionToken.WALKING -> return WALKING
            }
            if (context?.isTrip == true || motion == MotionToken.AUTOMOTIVE || motion == MotionToken.CYCLING) return TRIP
            return when (source) {
                PlaySource.MIX -> MIX
                PlaySource.BROWSER, PlaySource.ALBUM, PlaySource.ARTIST -> BROWSE
                else -> COLLECTION
            }
        }

        fun derive(e: PlayEvent): PocketMode? = derive(e.source, e.carPlay, e.motion, e.listeningContext)
    }
}

/** The raw motion tokens stored on `PlayEvent.motion`. */
object MotionToken {
    const val RUNNING = "running"
    const val WALKING = "walking"
    const val CYCLING = "cycling"
    const val AUTOMOTIVE = "automotive"
    const val STATIONARY = "stationary"

    /** Tie-break order: the more active state wins. */
    val activityOrder: List<String> = listOf(RUNNING, WALKING, CYCLING, AUTOMOTIVE, STATIONARY)
    fun activityRank(t: String): Int = activityOrder.indexOf(t).let { if (it < 0) activityOrder.size else it }
}

/** One wheel cell's key. `dow` is ISO (1 = Monday .. 7 = Sunday); `hour` local 0..23. Use [of] to normalise. */
@Serializable
data class PocketMomentKey(val hour: Int, val dow: Int, val mode: PocketMode) : Comparable<PocketMomentKey> {

    /** "h08|d2|carPlay" — the token a run's plays carry (`PocketRunTag.momentKey`). */
    val token: String get() = "h${hour.toString().padStart(2, '0')}|d$dow|" + mode.token

    val isWeekend: Boolean get() = dow >= 6

    override fun compareTo(other: PocketMomentKey): Int {
        if (dow != other.dow) return dow.compareTo(other.dow)
        if (hour != other.hour) return hour.compareTo(other.hour)
        return mode.rank.compareTo(other.mode.rank)
    }

    /** "Tue 8 AM · CarPlay". */
    val shortLabel: String get() = "${weekdayAbbrev[dow - 1]} ${hourLabel(hour)} · ${mode.label}"

    /** "Tuesday 8 AM · CarPlay". */
    val longLabel: String get() = "${weekdayNames[dow - 1]} ${hourLabel(hour)} · ${mode.label}"

    companion object {
        /** iOS init: hour wraps mod 24, dow clamps to 1..7. */
        fun of(hour: Int, dow: Int, mode: PocketMode) =
            PocketMomentKey(((hour % 24) + 24) % 24, dow.coerceIn(1, 7), mode)

        /** Parse "h08|d2|carPlay"; null for anything malformed or out of range. */
        fun fromToken(token: String): PocketMomentKey? {
            val parts = token.split("|").filter { it.isNotEmpty() }
            if (parts.size != 3 || !parts[0].startsWith("h") || !parts[1].startsWith("d")) return null
            val h = parts[0].drop(1).toIntOrNull() ?: return null
            val d = parts[1].drop(1).toIntOrNull() ?: return null
            val m = PocketMode.fromToken(parts[2]) ?: return null
            if (h !in 0..23 || d !in 1..7) return null
            return PocketMomentKey(h, d, m)
        }

        val weekdayShort = listOf("M", "T", "W", "T", "F", "S", "S")
        val weekdayNames = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
        val weekdayAbbrev = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

        /** "8 AM", "12 PM", "11 PM". */
        fun hourLabel(h: Int): String {
            val hh = ((h % 24) + 24) % 24
            val twelve = if (hh % 12 == 0) 12 else hh % 12
            return "$twelve ${if (hh < 12) "AM" else "PM"}"
        }
    }
}

/**
 * The local (hour, ISO weekday) of an epoch-ms instant at a fixed UTC offset — pure, so the moment engine,
 * best-match and tests agree without a Calendar/TimeZone.
 */
object PocketClock {
    data class Local(val hour: Int, val dow: Int, val fractionalHour: Double, val dayIndex: Int)

    fun local(atMs: Double, tzOffsetMin: Int): Local {
        val localMs = atMs + tzOffsetMin.toDouble() * 60_000.0
        val dayMs = 86_400_000.0
        val dayIndex = floor(localMs / dayMs).toInt()
        val msInDay = localMs - dayIndex.toDouble() * dayMs
        val fh = msInDay / 3_600_000.0
        // 1970-01-01 was a Thursday (ISO 4).
        val dow = ((dayIndex % 7 + 7) % 7 + 3) % 7 + 1
        return Local(fh.toInt().coerceIn(0, 23), dow, fh, dayIndex)
    }
}

/** Reserved synthetic collection ids the wheel understands. */
object PocketWheelIds {
    const val FAVORITES = "fav_songs"
    const val FAVORITES_NAME = "Favorite songs"

    /** The sequencer run-tag prefix for a Pocket Wheel run (`pwr_<runId>`). */
    const val RUN_TAG_PREFIX = "pwr_"

    fun runTag(runId: String): String = RUN_TAG_PREFIX + runId

    /** The run id (verbatim, case preserved) inside a `pwr_<uuid>` tag; null when not a run tag or not a UUID. */
    fun runId(fromTag: String?): String? {
        val tag = fromTag ?: return null
        if (!tag.startsWith(RUN_TAG_PREFIX)) return null
        val id = tag.substring(RUN_TAG_PREFIX.length)
        return if (UUID_RE.matches(id)) id else null
    }

    private val UUID_RE = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
}
