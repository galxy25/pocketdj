package com.levi.pocketdj.playback

/** One song handed to a game run (iOS `SetlistPlayer.Item` as the games use it). */
data class RunItem(
    val songId: String,
    val title: String,
    val artist: String? = null,
    val lengthMs: Long? = null,
)

/**
 * The narrow audio surface the timed games (Gem Collector, In the Pocket) drive. The audio owner
 * stays the app-scoped sequencer; a game only hands it a queue under a RUN TAG and later asks
 * "is that run still mine?".
 *
 * OWNERSHIP is the load-bearing concept: any other surface (Browse, a setlist, a jukebox accept)
 * may `play()` over the shared queue mid-round. After that [runningTag] names the FOREIGN run, so
 * every read of [position], every skip, append and stop is gated on [ownsRun] and a game never
 * advances, extends or stops somebody else's audio.
 */
interface GameRunPlayer {
    /** Tag of the run currently sounding (any owner), or null when nothing runs. */
    val runningTag: String?

    /** Is any run (ours or foreign) active? */
    val isRunning: Boolean

    /** Cursor inside the CURRENT run's queue (0 when idle). Meaningful only while [ownsRun]. */
    val position: Int

    /** True only while the run tagged [tag] is the one still sounding. */
    fun ownsRun(tag: String): Boolean = isRunning && runningTag == tag

    /** Replace whatever plays with [items] under [tag]; History rows read "Game · [label]". */
    fun playRun(items: List<RunItem>, tag: String, label: String)

    /** Append to the run's tail. Refused (false) unless [ownsRun]; a foreign queue is never extended. */
    fun appendRun(items: List<RunItem>, tag: String): Boolean

    /** Advance the run one row. No-op (false) unless [ownsRun]. */
    fun skipNext(tag: String): Boolean

    /** Stop the run. No-op (false) unless [ownsRun] - foreign audio keeps playing. */
    fun stopRun(tag: String): Boolean

    /**
     * Drop the items whose audio cannot start (the "a card on screen is a song you can hear"
     * contract). Local rips / burns pass instantly; network-resolved sources are probed in chunks.
     * Default: everything resolves.
     */
    suspend fun filterResolvable(items: List<RunItem>): List<RunItem> = items
}
