package com.levi.pocketdj.data.collections.io

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Shared zip + JSON plumbing for the `.pdjcollection` / `.pocketdj.zip` codecs. Mirrors the iOS
 * `Archive` usage: entries written in sorted-name order, deflated, JSON compact with SORTED KEYS
 * (iOS `.sortedKeys`) so the byte shape matches what the PWA/iOS produce.
 */
object ZipIo {
    /** `PK\u0003\u0004` — the local-file-header magic. Content routing keys off this, never the extension. */
    fun isZip(data: ByteArray): Boolean =
        data.size >= 4 && data[0] == 0x50.toByte() && data[1] == 0x4B.toByte() &&
            data[2] == 0x03.toByte() && data[3] == 0x04.toByte()

    /** Write [files] as a deflated zip, entries sorted by name (iOS `files.sorted(by: key)`). */
    fun write(files: Map<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            zos.setLevel(java.util.zip.Deflater.DEFAULT_COMPRESSION)
            for ((name, bytes) in files.toSortedMap()) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    const val MAX_INFLATED_BYTES = 512L * 1024 * 1024

    /** All entries of a zip by path; null when the bytes are not a readable archive. */
    fun read(data: ByteArray): Map<String, ByteArray>? {
        if (!isZip(data)) return null
        return try {
            val out = LinkedHashMap<String, ByteArray>()
            var total = 0L
            ZipInputStream(ByteArrayInputStream(data)).use { zis ->
                while (true) {
                    val e = zis.nextEntry ?: break
                    if (e.isDirectory) continue
                    val b = zis.readBytes()
                    total += b.size
                    if (total > MAX_INFLATED_BYTES) return null // zip-bomb guard
                    out[e.name] = b
                }
            }
            // A zip that starts with a local-file header always has an entry; none ⇒ corrupt (iOS: Archive init throws).
            out.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    /** ISO-8601, seconds precision, `Z` — what Swift's default `ISO8601DateFormatter` emits. */
    fun iso8601(nowMs: Long = System.currentTimeMillis()): String =
        Instant.ofEpochMilli(nowMs).truncatedTo(ChronoUnit.SECONDS).toString()

    /** Recursively sort object keys (iOS `.sortedKeys`). */
    fun sorted(el: JsonElement): JsonElement = when (el) {
        is JsonObject -> JsonObject(el.entries.sortedBy { it.key }.associate { it.key to sorted(it.value) })
        is JsonArray -> JsonArray(el.map(::sorted))
        else -> el
    }

    fun bytes(el: JsonElement, json: Json): ByteArray =
        json.encodeToString(JsonElement.serializer(), sorted(el)).toByteArray(Charsets.UTF_8)
}
