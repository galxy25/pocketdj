package com.levi.pocketdj.playback.session

import com.levi.pocketdj.diag.NPLog

/** `[transport] rc cmd=<..> engine=<exo|am> verdict=<..>` - one line per remote command. */
object TransportLog {
    object Cmd {
        const val PLAY = "play"
        const val PAUSE = "pause"
        const val TOGGLE = "toggle"
        const val NEXT = "next"
        const val PREV = "prev"
        const val REPEAT = "repeat"
        const val SHUFFLE = "shuffle"
        const val FAVORITE = "favorite"
    }

    object Verdict {
        const val HANDLED = "handled"
        const val REFUSED_IDLE = "refused-idle"
        const val REFUSED_MIC = "refused-mic-capture"
        const val NOT_RUNNING = "not-running"
        const val NOT_OWNER = "not-owner"
        const val REPLAY_IDLE = "replay-idle"
        const val REKICK_BUFFERING = "rekick-buffering"
        fun idlePlay(kind: IdlePlayVerdict) = "onIdlePlay→${kind.token}"
    }

    fun format(cmd: String, engine: String, verdict: String): String =
        "rc cmd=$cmd engine=$engine verdict=$verdict"

    @Volatile var sink: (String) -> Unit = { NPLog.lane(NPLog.TRANSPORT, it) }

    fun rc(cmd: String, engine: String, verdict: String) = sink(format(cmd, engine, verdict))
}
