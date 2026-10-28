package com.levi.pocketdj.data.lyrics

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** One recognized word, timed in ms from 0:00 of the analyzed file (iOS `DemuxWord`). */
data class TimedWord(val text: String, val startMs: Long, val endMs: Long)

/** A display line: words grouped by silence gaps (iOS `DemuxLine`). */
data class TimedLine(val words: List<TimedWord>) {
    val startMs: Long get() = words.firstOrNull()?.startMs ?: 0L
    val endMs: Long get() = words.lastOrNull()?.endMs ?: 0L
    val text: String get() = words.joinToString(" ") { it.text }
}

/** The cloud whisper sidecar `rips/lyrics/<id>.json`: `{version, model, lang, durationMs, words:[...]}`. */
data class TimedLyrics(
    val version: Int?,
    val model: String?,
    val lang: String?,
    val durationMs: Long?,
    val words: List<TimedWord>,
) {
    fun lines(gapMs: Long = 1_200, maxWords: Int = 12): List<TimedLine> = TimedLyricsSidecar.lines(words, gapMs, maxWords)
}

object TimedLyricsSidecar {
    /**
     * Decode a sidecar. Malformed words (not an object, missing/blank text, non-numeric or negative
     * times, end before start) are DROPPED individually; the doc fails (null) only when it is not
     * JSON, not an object, or has no `words` array.
     */
    fun decode(raw: String): TimedLyrics? {
        val root = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject ?: return null
        val arr = root["words"] as? JsonArray ?: return null
        val words = arr.mapNotNull { word(it) }
        return TimedLyrics(
            version = prim(root["version"])?.longOrNull?.toInt(),
            model = prim(root["model"])?.takeIf { it.isString }?.contentOrNull,
            lang = prim(root["lang"])?.takeIf { it.isString }?.contentOrNull,
            durationMs = prim(root["durationMs"])?.let { it.longOrNull ?: it.doubleOrNull?.toLong() },
            words = words,
        )
    }

    private fun prim(e: kotlinx.serialization.json.JsonElement?): JsonPrimitive? =
        (e as? JsonPrimitive)?.takeIf { it.contentOrNull != null }

    private fun ms(e: kotlinx.serialization.json.JsonElement?): Long? {
        val p = prim(e) ?: return null
        if (p.isString) return null
        return p.longOrNull ?: p.doubleOrNull?.takeIf { it.isFinite() }?.toLong()
    }

    private fun word(e: kotlinx.serialization.json.JsonElement): TimedWord? {
        val o = e as? JsonObject ?: return null
        val t = prim(o["text"])?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() } ?: return null
        val s = ms(o["startMs"]) ?: return null
        val en = ms(o["endMs"]) ?: return null
        if (s < 0 || en < s) return null
        return TimedWord(t, s, en)
    }

    /** Group words into lines at silence gaps >= [gapMs] or [maxWords] per line (DemuxLine.lines parity). */
    fun lines(words: List<TimedWord>, gapMs: Long = 1_200, maxWords: Int = 12): List<TimedLine> {
        val out = ArrayList<TimedLine>()
        var cur = ArrayList<TimedWord>()
        for (w in words) {
            val last = cur.lastOrNull()
            if (last != null && (w.startMs - last.endMs >= gapMs || cur.size >= maxWords)) {
                out.add(TimedLine(cur)); cur = ArrayList()
            }
            cur.add(w)
        }
        if (cur.isNotEmpty()) out.add(TimedLine(cur))
        return out
    }

    /** Plain text, one line per row - same derivation as fold-cloud-lyrics. */
    fun plainText(doc: TimedLyrics): String = doc.lines().joinToString("\n") { it.text }
}
