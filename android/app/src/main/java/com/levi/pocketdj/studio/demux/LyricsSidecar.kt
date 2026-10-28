package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Feature gate for the Demuxer lyrics. On-device recognition over music is too sparse to ship (iOS 2026-07-18), so the
 * only shipped engine is the CLOUD whisper sidecar; the panel shows when [lyricsEnabled] (dev seam) OR the source has a
 * cloud transcript. Android has no on-device recognizer, so the gate only decides panel visibility.
 */
object DemuxFeatures {
    @Volatile var lyricsEnabled: Boolean = false

    /** Panel visibility: gate on, or a cloud sidecar exists / already landed (the offline case). */
    fun lyricsPanelVisible(hasCloudSidecar: Boolean, doc: DemuxDocument?, gate: Boolean = lyricsEnabled): Boolean =
        gate || hasCloudSidecar || (doc?.transcriptEngine == "cloud" && !doc.words.isNullOrEmpty())
}

/**
 * The timed-lyrics sidecar the cloud worker ships (`rips/lyrics/<songId>.json`, transcribe-one.py): whisper words over
 * the vocals stem, ms from the song's 0:00. Decoded LOSSY per word (iOS TimedLyricsSidecar): ONE malformed word drops
 * that word only, never the whole transcript (an all-or-nothing decode would land "instrumental" as done+cloud and the
 * fetched-once dedup would never retry it).
 */
data class TimedLyricsSidecar(
    val version: Int? = null,
    val model: String? = null,
    val lang: String? = null,
    val durationMs: Int? = null,
    val words: List<DemuxWord> = emptyList(),
) {
    companion object {
        /** Null when [text] is not a JSON object (truncated body, HTML error page): the caller falls back / retries. */
        fun parse(text: String): TimedLyricsSidecar? {
            val root = runCatching { PdjJson.lenient.parseToJsonElement(text) }.getOrNull() as? JsonObject ?: return null
            val words = (root["words"] as? JsonArray)?.mapNotNull { word(it) }.orEmpty()
            return TimedLyricsSidecar(
                version = int(root["version"]), model = str(root["model"]), lang = str(root["lang"]),
                durationMs = int(root["durationMs"]), words = words,
            )
        }

        private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        private fun int(e: JsonElement?): Int? = (e as? JsonPrimitive)?.takeIf { !it.isString }?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }
        private fun word(e: JsonElement): DemuxWord? {
            val o = e as? JsonObject ?: return null
            val text = str(o["text"]) ?: return null
            val s = int(o["startMs"]) ?: return null
            val en = int(o["endMs"]) ?: return null
            return DemuxWord(text, s, en)
        }
    }
}

/** A display line: words grouped by silence gaps (karaoke rows). */
data class DemuxLine(val words: List<DemuxWord>) {
    val startMs: Int get() = words.firstOrNull()?.startMs ?: 0
    val endMs: Int get() = words.lastOrNull()?.endMs ?: 0
    val text: String get() = words.joinToString(" ") { it.text }

    companion object {
        /** Group at silence gaps >= [gapMs] (verse-ish phrasing), capping a line at [maxWords] so a rap verse still wraps. */
        fun lines(words: List<DemuxWord>, gapMs: Int = 1_200, maxWords: Int = 12): List<DemuxLine> {
            val lines = ArrayList<DemuxLine>()
            var current = ArrayList<DemuxWord>()
            for (w in words) {
                val last = current.lastOrNull()
                if (last != null && (w.startMs - last.endMs >= gapMs || current.size >= maxWords)) {
                    lines.add(DemuxLine(current)); current = ArrayList()
                }
                current.add(w)
            }
            if (current.isNotEmpty()) lines.add(DemuxLine(current))
            return lines
        }

        /** Index of the line the playhead is in (last line starting at/before [nowMs]), or -1. */
        fun currentIndex(lines: List<DemuxLine>, nowMs: Int): Int = lines.indexOfLast { it.startMs <= nowMs }

        /** Karaoke fill: a word is "sung" once its start is at/before [nowMs] (only the current line fills). */
        fun isCurrent(line: DemuxLine, nowMs: Int): Boolean = line.startMs <= nowMs && nowMs < line.endMs + 800
    }
}

/** What the lyrics section shows for a source (a pure projection so the wording/branching is testable). */
sealed class LyricsPanelState {
    object Hidden : LyricsPanelState()
    object Fetching : LyricsPanelState()
    /** Cloud lyrics landed. */
    data class Lyrics(val lines: List<DemuxLine>, val diag: String?) : LyricsPanelState()
    /** Transcribed but wordless (an instrumental). */
    object Instrumental : LyricsPanelState()
    /** Sidecar exists but has not been fetched (or the fetch failed): offer a retry. */
    object Retry : LyricsPanelState()

    companion object {
        fun of(visible: Boolean, fetching: Boolean, doc: DemuxDocument?, hasCloudSidecar: Boolean): LyricsPanelState = when {
            !visible -> Hidden
            fetching -> Fetching
            doc != null && doc.transcriptStatus == DemuxArtifactStatus.DONE && doc.words.isNotEmpty() ->
                Lyrics(DemuxLine.lines(doc.words), doc.transcriptDiag)
            doc != null && doc.transcriptStatus == DemuxArtifactStatus.DONE -> Instrumental
            hasCloudSidecar -> Retry
            else -> Hidden
        }
    }
}

/** Landing a cloud transcript WHOLESALE on a document (iOS DemuxStore.applyCloudTranscript). */
fun DemuxDocument.withCloudTranscript(sidecar: TimedLyricsSidecar): DemuxDocument = copy(
    words = sidecar.words.sortedBy { it.startMs },
    transcriptStatus = DemuxArtifactStatus.DONE,   // empty words = instrumental; the panel says so
    transcriptCoveredMs = maxOf(durationMs, transcriptCoveredMs ?: 0),
    transcriptEngine = "cloud",
    transcriptDiag = sidecar.model?.let { "Transcribed in the cloud ($it)." },
)
