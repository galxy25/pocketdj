package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first

/** iOS `NPMixCellularPolicy`: what Mix Mode buffers on a cellular path. [raw] is the persisted value. */
enum class NpMixCellularPolicy(val raw: String) {
    /** Nothing beyond what Stem Lock already fetches. */
    OFF("off"),
    /** The current row + the NEXT song (default). */
    NEXT_SONG("nextSong"),
    /** Like Wi-Fi: the whole window, stems included. */
    FULL("full");

    companion object {
        /** An unknown raw value (a newer build's) reads as the default. */
        fun fromRaw(s: String?): NpMixCellularPolicy = entries.firstOrNull { it.raw == s } ?: NEXT_SONG
    }
}

/**
 * Now Playing Mix Mode buffer settings, an immutable snapshot with iOS-verbatim keys/defaults
 * (iOS `SettingsStore` npMix* fields). [bufferTtlHours] is the EFFECTIVE TTL: null = "Keep" (new
 * buffer assets are pinned at creation). A change applies only to assets buffered AFTER it.
 */
data class NpMixSettings(
    val bufferTtlHours: Double? = DEFAULT_TTL_HOURS,
    val bufferCapGb: Double = DEFAULT_CAP_GB,
    val bufferAhead: Int = DEFAULT_BUFFER_AHEAD,
    val cellular: NpMixCellularPolicy = NpMixCellularPolicy.NEXT_SONG,
    val modeDefaultOn: Boolean = false,
    val keepPickedFolderBuffers: Boolean = false,
) {
    /** Temporary-footprint cap in bytes (decimal GB, like the soft cap). */
    val bufferCapBytes: Long get() = (bufferCapGb * BYTES_PER_GB).toLong()

    companion object {
        const val DEFAULT_TTL_HOURS = 48.0
        const val DEFAULT_CAP_GB = 2.0
        const val DEFAULT_BUFFER_AHEAD = 3
        /** The stored TTL value meaning "Keep (treat as downloads)". */
        const val KEEP_SENTINEL = 0.0
        const val BYTES_PER_GB = 1_000_000_000.0

        /** Settings > Storage TTL picker: 6 h / 12 h / 24 h / 48 h / 3 days / 7 days / Keep. */
        val TTL_OPTIONS = listOf(6.0, 12.0, 24.0, 48.0, 72.0, 168.0, KEEP_SENTINEL)
        val CAP_OPTIONS = listOf(0.5, 1.0, 2.0, 5.0, 10.0, 20.0)
        val AHEAD_OPTIONS = listOf(1, 3, 5, 10)
    }
}

/** Persisted DataStore keys. Names are FROZEN (equal the iOS field names). */
object NpMixSettingsKeys {
    /** Absent = 48 h (the default); 0 = Keep. */
    val BUFFER_TTL_HOURS = PrefKey.double("npMixBufferTTLHours", NpMixSettings.DEFAULT_TTL_HOURS)
    val BUFFER_CAP_GB = PrefKey.double("npMixBufferCapGB", NpMixSettings.DEFAULT_CAP_GB)
    val BUFFER_AHEAD = PrefKey.int("npMixBufferAhead", NpMixSettings.DEFAULT_BUFFER_AHEAD)
    val CELLULAR = PrefKey.string("npMixCellular", NpMixCellularPolicy.NEXT_SONG.raw)
    val MODE_DEFAULT_ON = PrefKey.boolean("npMixModeDefaultOn", false)
    val KEEP_PICKED_FOLDER_BUFFERS = PrefKey.boolean("npMixKeepPickedFolderBuffers", false)
    /** Epoch ms of the last temporary-asset sweep START (0 = never; stamped first). */
    val LAST_TEMPORARY_SWEEP_AT = PrefKey.double("lastTemporarySweepAt", 0.0)
}

