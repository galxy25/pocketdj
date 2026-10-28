package com.levi.pocketdj.diag

import java.io.File

/**
 * Settings ▸ Debug capture: while ON every mirrored line is buffered in memory; turning it OFF
 * saves the buffer as a session file. OFF ⇒ nothing is buffered.
 */
class CaptureSessions(private val dir: File, private val clock: () -> Long = System::currentTimeMillis) {
    private val lock = Any()
    private val buffer = ArrayList<String>()
    @Volatile var active: Boolean = false
        private set

    fun start() = synchronized(lock) { buffer.clear(); active = true }

    /** Stop and persist; returns the saved file (null if nothing was captured). */
    fun stop(): File? = synchronized(lock) {
        active = false
        if (buffer.isEmpty()) return null
        dir.mkdirs()
        val f = File(dir, "capture-${clock()}.txt")
        f.writeText(buffer.joinToString("\n") + "\n")
        buffer.clear()
        f
    }

    fun append(line: String) {
        if (!active) return
        synchronized(lock) {
            if (active) {
                buffer.add(line)
                if (buffer.size > MAX_LINES) buffer.subList(0, buffer.size - MAX_LINES).clear()
            }
        }
    }

    companion object {
        /** Ring cap so a long capture can't grow without bound (newest lines kept). */
        const val MAX_LINES = 20_000
    }

    fun sessions(): List<File> =
        (dir.listFiles { f -> f.name.startsWith("capture-") }?.toList() ?: emptyList()).sortedByDescending { it.name }

    fun delete(f: File): Boolean = f.parentFile == dir && f.delete()
}
