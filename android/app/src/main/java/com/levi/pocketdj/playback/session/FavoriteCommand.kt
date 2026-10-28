package com.levi.pocketdj.playback.session

import android.os.Bundle
import androidx.media3.session.CommandButton
import androidx.media3.session.SessionCommand

/**
 * The notification/lock-screen heart. Installed by the favorites package; null seam => no button.
 */
interface FavoriteSeam {
    /** False while the Mix engine owns audio (no heart then). */
    val isAvailable: Boolean
    fun isFavorite(songId: String): Boolean
    fun toggle(songId: String)
}

object FavoriteCommand {
    /** Installed by the favorites package (null => no ♥ anywhere). */
    @Volatile var seam: FavoriteSeam? = null

    const val ACTION = "pdj.favorite"
    val sessionCommand: SessionCommand by lazy { SessionCommand(ACTION, Bundle.EMPTY) }

    /** Should a heart show for [songId]? Pure: seam installed, available, a song is current. */
    fun visible(seam: FavoriteSeam?, songId: String?): Boolean =
        seam != null && seam.isAvailable && !songId.isNullOrEmpty()

    fun filled(seam: FavoriteSeam?, songId: String?): Boolean =
        visible(seam, songId) && seam!!.isFavorite(songId!!)

    /** Toggle the CURRENT song; returns whether anything happened. */
    fun press(seam: FavoriteSeam?, songId: String?): Boolean {
        if (!visible(seam, songId)) return false
        seam!!.toggle(songId!!)
        return true
    }

    fun button(filled: Boolean): CommandButton =
        CommandButton.Builder(if (filled) CommandButton.ICON_HEART_FILLED else CommandButton.ICON_HEART_UNFILLED)
            .setDisplayName(if (filled) "Unfavorite" else "Favorite")
            .setSessionCommand(sessionCommand)
            .build()

    /** The custom layout for the session: empty when no heart should show. */
    fun layout(seam: FavoriteSeam?, songId: String?): List<CommandButton> =
        if (visible(seam, songId)) listOf(button(filled(seam, songId))) else emptyList()
}
