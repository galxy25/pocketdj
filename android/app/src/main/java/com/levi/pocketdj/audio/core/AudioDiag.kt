package com.levi.pocketdj.audio.core

import com.levi.pocketdj.diag.NPLog
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Reason-tagged play()/stop() exits: every path out of a transport call records WHY it did or did
 * not produce sound ("no sound" vs "never called" is the iOS lesson). Not for the render thread
 * (it formats strings); call from control paths.
 */
object AudioDiag {
    @Volatile var emit: (String) -> Unit = { NPLog.lane(NPLog.MIX, it) }
    private val counts = ConcurrentHashMap<String, AtomicInteger>()

    fun line(kind: String, owner: String, reason: String, detail: String? = null): String =
        "audio.$kind owner=$owner reason=$reason" + (if (detail != null) " $detail" else "")

    /** A play() exit. [started] false means nothing will be heard and [reason] says why. */
    fun play(owner: String, reason: String, started: Boolean, detail: String? = null) =
        record("play${if (started) "" else ".skip"}", owner, reason, detail)

    fun stop(owner: String, reason: String, detail: String? = null) = record("stop", owner, reason, detail)

    private fun record(kind: String, owner: String, reason: String, detail: String?) {
        counts.getOrPut("$kind/$reason") { AtomicInteger() }.incrementAndGet()
        emit(line(kind, owner, reason, detail))
    }

    fun count(kind: String, reason: String): Int = counts["$kind/$reason"]?.get() ?: 0
    fun snapshot(): Map<String, Int> = counts.mapValues { it.value.get() }
    fun reset() = counts.clear()
}
