package com.levi.pocketdj.playback.sequencer

/**
 * Whole-session repeat (iOS `RepeatMode`). Sticky across runs; the persisted token
 * (`off|all|one`) is shared with the durable session snapshot.
 */
enum class RepeatMode(val token: String) {
    OFF("off"),
    ALL("all"),
    ONE("one");

    /** The Now Playing repeat button cycle: off -> all -> one -> off. */
    val next: RepeatMode
        get() = when (this) {
            OFF -> ALL
            ALL -> ONE
            ONE -> OFF
        }

    companion object {
        fun fromToken(token: String?): RepeatMode = entries.firstOrNull { it.token == token } ?: OFF
    }
}
