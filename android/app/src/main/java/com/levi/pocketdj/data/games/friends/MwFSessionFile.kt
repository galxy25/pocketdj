package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.builtins.ListSerializer

/** Atomic JSON list of [MwFSessionEntry] (`pocketdj-mwf-sessions.json`, iOS field names). */
class MwFSessionFile(private val file: File) {
    private val serializer = ListSerializer(MwFSessionEntry.serializer())

    fun load(): List<MwFSessionEntry> {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull() ?: return emptyList()
        return runCatching { PdjJson.lenient.decodeFromString(serializer, text) }.getOrDefault(emptyList())
    }

    fun save(list: List<MwFSessionEntry>) {
        val bytes = runCatching { PdjJson.lenient.encodeToString(serializer, list).toByteArray(Charsets.UTF_8) }
            .getOrNull() ?: return
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) {
                file.writeBytes(bytes)
                tmp.delete()
            }
        }
    }

    fun delete() {
        runCatching { file.delete() }
    }

    companion object {
        const val FILE_NAME = "pocketdj-mwf-sessions.json"
    }
}
