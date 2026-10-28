package com.levi.pocketdj.mix.service

import com.levi.pocketdj.diag.NPLog
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The Mix trace (iOS `mixdiag`): every engine diag line (`hb render=1 tapAge sigAge ...`, recover,
 * SILENT-PLAYING, focus) lands in a bounded in-memory ring AND in the `mix` DiagLog lane / logcat.
 * Settings > Debug exports the ring as a plain text file for a drive-test post-mortem.
 */
object MixDiag {
    const val CAPACITY = 2000

    private val lock = Any()
    private val ring = ArrayDeque<String>()

    /** Replaced in JVM tests; production forwards to the DiagLog `mix` lane + logcat. */
    @Volatile var forward: (String) -> Unit = { NPLog.lane(NPLog.MIX, it) }
    @Volatile var clock: () -> Long = System::currentTimeMillis

    /** Record one line (also forwarded to the lane). Safe from any thread. */
    fun log(line: String) {
        val stamped = "${stamp(clock())} [mix] $line"
        synchronized(lock) {
            ring.addLast(stamped)
            while (ring.size > CAPACITY) ring.removeFirst()
        }
        runCatching { forward(line) }
    }

    fun snapshot(): List<String> = synchronized(lock) { ring.toList() }

    fun clear() = synchronized(lock) { ring.clear() }

    /** The export body: a header plus every retained line, oldest first. */
    fun exportText(header: String = ""): String {
        val lines = snapshot()
        return buildString {
            append("PocketDJ mix diag - ${lines.size} lines\n")
            if (header.isNotBlank()) append(header.trimEnd()).append('\n')
            append('\n')
            lines.forEach { append(it).append('\n') }
        }
    }

    /** Write [exportText] to `<dir>/mixdiag-<yyyyMMdd-HHmmss>.txt` and return the file. */
    fun export(dir: File, header: String = ""): File {
        dir.mkdirs()
        val name = "mixdiag-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(clock())) + ".txt"
        return File(dir, name).also { it.writeText(exportText(header)) }
    }

    private fun stamp(ms: Long): String = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date(ms))
}
