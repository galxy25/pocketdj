package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.rips.RipManifestEntry
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject

/**
 * The `.txt` sidecar — mirrors burn-setlist.mjs `buildSidecar` HEADER ORDER
 * (BPM · Key+Camelot · Sentiment · Album). Prefers the analyzed manifest values over the
 * catalog. The trailing Raw JSON embeds {song, album, manifestEntry} so the prose header and
 * the JSON agree, and so `parseSidecarForAdoption` can recover a ledger entry.
 */
object BurnSidecar {
    private const val DASH = "—"

    fun build(
        songId: String,
        fallback: BurnSong,
        song: IndexSong?,
        album: IndexAlbum?,
        entry: RipManifestEntry?,
    ): String {
        val artist = song?.artist ?: fallback.artist
        val title = song?.name ?: fallback.title
        val bpm = entry?.bpm ?: song?.bpm
        val key = entry?.musicalKey ?: song?.key
        val camelot = entry?.camelot ?: song?.camelot
        val sentiment = (song?.sentimentKeywords ?: emptyList()).joinToString(", ")

        fun dash(s: String?) = if (!s.isNullOrEmpty()) s else DASH
        val lines = ArrayList<String>()
        lines += "$artist — $title"
        lines += "=".repeat(60)
        lines += ""
        lines += "BPM:        ${bpm?.toString() ?: DASH}"
        lines += "Key:        ${dash(key)}  (Camelot ${dash(camelot)})"
        lines += "Sentiment:  ${sentiment.ifEmpty { DASH }}"
        lines += "Album:      ${dash(album?.name)}"
        lines += ""
        lines += "-- Song metadata --"
        if (song != null) songFields(song).forEach { (k, v) -> lines += "  $k: $v" } else lines += "  (song not found in index)"
        lines += ""
        lines += "-- Album metadata --"
        if (album != null) albumFields(album).forEach { (k, v) -> lines += "  $k: $v" } else lines += "  (album not found in index)"
        lines += ""
        lines += "-- Raw JSON --"
        lines += rawJson(song, album, entry)
        lines += ""
        return lines.joinToString("\n")
    }

    private fun d(v: String?) = if (!v.isNullOrEmpty()) v else DASH

    private fun songFields(s: IndexSong): List<Pair<String, String>> = listOf(
        "id" to s.id,
        "artist" to d(s.artist),
        "name" to d(s.name),
        "albumId" to d(s.albumId),
        "trackNumber" to (s.trackNumber?.toString() ?: DASH),
        "year" to (s.year?.toString() ?: DASH),
        "sentimentKeywords" to (s.sentimentKeywords ?: emptyList()).joinToString(", ").ifEmpty { DASH },
        "explicit" to (s.explicit?.toString() ?: DASH),
        "bpm" to (s.bpm?.toString() ?: DASH),
        "key" to d(s.key),
        "camelot" to d(s.camelot),
        "length" to (s.length?.toString() ?: DASH),
        "fileType" to d(s.fileType),
        "appleMusicId" to d(s.appleMusicId),
    )

    private fun albumFields(a: IndexAlbum): List<Pair<String, String>> = listOf(
        "id" to a.id,
        "artist" to d(a.artist),
        "name" to d(a.name),
        "genre" to d(a.genre),
        "year" to (a.year?.toString() ?: DASH),
        "country" to d(a.country),
        "fileType" to d(a.fileType),
        "trackList" to "[${a.trackList.size} entries]",
        "audioTracks" to "[${(a.audioTracks ?: emptyList()).size} entries]",
    )

    // ---- Raw JSON (Foundation `.prettyPrinted + .sortedKeys` shape) ------------------------

    private fun rawJson(song: IndexSong?, album: IndexAlbum?, entry: RipManifestEntry?): String {
        val obj = LinkedHashMap<String, JsonElement>()
        if (song != null) obj["song"] = songJson(song)
        if (album != null) obj["album"] = albumJson(album)
        if (entry != null) obj["manifestEntry"] = entryJson(entry)
        return StringBuilder().also { writePretty(JsonObject(obj), it, 0) }.toString()
    }

    private fun obj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
        JsonObject(pairs.filter { it.second != null && it.second !is JsonNull }.associate { it.first to it.second!! })

    private fun s(v: String?): JsonElement? = v?.let { JsonPrimitive(it) }
    private fun n(v: Number?): JsonElement? = v?.let { JsonPrimitive(it) }
    private fun b(v: Boolean?): JsonElement? = v?.let { JsonPrimitive(it) }

