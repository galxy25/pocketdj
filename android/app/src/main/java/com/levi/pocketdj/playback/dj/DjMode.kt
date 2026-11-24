package com.levi.pocketdj.playback.dj

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/**
 * Now Playing DJ Mode model (iOS `Playback/DJMode.swift`, docs/design/np-dj-mode.md).
 * Words, defaults and constants are verbatim from iOS; engine packages build on this file.
 */

/**
 * Session state, persisted in the playback snapshot as an optional `djMode`.
 * [planner] is the selector's opaque wave + pocket position (`DJSetPlanner.State`); it is
 * carried as raw JSON so the shape round-trips untouched until the planner package decodes it.
 * Absent until the first plan (and in snapshots written before it existed).
 */
@Serializable
data class DJModeState(
    val enabled: Boolean = false,
    val planner: JsonElement? = null,
)

/**
 * The Settings ▸ Mixing DJ toggles as one value (np-dj-mode §6). Every part defaults ON; the
 * toggles MASK parts of the orchestration off — they never change the shared Mix-tab timings.
 */
data class DJModeSettings(
    /** DJ transitions (crossfade orchestration). Off => every advance is a normal advance. */
    val transitions: Boolean = true,
    /** FX texture sweep during a transition. Off => no texture. */
    val effectSweeps: Boolean = true,
    /** Tempo meet-in-the-middle. Off => rate targets 1. */
    val tempoMatch: Boolean = true,
    /** +-1 key pitch bend. Off => pitch 0. */
    val keyMatch: Boolean = true,
    /** Loudness leveling toward the -14 LUFS target. */
    val volumeLeveling: Boolean = true,
    /** The selector's 10-BPM tempo waves. */
    val tempoWaves: Boolean = true,
    /** The selector's genre / year / collection pockets. */
    val pockets: Boolean = true,
) {
    /** The selector-facing subset (`DJSetPlanner.Options`); key fit follows [keyMatch]. */
    val plannerOptions: PlannerOptions get() = PlannerOptions(tempoWaves = tempoWaves, pockets = pockets, key = keyMatch)

    data class PlannerOptions(val tempoWaves: Boolean, val pockets: Boolean, val key: Boolean)

    companion object {
        val ALL_ON = DJModeSettings()
    }
}

object DjMode {
    /** The shared Mix-tab transition lengths DJ Mode reuses; toggles mask, these never change per mode. */
    data class Timings(
        /** `autoMixLeadSeconds`: a transition may begin with this much (or less) left. */
        val lead: Double = 15.0,
        /** `autoMixFadeSeconds`: the equal-power crossfade. */
        val fade: Double = 3.0,
        /** `mixGlideSeconds`: the glide pre-roll ceiling and post-roll length. */
        val glide: Double = 10.0,
        /** `skipFadeSeconds`: the crossfade a skip mixes over. */
        val skipFade: Double = 15.0,
    )

    /** The FAST skip's crossfade (double-tapped skip, lock-screen / Auto skip). */
    const val FAST_SKIP_FADE_SECONDS: Double = 5.0

    /** What the Now Playing Mix panel's DJ status shows (np-dj-mode §7). */
    sealed interface Indicator {
        data object Off : Indicator
        /** A Mix-tab session is live: DJ Mode waits. */
        data object Suspended : Indicator
        /** A Remote session is attached: DJ Mode waits until it ends. */
        data object SuspendedRemote : Indicator
        /** This song's end won't mix; [why] is a [DjEndReason.chipWords]. */
        data class NoMix(val why: String) : Indicator
        data object Mixing : Indicator
        data object NextReady : Indicator
        /** The next row is still becoming local; byte progress 0..1 when known. */
        data class BufferingNext(val fraction: Double?) : Indicator
        data object LastTrack : Indicator

        val chipText: String?
            get() = when (this) {
                Off -> null
                Suspended -> "DJ — paused while the Mix tab plays"
                SuspendedRemote -> "DJ — paused · SharePlay session"
                is NoMix -> "DJ — $why"
                Mixing -> "DJ — mixing"
                NextReady -> "DJ — next mixes in"
                is BufferingNext -> if (fraction == null) "DJ — buffering next"
                else "DJ — buffering next ${(fraction.coerceIn(0.0, 1.0) * 100).let { Math.round(it) }}%"
                LastTrack -> "DJ — last song"
            }

        /** Re-read on a timer while true (byte progress isn't observable). */
        val isBuffering: Boolean get() = this is BufferingNext
    }
}

/** Why the END of the current row will NOT be a DJ transition (iOS `DJEndReason`). */
enum class DjEndReason(val raw: String, val chipWords: String) {
    TRANSITIONS_OFF("transitions off", "transitions off"),
    REPEATING("repeat", "repeating this song"),
    HALTED("halted", "paused"),
    LAST_SONG("last song", "last song"),
    SET_REPEATS("set repeats", "set repeats"),
    ALBUM_RUN("album run", "album plays through"),
    ALBUM_STARTS("next starts an album side", "album side next"),
    PLAIN("plain row", "this song ends as is");

    companion object {
        /** iOS `djIndicator` mapping of a decline reason to the indicator. */
        fun indicator(reason: DjEndReason): DjMode.Indicator = when (reason) {
            LAST_SONG -> DjMode.Indicator.LastTrack
            SET_REPEATS -> DjMode.Indicator.NoMix("set repeats")
            else -> DjMode.Indicator.NoMix(reason.chipWords)
        }
    }
}