/** Read-side normalisation (iOS `npMixBuffer*Effective*`): a corrupt value reads as the default. */
object NpMixSettingsRules {
    /** null = Keep. Corrupt (negative / NaN / infinite) reads as the default, never Keep or "expire now". */
    fun effectiveTtlHours(raw: Double?): Double? {
        if (raw == null) return NpMixSettings.DEFAULT_TTL_HOURS
        if (raw == NpMixSettings.KEEP_SENTINEL) return null
        return if (raw > 0 && raw.isFinite()) raw else NpMixSettings.DEFAULT_TTL_HOURS
    }

    fun effectiveCapGb(raw: Double?): Double =
        raw?.takeIf { it > 0 && it.isFinite() } ?: NpMixSettings.DEFAULT_CAP_GB

    /** 1..10 rows ahead; non-positive reads as the default. */
    fun effectiveAhead(raw: Int?): Int {
        val v = raw?.takeIf { it > 0 } ?: return NpMixSettings.DEFAULT_BUFFER_AHEAD
        return minOf(v, NpMixSettings.AHEAD_OPTIONS.max())
    }

    fun normalize(
        ttlRaw: Double?, capRaw: Double?, aheadRaw: Int?, cellularRaw: String?,
        modeDefaultOn: Boolean, keepPickedFolderBuffers: Boolean,
    ) = NpMixSettings(
        bufferTtlHours = effectiveTtlHours(ttlRaw),
        bufferCapGb = effectiveCapGb(capRaw),
        bufferAhead = effectiveAhead(aheadRaw),
        cellular = NpMixCellularPolicy.fromRaw(cellularRaw),
        modeDefaultOn = modeDefaultOn,
        keepPickedFolderBuffers = keepPickedFolderBuffers,
    )
}

fun AppSettingsStore.npMixSettingsFlow(): Flow<NpMixSettings> = combine(
    listOf<Flow<Any>>(
        flow(NpMixSettingsKeys.BUFFER_TTL_HOURS), flow(NpMixSettingsKeys.BUFFER_CAP_GB),
        flow(NpMixSettingsKeys.BUFFER_AHEAD), flow(NpMixSettingsKeys.CELLULAR),
        flow(NpMixSettingsKeys.MODE_DEFAULT_ON), flow(NpMixSettingsKeys.KEEP_PICKED_FOLDER_BUFFERS),
    ),
) { v ->
    NpMixSettingsRules.normalize(
        ttlRaw = v[0] as Double, capRaw = v[1] as Double, aheadRaw = v[2] as Int,
        cellularRaw = v[3] as String, modeDefaultOn = v[4] as Boolean, keepPickedFolderBuffers = v[5] as Boolean,
    )
}.distinctUntilChanged()

suspend fun AppSettingsStore.npMixSettings(): NpMixSettings = npMixSettingsFlow().first()

suspend fun AppSettingsStore.setNpMixBufferTtlHours(v: Double) = set(NpMixSettingsKeys.BUFFER_TTL_HOURS, v)
suspend fun AppSettingsStore.setNpMixBufferCapGb(v: Double) = set(NpMixSettingsKeys.BUFFER_CAP_GB, v)
suspend fun AppSettingsStore.setNpMixBufferAhead(v: Int) = set(NpMixSettingsKeys.BUFFER_AHEAD, v)
suspend fun AppSettingsStore.setNpMixCellular(p: NpMixCellularPolicy) = set(NpMixSettingsKeys.CELLULAR, p.raw)
suspend fun AppSettingsStore.setNpMixModeDefaultOn(on: Boolean) = set(NpMixSettingsKeys.MODE_DEFAULT_ON, on)
suspend fun AppSettingsStore.setNpMixKeepPickedFolderBuffers(on: Boolean) = set(NpMixSettingsKeys.KEEP_PICKED_FOLDER_BUFFERS, on)
suspend fun AppSettingsStore.stampTemporarySweepAt(epochMs: Double) = set(NpMixSettingsKeys.LAST_TEMPORARY_SWEEP_AT, epochMs)
