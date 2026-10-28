package com.levi.pocketdj.playback

/** Scriptable [GameRunPlayer]: models the shared audio owner so ownership races can be staged. */
class FakeGameRunPlayer : GameRunPlayer {
    override var runningTag: String? = null
    override var isRunning: Boolean = false
    override var position: Int = 0

    val plays = mutableListOf<Pair<String, List<RunItem>>>()
    val appended = mutableListOf<RunItem>()
    var skips = 0
    var stops = 0

    /** Song ids [filterResolvable] drops. */
    val unresolvable = mutableSetOf<String>()

    override fun playRun(items: List<RunItem>, tag: String, label: String) {
        plays += tag to items
        runningTag = tag
        isRunning = true
        position = 0
    }

    override fun appendRun(items: List<RunItem>, tag: String): Boolean {
        if (!ownsRun(tag)) return false
        appended += items
        return true
    }

    override fun skipNext(tag: String): Boolean {
        if (!ownsRun(tag)) return false
        position++
        skips++
        return true
    }

    override fun stopRun(tag: String): Boolean {
        if (!ownsRun(tag)) return false
        stops++
        isRunning = false
        runningTag = null
        position = 0
        return true
    }

    override suspend fun filterResolvable(items: List<RunItem>): List<RunItem> =
        items.filter { it.songId !in unresolvable }

    // ---- staging helpers ----
    /** Another surface plays over the queue. */
    fun foreignPlay(tag: String? = "set_foreign") {
        runningTag = tag
        isRunning = true
        position = 0
    }

    /** The run ran out / every source failed: nothing is playing. */
    fun goSilent() {
        isRunning = false
        runningTag = null
        position = 0
    }
}