    private fun songJson(x: IndexSong) = obj(
        "id" to s(x.id), "artist" to s(x.artist), "name" to s(x.name), "albumId" to s(x.albumId),
        "trackNumber" to n(x.trackNumber), "year" to n(x.year),
        "sentimentKeywords" to x.sentimentKeywords?.let { l -> JsonArray(l.map { JsonPrimitive(it) }) },
        "explicit" to b(x.explicit), "bpm" to n(x.bpm), "key" to s(x.key), "camelot" to s(x.camelot),
        "length" to n(x.length), "fileType" to s(x.fileType), "lyricsStatus" to s(x.lyricsStatus),
        "appleMusicId" to s(x.appleMusicId),
    )

    private fun albumJson(x: IndexAlbum) = obj(
        "id" to s(x.id), "artist" to s(x.artist), "name" to s(x.name),
        "trackList" to JsonArray(x.trackList.map { JsonPrimitive(it) }),
        "trackCount" to n(x.trackList.size),
        "genre" to s(x.genre), "year" to n(x.year), "country" to s(x.country), "fileType" to s(x.fileType),
        "audioDurationSec" to n(x.audioDurationSec), "audioTrackCount" to n((x.audioTracks ?: emptyList()).size),
    )

    private fun entryJson(e: RipManifestEntry) = obj(
        "key" to s(e.key), "ext" to s(e.ext), "source" to s(e.source), "startMs" to n(e.startMs),
        "durationMs" to n(e.durationMs), "bpm" to n(e.bpm), "musicalKey" to s(e.musicalKey),
        "camelot" to s(e.camelot), "waveform" to s(e.waveform), "analyzed" to b(e.analyzed),
    )

    private fun writePretty(e: JsonElement, out: StringBuilder, depth: Int) {
        val pad = "  ".repeat(depth + 1)
        val close = "  ".repeat(depth)
        when (e) {
            is JsonObject -> {
                if (e.isEmpty()) { out.append("{\n\n").append(close).append("}"); return }
                out.append("{\n")
                val keys = e.keys.sorted()
                keys.forEachIndexed { i, k ->
                    out.append(pad).append(quote(k)).append(" : ")
                    writePretty(e.getValue(k), out, depth + 1)
                    out.append(if (i < keys.lastIndex) ",\n" else "\n")
                }
                out.append(close).append("}")
            }
            is JsonArray -> {
                if (e.isEmpty()) { out.append("[\n\n").append(close).append("]"); return }
                out.append("[\n")
                e.forEachIndexed { i, v ->
                    out.append(pad)
                    writePretty(v, out, depth + 1)
                    out.append(if (i < e.lastIndex) ",\n" else "\n")
                }
                out.append(close).append("]")
            }
            is JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                e.isString -> out.append(quote(e.content))
                e.booleanOrNull != null -> out.append(e.content)
                else -> {
                    val dv = e.doubleOrNull
                    val txt = e.content
                    // Foundation prints integral doubles without the ".0".
                    if (dv != null && txt.contains('.') && dv == Math.floor(dv) && Math.abs(dv) < 1e15) {
                        out.append(dv.toLong().toString())
                    } else out.append(txt)
                }
            }
        }
    }

    private fun quote(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '/' -> sb.append("\\/") // Foundation escapes slashes
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c.code < 0x20 -> sb.append(String.format("\\u%04X", c.code))
            else -> sb.append(c)
        }
        return sb.append('"').toString()
    }

    // ---- Adoption --------------------------------------------------------------------------

    /** What orphan adoption recovers from one sidecar (header parse only). */
    data class Adopted(val artist: String?, val title: String?, val entry: RipManifestEntry?)

    fun parseForAdoption(text: String): Adopted {
        var artist: String? = null
        var title: String? = null
        val first = text.substringBefore('\n')
        val sep = first.indexOf(" — ")
        if (sep >= 0) {
            val a = first.substring(0, sep).trim()
            val t = first.substring(sep + 3).trim()
            artist = if (a.isEmpty() || a == DASH) null else a
            title = if (t.isEmpty() || t == DASH) null else t
        }
        var entry: RipManifestEntry? = null
        val marker = text.indexOf("-- Raw JSON --")
        if (marker >= 0) {
            val jsonText = text.substring(marker + "-- Raw JSON --".length).trim()
            entry = runCatching {
                val o = PdjJson.lenient.parseToJsonElement(jsonText).jsonObject
                val me = o["manifestEntry"]?.jsonObject ?: return@runCatching null
                PdjJson.lenient.decodeFromJsonElement(RipManifestEntry.serializer(), me)
            }.getOrNull()
        }
        return Adopted(artist, title, entry)
    }
}
