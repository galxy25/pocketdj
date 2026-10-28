package com.levi.pocketdj.diag

/**
 * The Now Playing / playback trace (iOS `NPLog` grammar). Lanes are the `[category]` of the
 * DiagLog line so `scripts/deadair-report.py` reads Android logs unchanged.
 */
object NPLog {
    const val PLAYBACK = "playback"
    const val SESSION = "session"
    const val TRANSPORT = "transport"
    const val SUPERVISOR = "supervisor"
    const val DEADAIR = "deadair"
    const val RUNWAY = "runway"
    const val RIPREQ = "ripreq"
    const val ACTION = "action"
    const val NP = "np"
    const val MIX = "mix"
    const val STUDIO = "studio"

    val LANES = listOf(PLAYBACK, SESSION, TRANSPORT, SUPERVISOR, DEADAIR, RUNWAY, RIPREQ, ACTION, NP, MIX, STUDIO)

    /** Where `Log.d("PocketDJ.np", …)` goes; replaced in JVM tests. */
    @Volatile var logd: (tag: String, msg: String) -> Unit = { tag, msg -> runCatching { android.util.Log.d(tag, msg) } }

    @Volatile var processTag = "app"

    /** The `[np]` trace: logcat always, mirrored into DiagLog as an `np` line. */
    fun trace(message: () -> String) {
        val line = "[$processTag] ${message()}"
        logd("PocketDJ.np", line)
        DiagLog.shared?.log(NP, line)
    }

    fun trace(message: String) = trace { message }

    /** A lane line (e.g. `NPLog.lane(NPLog.DEADAIR, "…")`). */
    fun lane(lane: String, message: String) {
        // Mirror to logcat too (verification + adb triage); the DiagLog line stays the durable copy.
        logd("PocketDJ.$lane", message)
        DiagLog.shared?.log(lane, message)
    }
}
