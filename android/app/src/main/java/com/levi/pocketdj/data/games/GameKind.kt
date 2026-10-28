package com.levi.pocketdj.data.games

/**
 * The games the scoreboard knows about. [token] values are PERSISTED (scoreboard document,
 * uploaded rec puzzle events, a11y ids) and shared with iOS: never rename. [label] is the only
 * user-facing string and may change freely ("collectorsPuzzle" is shown as "Gem Collector").
 */
enum class GameKind(val token: String, val label: String) {
    CollectorsPuzzle("collectorsPuzzle", "Gem Collector"),
    MusicWithFriends("musicWithFriends", "Music with Friends"),

    /** score = songs of the round played through (0..4); `detail["outcome"]` is pocket|broke|abandoned. */
    InThePocket("inThePocket", "In the Pocket"),
    ;

    companion object {
        fun fromToken(token: String?): GameKind? = entries.firstOrNull { it.token == token }
    }
}
