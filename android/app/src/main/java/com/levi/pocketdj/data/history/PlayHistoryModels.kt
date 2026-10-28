package com.levi.pocketdj.data.history

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Where a play came from — the persisted `source` tokens of the play-history
 * document (specs/history.md §2). Raw values are the PERSISTED tokens shared
 * with iOS — never rename. Decoding an unknown future token coerces to
 * [BROWSER] (coerceInputValues + the property default on [PlayEvent.source])
 * instead of failing the whole document.
 */
@Serializable
enum class PlaySource {
    @SerialName("browser")
    BROWSER,

    @SerialName("playlist")
    PLAYLIST,

    @SerialName("pocket")
    POCKET,

    @SerialName("album")
    ALBUM,

    @SerialName("setlist")
    SETLIST,

    @SerialName("mix")
    MIX,

    @SerialName("artist")
    ARTIST,

    /** Played by a game (Gem Collector, ...); the game's own name rides in `contextName`. */
    @SerialName("game")
    GAME,
    ;

    /** Human label (specs/history.md §2, iOS `PlayHistoryStore.swift:31-42`). */
    val label: String
        get() = when (this) {
            BROWSER -> "Browser"
            PLAYLIST -> "Playlist"
            POCKET -> "Pocket"
            ALBUM -> "Album"
            SETLIST -> "Set list"
            MIX -> "Mix"
            ARTIST -> "Artist"
            GAME -> "Game"
        }

    /** The persisted raw token. */
    val token: String
        get() = when (this) {
            BROWSER -> "browser"
            PLAYLIST -> "playlist"
            POCKET -> "pocket"
            ALBUM -> "album"
            SETLIST -> "setlist"
            MIX -> "mix"
            ARTIST -> "artist"
            GAME -> "game"
        }

    companion object {
        /** Core `PlayContext.source` string token → enum; unknown → [BROWSER]. */
        fun fromToken(token: String?): PlaySource =
            entries.firstOrNull { it.token == token } ?: BROWSER
    }
}

/**
 * One play — one timeline row (specs/history.md §2). `id` is the stable merge/
 * dedupe key; `playedAt` is epoch **ms** as a double (iOS wire compatibility);
 * `contextName`/`title`/`artist` are snapshots resolved at record time so
 * history stays readable after a song leaves the catalog.
 */
@Serializable
data class PlayEvent(
    val id: String,
    val songId: String,
    val playedAt: Double,
    val source: PlaySource = PlaySource.BROWSER,
    val contextId: String? = null,
    val contextName: String? = null,
    val title: String? = null,
    val artist: String? = null,
    /** Install that recorded the play (null = legacy, this device's own). */
    val originInstallId: String? = null,
    /** Advanced away from under 50 % played. Only ever flips false(null) -> true. */
    val wasSkipped: Boolean? = null,
    /** High-water played fraction 0...1; max-merged; null = unknown. */
    val listenedFraction: Double? = null,
    /** Minutes from UTC at play time. */
    val tzOffsetMin: Int? = null,
    /** Navigable origin collection (playlist/pocket id) of a set_now_playing run. */
    val originCollectionId: String? = null,
    /** Settled location context (opaque place/trip ids only). Write-once, own plays only; null = unresolved. */
    val listeningContext: com.levi.pocketdj.data.pockets.ListeningContextTag? = null,
    /** True when a car-projection session was connected at record time; null = unknown / not applicable. */
    val carPlay: Boolean? = null,
) {
    /** DERIVED, never stored: skipped wins, then fraction >= 0.5 completed else partial. */
    val outcome: PlayOutcome
        get() {
            if (wasSkipped == true) return PlayOutcome.SKIPPED
            val f = listenedFraction ?: return PlayOutcome.UNKNOWN
            return if (f >= 0.5) PlayOutcome.COMPLETED else PlayOutcome.PARTIAL
        }
}

enum class PlayOutcome { COMPLETED, SKIPPED, PARTIAL, UNKNOWN }

/**
 * The on-disk document `pocketdj-play-history.json` (specs/history.md §2).
 * Additive-optional iron law: every field has a default and unknown keys are
 * ignored, so a later field addition never wipes a saved log. `installId` is
 * this install's stable identity for the future cross-profile merge.
 */
@Serializable
data class PlayHistoryDocument(
    val schemaVersion: Int = PLAY_HISTORY_SCHEMA_VERSION,
    val installId: String = "",
    /** Oldest → newest; insertion order == chronological for live plays. */
    val events: List<PlayEvent> = emptyList(),
)

const val PLAY_HISTORY_SCHEMA_VERSION = 1
