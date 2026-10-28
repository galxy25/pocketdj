package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * iOS `SongTransfer`: the song-id list that travels on the clipboard / drag, with a capped
 * human-readable text fallback so external apps paste something useful.
 */
@Serializable
data class SongTransfer(val songIds: List<String>, val text: String? = null) {
    /** What an external app pastes: the text fallback, else the raw ids one per line. */
    val plainTextExport: String get() = text ?: songIds.joinToString("\n")

    fun toJson(): String = JSON.encodeToString(this)

    companion object {
        /** Cap the plain-text fallback so a 96k-song select-all still copies instantly. */
        const val TEXT_LINE_CAP = 200

        /** iOS `SongPasteboard.maxPayloadBytes`: refuse to decode anything bigger. */
        const val MAX_PAYLOAD_BYTES = 8 * 1024 * 1024

        /** Clipboard label / MIME-ish tag shared with iOS (`com.pocketdj.songlist`). */
        const val CLIP_LABEL = "com.pocketdj.songlist"

        private val JSON = Json { ignoreUnknownKeys = true }

        fun make(ids: List<String>, songsById: Map<String, IndexSong>): SongTransfer {
            val lines = ids.asSequence().take(TEXT_LINE_CAP)
                .mapNotNull { songsById[it]?.let { s -> "${s.artist} — ${s.name}" } }
                .toList()
            val extra = ids.size - minOf(ids.size, TEXT_LINE_CAP)
            val text = if (lines.isEmpty()) null
            else lines.joinToString("\n") + if (extra > 0) "\n…and $extra more" else ""
            return SongTransfer(ids, text)
        }

        /** Byte-capped decode boundary (null on oversize / malformed). */
        fun decode(json: String): SongTransfer? {
            if (json.toByteArray(Charsets.UTF_8).size > MAX_PAYLOAD_BYTES) return null
            return runCatching { JSON.decodeFromString<SongTransfer>(json) }.getOrNull()
        }
    }
}

/**
 * iOS `SongDrop`: drop/paste validation, pure for unit tests. Keeps ids the current catalog can
 * resolve (or studio ids the caller's lookup backs), order-preserving, deduped and BOUNDED -
 * the payload crosses a process boundary (any app can author the clip), so per-id length and
 * total count are capped before anything touches the persisted document.
 */
object SongDrop {
    /** Above any real select-all (full catalog ~96k), below OOM/document-bloat scale. */
    const val MAX_IDS = 100_000

    /** Above any real namespaced id (sng_/amrec_/smp_ + uuid), below junk-string scale. */
    const val MAX_ID_LENGTH = 128

    fun acceptableIds(items: List<SongTransfer>, resolves: (String) -> Boolean): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>()
        outer@ for (t in items) for (id in t.songIds) {
            if (out.size >= MAX_IDS) break@outer
            if (id.length > MAX_ID_LENGTH || !seen.add(id) || !resolves(id)) continue
            out.add(id)
        }
        return out
    }

    /**
     * Drop/paste onto a collection: ONE addSongs call (default chapter, whole-collection dedupe),
     * only when something acceptable survives. True when anything was actually added - a
     * self-drop of already-present songs adds nothing and writes nothing.
     */
    fun accept(
        items: List<SongTransfer>,
        resolves: (String) -> Boolean,
        add: (List<String>) -> Int,
    ): Boolean {
        val ids = acceptableIds(items, resolves)
        if (ids.isEmpty()) return false
        return add(ids) > 0
    }
}
