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
     * Decode a sidecar (iOS `RipsStore.TimedLyricsSidecar` parity). Fails (null) when not JSON, not an
     * object, or a present header field is wrong-typed (version/durationMs not integral, model/lang not
     * string). A missing/non-array `words` yields an empty word list. Words that fail the type checks
     * (not an object, text not a string, times not integral numbers) are dropped individually; blank
     * text, negative times and end<start are kept, as on iOS.
     */
    fun decode(raw: String): TimedLyrics? {
        val root = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject ?: return null
        val arr = root["words"] as? JsonArray
        val words = arr?.mapNotNull { word(it) } ?: emptyList()
        val version = optInt(root["version"]) ?: return null
        val duration = optInt(root["durationMs"]) ?: return null
        val model = optString(root["model"]) ?: return null
        val lang = optString(root["lang"]) ?: return null
        return TimedLyrics(
            version = version.value?.toInt(),
            model = model.value,
            lang = lang.value,
            durationMs = duration.value,
            words = words,
        )
    }

    private class Opt<T>(val value: T?)

    private fun optInt(e: kotlinx.serialization.json.JsonElement?): Opt<Long>? {
        if (e == null || e is kotlinx.serialization.json.JsonNull) return Opt(null)
        return ms(e)?.let { Opt(it) }
    }

    private fun optString(e: kotlinx.serialization.json.JsonElement?): Opt<String>? {
        if (e == null || e is kotlinx.serialization.json.JsonNull) return Opt(null)
        val p = e as? JsonPrimitive ?: return null
        return if (p.isString) Opt(p.content) else null
    }

    private fun prim(e: kotlinx.serialization.json.JsonElement?): JsonPrimitive? =
        (e as? JsonPrimitive)?.takeIf { it.contentOrNull != null }

    /** Integral JSON number (30 or 30.0) -> Long; fractional / non-number -> null (Swift Int decode). */
    private fun ms(e: kotlinx.serialization.json.JsonElement?): Long? {
        val p = prim(e) ?: return null
        if (p.isString) return null
        p.longOrNull?.let { return it }
        val d = p.doubleOrNull ?: return null
        return if (d.isFinite() && d == Math.floor(d)) d.toLong() else null
    }

    private fun word(e: kotlinx.serialization.json.JsonElement): TimedWord? {
        val o = e as? JsonObject ?: return null
        val t = prim(o["text"])?.takeIf { it.isString }?.content ?: return null
        val s = ms(o["startMs"]) ?: return null
        val en = ms(o["endMs"]) ?: return null
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
