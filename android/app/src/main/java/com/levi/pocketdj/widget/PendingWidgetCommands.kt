package com.levi.pocketdj.widget

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** A widget tap that reached a process with no live graph. */
@Serializable
data class WidgetCommand(
    val kind: Kind,
    /** The song the user SAW (snapshot songId): a queued ♥ targets it, not whatever plays at drain time. */
    val songId: String? = null,
    val appleMusicId: String? = null,
    /** Desired end state: "1"/"0" for favorite and shuffle, the repeat token for repeat. */
    val value: String? = null,
    val atMs: Long = 0,
) {
    @Serializable
    enum class Kind(val transport: Boolean) {
        PLAY_PAUSE(true), NEXT(true), PREVIOUS(true), REPEAT(true), SHUFFLE(true),
        FAVORITE(false), VERDICT_ACCEPT(false), VERDICT_REJECT(false),
    }
}

/**
 * Durable FIFO of widget commands (cap 32, oldest trimmed). Transport-class entries older than
 * [TRANSPORT_TTL_MS] are discarded at drain (a stale ⏭ must not skip a song the user never
 * meant); ♥ and verdicts never expire. A corrupt file reads as empty.
 */
class PendingWidgetCommands(
    private val file: File,
    private val clockMs: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(WidgetCommand.serializer())

    fun enqueue(cmd: WidgetCommand) = synchronized(lock) {
        val stamped = if (cmd.atMs == 0L) cmd.copy(atMs = clockMs()) else cmd
        val all = (load() + stamped).let { if (it.size > CAP) it.takeLast(CAP) else it }
        save(all)
    }

    fun size(): Int = synchronized(lock) { load().size }

    /** Returns the still-valid commands in enqueue order and empties the queue. */
    fun drain(): List<WidgetCommand> = synchronized(lock) {
        val now = clockMs()
        val all = load()
        if (all.isNotEmpty() || file.exists()) runCatching { file.delete() }
        all.filter { !it.kind.transport || now - it.atMs <= TRANSPORT_TTL_MS }
    }

    private fun load(): List<WidgetCommand> =
        runCatching { json.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyList())

    private fun save(list: List<WidgetCommand>) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(json.encodeToString(serializer, list))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }

    companion object {
        const val CAP = 32
        const val TRANSPORT_TTL_MS = 20_000L
    }
}
