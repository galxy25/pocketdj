package com.levi.pocketdj.mix.nowplaying

import kotlinx.serialization.Serializable

/**
 * NOW PLAYING MIX MODE state (iOS `NPMixModeState` / `NPMixMode`): session state like the Stem Lock; the
 * durable-session key `npMixMode` is `{"enabled":bool}` (iOS shape). Chip words are verbatim from iOS.
 */
@Serializable
data class NpMixModeState(val enabled: Boolean = false)

object NpMixMode {
    /** The Settings "Buffer ahead" picker. */
    val bufferAheadOptions = NpMixSettings.AHEAD_OPTIONS
    const val DEFAULT_BUFFER_AHEAD = NpMixSettings.DEFAULT_BUFFER_AHEAD

    /** The `npmix` lane (song ids only, never titles). */
    fun log(message: String) = com.levi.pocketdj.diag.NPLog.lane("npmix", message)

    /** The status chip on the Now Playing Mix panel header. */
    sealed interface Indicator {
        data object Off : Indicator
        data object Ready : Indicator
        data object ReadyFromAppleMusic : Indicator
        data object Engaged : Indicator
        /** The DSP holds its growing file for bytes; null = size unknown. */
        data class Holding(val fraction: Double?) : Indicator
        /** The current track's local copy is downloading; null = size not known yet. */
        data class Buffering(val fraction: Double?) : Indicator
        data object StemsLoading : Indicator
        data object Ripping : Indicator
        data class RippingEdition(val edition: String) : Indicator
        data class Unavailable(val reason: String) : Indicator
        data object Suspended : Indicator
        data object Waiting : Indicator

        /** The chip's text (null = no chip). */
        val chipText: String?
            get() = when (this) {
                Off -> null
                Ready -> "Ready"
                ReadyFromAppleMusic -> "Ready — tap a control to switch to the local copy"
                Engaged -> "Mixing"
                is Holding -> percent(fraction)
                is Buffering -> percent(fraction)
                StemsLoading -> "Loading stems…"
                Ripping -> "Ripping — mixable next play"
                is RippingEdition -> "Ripping $edition edition — mixable next play"
                is Unavailable -> reason
                Suspended -> "Paused — Mix tab is live"
                Waiting -> "Buffers on ▶"
            }

        /** The controls are usable (the current track is, or can be swapped onto, a local file). */
        val controlsLive: Boolean
            get() = this is Ready || this is ReadyFromAppleMusic || this is Engaged || this is Holding || this is StemsLoading

        /** Stable accessibility / test-tag value of the chip. */
        val a11yValue: String
            get() = when (this) {
                Off -> "off"
                Ready -> "ready"
                ReadyFromAppleMusic -> "readyFromAppleMusic"
                Engaged -> "engaged"
                is Holding -> "holding"
                is Buffering -> "buffering"
                StemsLoading -> "stemsLoading"
                Ripping, is RippingEdition -> "ripping"
                is Unavailable -> "unavailable"
                Suspended -> "suspended"
                Waiting -> "waiting"
            }

        private fun percent(f: Double?): String =
            f?.let { "Buffering ${Math.floor(it * 100).toInt()}%" } ?: "Buffering…"
    }

    /** The inputs the indicator is a pure function of. */
    data class IndicatorInput(
        val enabled: Boolean = false,
        val running: Boolean = false,
        val held: Boolean = false,
        val mixTabLive: Boolean = false,
        val engaged: Boolean = false,
        val stemsLoading: Boolean = false,
        val mixable: Boolean = false,
        val onAppleMusic: Boolean = false,
        val live: Boolean = false,
        val offline: Boolean = false,
        val ripped: Boolean = false,
        val deviceMode: Boolean = false,
        val bufferFraction: Double? = null,
        val buffering: Boolean = false,
        val failed: Boolean = false,
        val storageFull: Boolean = false,
        /** Cellular policy Off: this network adds no Mix Mode downloads. */
        val cellularOff: Boolean = false,
        /** The engaged DSP is holding its growing file for bytes. */
        val dspHolding: Boolean = false,
        /** OWNER ONLY (caller folds the gate in): an Apple-Music-only row has a rip in flight. */
        val ripping: Boolean = false,
        val rippingEdition: String? = null,
    )

    /** THE CHIP. Order matters: off/not running, session-wide states, what the DSP does, what the track is. */
    fun indicator(i: IndicatorInput): Indicator {
        if (!i.enabled || !i.running) return Indicator.Off
        if (i.held) return Indicator.Waiting
        if (i.mixTabLive) return Indicator.Suspended
        if (i.engaged) {
            if (i.dspHolding) return Indicator.Holding(i.bufferFraction)
            return if (i.stemsLoading) Indicator.StemsLoading else Indicator.Engaged
        }
        if (i.mixable) return if (i.onAppleMusic) Indicator.ReadyFromAppleMusic else Indicator.Ready
        // A RIPPED Apple Music row is never "Apple Music only" (iOS 2026-11-02 repro): it falls through to
        // the local-copy states below.
        if (i.onAppleMusic && !i.ripped) {
            if (i.ripping) return i.rippingEdition?.let { Indicator.RippingEdition(it) } ?: Indicator.Ripping
            return Indicator.Unavailable("Apple Music only")
        }
        if (i.live) return Indicator.Unavailable("Live capture")
        if (i.storageFull) return Indicator.Unavailable("Storage full")
        if (i.failed) return Indicator.Unavailable("Download failed")
        if (i.buffering) return Indicator.Buffering(i.bufferFraction)
        if (i.deviceMode) return Indicator.Unavailable("Device mode — downloads only")
        if (i.offline) return Indicator.Unavailable("Offline")
        if (!i.ripped) return Indicator.Unavailable("Not ripped")
        if (i.cellularOff) return Indicator.Unavailable("Cellular — buffering off")
        return Indicator.Buffering(i.bufferFraction) // ripped + allowed: the lane is about to take it
    }

    /** One buffer-strip dot: local / buffering / queued / unavailable. */
    enum class BufferDot(val glyph: String) {
        LOCAL("●"), BUFFERING("◐"), QUEUED("○"), UNAVAILABLE("⨯");

        val raw: String get() = name.lowercase()
    }

    /** One row of the buffer strip under the controls. */
    data class BufferRow(val id: String, val title: String, val dot: BufferDot)
}
