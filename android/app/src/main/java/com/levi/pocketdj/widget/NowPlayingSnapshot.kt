package com.levi.pocketdj.widget

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The Now Playing state the app publishes and the widget reads (iOS `NowPlayingSnapshot`).
 * Key names are exactly iOS's so a snapshot is interchangeable. Every field has a default so a
 * blob from an older build (missing the newer keys) still decodes instead of yielding [EMPTY].
 */
@Serializable
data class NowPlayingSnapshot(
    val isPlaying: Boolean = false,
    val hasContent: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val songId: String? = null,
    /** Bumps each time the cover file is rewritten. */
    val coverVersion: Int = 0,
    val upNext: List<Track> = emptyList(),
    val isFavorite: Boolean = false,
    val appleMusicId: String? = null,
    /** "off" / "all" / "one". */
    val repeatMode: String = "off",
    val shuffleEnabled: Boolean = false,
    /** "" / "accepted" / "rejected". Android has no For You verdicts yet: always "". */
    val recVerdict: String = "",
    /** Empty on Android: the widget shows no thumbs. */
    val recScope: String = "",
    /** Android-only additive key (iOS ignores it): is a FavoriteSeam installed, so ♥ may show. */
    val favoriteAvailable: Boolean = true,
) {
    @Serializable
    data class Track(
        val id: String,
        val songId: String,
        val title: String,
        val artist: String,
    )

    companion object {
        val EMPTY = NowPlayingSnapshot()
    }
}

object NowPlayingSnapshotCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        isLenient = true
    }

    fun encode(snapshot: NowPlayingSnapshot): String = json.encodeToString(NowPlayingSnapshot.serializer(), snapshot)

    /** Corrupt / blank input decodes to [NowPlayingSnapshot.EMPTY], like iOS `read()`. */
    fun decode(text: String?): NowPlayingSnapshot {
        if (text.isNullOrBlank()) return NowPlayingSnapshot.EMPTY
        return runCatching { json.decodeFromString(NowPlayingSnapshot.serializer(), text) }
            .getOrDefault(NowPlayingSnapshot.EMPTY)
    }
}
