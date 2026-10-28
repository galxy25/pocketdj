package com.levi.pocketdj.mix.model

/** The two decks. [label] ("A"/"B") labels the UI and namespaces per-deck state. */
enum class Deck(val label: String) {
    A("A"), B("B");

    val other: Deck get() = if (this == A) B else A

    companion object {
        fun fromLabel(s: String): Deck? = entries.firstOrNull { it.label == s }
    }
}

/** Which tap the deck's VU meter shows: pre-fader (post-FX) or post-fader. */
enum class MeterSource(val raw: String) { PRE("pre"), POST("post") }

/** The four per-deck effect families. [raw] is the persisted / session-timeline rawValue. */
enum class Effect(val raw: String, val label: String) {
    COMPRESSOR("compressor", "Comp"),
    REVERB("reverb", "Reverb"),
    FLANGER("flanger", "Flanger"),   // modulation family; kept its legacy rawValue
    FILTER("filter", "Filter");

    companion object {
        fun fromRaw(s: String?): Effect? = entries.firstOrNull { it.raw == s }
    }
}

/** Legacy filter shape toggle (pre-rack persisted field). */
enum class FilterMode(val raw: String, val label: String) {
    LOW_PASS("lowPass", "LP"), HIGH_PASS("highPass", "HP");

    companion object {
        fun fromRaw(s: String?): FilterMode? = entries.firstOrNull { it.raw == s }
    }
}

/** 3-band deck EQ (low shelf / mid peak / high shelf); [bandIndex] is the fixed band order. */
enum class EQBand(val bandIndex: Int, val label: String) {
    LOW(0, "Low"), MID(1, "Mid"), HIGH(2, "High")
}

/** Auto-DJ repeat: ONE replays the on-air track, ALL wraps a drained queue to its head. */
enum class AutoRepeatMode(val raw: String) {
    OFF("off"), ONE("one"), ALL("all");

    companion object {
        fun fromRaw(s: String?): AutoRepeatMode? = entries.firstOrNull { it.raw == s }
    }
}

/** A crate a deck can be loaded from. [id] matches iOS ("pocket:<id>" etc). */
sealed class MixSource {
    abstract val id: String

    data class Pocket(val value: String) : MixSource() { override val id get() = "pocket:$value" }
    data class Playlist(val value: String) : MixSource() { override val id get() = "playlist:$value" }
    data class Setlist(val value: String) : MixSource() { override val id get() = "setlist:$value" }

    companion object {
        /** Inverse of [id]; null for an unknown prefix or empty payload. */
        fun fromId(id: String): MixSource? {
            val i = id.indexOf(':')
            if (i <= 0 || i == id.lastIndex) return null
            val v = id.substring(i + 1)
            return when (id.substring(0, i)) {
                "pocket" -> Pocket(v)
                "playlist" -> Playlist(v)
                "setlist" -> Setlist(v)
                else -> null
            }
        }
    }
}

/**
 * One LOADABLE deck candidate (burned on disk, or streamable). Snapshot metadata is inlined so a
 * picker row reads standalone. [lengthMs] bounds an analog shared-album fallback to its slice.
 */
data class MixLoadable(
    val songId: String,
    val title: String,
    val artist: String,
    val bpm: Double? = null,
    val camelot: String? = null,
    val key: String? = null,
    val albumId: String? = null,
    val lengthMs: Int? = null,
) {
    val id: String get() = songId
}

/**
 * A deck's display payload. Grid fields default null: the engine falls back to catalog [bpm] and
 * a downbeat-at-0 assumption. [beatsMs] is the per-beat measured grid, [downbeatsMs] subset marks bars.
 */
data class LoadedTrack(
    val songId: String,
    val title: String,
    val artist: String,
    val bpm: Double? = null,
    val camelot: String? = null,
    val key: String? = null,
    val albumId: String? = null,
    val gridBpm: Double? = null,
    val firstDownbeatMs: Int? = null,
    val steady: Boolean? = null,
    val beatsMs: List<Int>? = null,
    val downbeatsMs: List<Int>? = null,
) {
    /** BPM used for beat matching: measured grid preferred over catalog. */
    val matchBpm: Double? get() = gridBpm ?: bpm
}

/** One Auto-Mix queue entry: a loadable plus known length; [sourceLabel] = crate provenance. */
data class AutoMixItem(
    val loadable: MixLoadable,
    val durationMs: Int,
    val sourceLabel: String? = null,
)

/** Tunable ranges (iOS MixEngine). */
object MixRanges {
    val rate: ClosedFloatingPointRange<Double> = 0.5..2.0
    val pitch: ClosedFloatingPointRange<Double> = -12.0..12.0
    /** 0..1 attenuation; 1..2 gain boost to +6 dB. */
    val volume: ClosedFloatingPointRange<Double> = 0.0..2.0
    val eq: ClosedFloatingPointRange<Double> = -12.0..12.0
}
