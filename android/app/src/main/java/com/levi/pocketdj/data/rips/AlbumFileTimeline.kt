package com.levi.pocketdj.data.rips

/**
 * The song layout of ONE shared analog album file (a vinyl side ripped as a single `rips/<albumId>.mp3`, every song a
 * `startMs` offset into it). Port of iOS `AlbumFileTimeline`: built from the rips manifest (the starts playback seeks
 * to) plus [SegmentOverrides.Snapshot] (user boundary edits, detected song ends, album membership).
 *
 * A song ends at its DETECTED end plus [FADE_GRACE_MS] (detection ends a quiet fade early), never past the next song's
 * start; a user-edited end is exact.
 */
class AlbumFileTimeline(
    val key: String,
    segments: List<Segment>,
    val exactEndMs: Map<String, Long> = emptyMap(),
    val detectedEndMs: Map<String, Long> = emptyMap(),
) {
    data class Segment(val songId: String, val startMs: Long)

    /** Sorted by (startMs, songId), strictly increasing: a duplicate start keeps the first. */
    val segments: List<Segment> = buildList {
        for (s in segments.sortedWith(compareBy<Segment>({ it.startMs }, { it.songId }))) {
            if (lastOrNull()?.startMs != s.startMs) add(s)
        }
    }

    fun segment(songId: String): Segment? = segments.firstOrNull { it.songId == songId }

    fun next(after: String): Segment? {
        val i = segments.indexOfFirst { it.songId == after }
        return if (i >= 0 && i + 1 < segments.size) segments[i + 1] else null
    }

    fun previous(before: String): Segment? {
        val i = segments.indexOfFirst { it.songId == before }
        return if (i > 0) segments[i - 1] else null
    }

    fun isLast(songId: String): Boolean = segments.lastOrNull()?.songId == songId

    /**
     * Where [songId] ends inside the file: its edited end, else detected end + grace, never past the next song's start
     * (and never at or before its own start, then the next start). null = the last song with no usable end (runs to
     * the file's end) or a song this timeline doesn't hold.
     */
    fun endMs(of: String): Long? {
        val seg = segment(of) ?: return null
        val nextStart = next(of)?.startMs
        val own = exactEndMs[of] ?: detectedEndMs[of]?.let { it + FADE_GRACE_MS }
        if (own == null || own <= seg.startMs) return nextStart
        return nextStart?.let { minOf(own, it) } ?: own
    }

    /** The song playing at absolute file position [ms]; the lead-in groove before the first start belongs to the first. */
    fun segmentAt(ms: Long): Segment? {
        val first = segments.firstOrNull() ?: return null
        return segments.lastOrNull { it.startMs <= ms } ?: first
    }

    companion object {
        const val FADE_GRACE_MS = 15_000L

        /** The timeline of the shared file [songId] plays from, or null when it isn't a slice of a multi-song file. */
        fun forSong(
            songId: String,
            manifest: Map<String, RipManifestEntry>,
            layout: SegmentOverrides.Snapshot = SegmentOverrides.Snapshot.EMPTY,
        ): AlbumFileTimeline? {
            val entry = manifest[songId]?.takeIf { it.startMs != null } ?: return null
            val members = layout.albumOfSong[songId]?.let { layout.albumTracks[it] }
            return forKey(entry.key, manifest, layout, members)
        }

        /**
         * The timeline of the file at manifest [key] (null when no song sits in it). [members] (the album's track list)
         * drops stale manifest entries still pointing at the file under an id the album no longer has.
         */
        fun forKey(
            key: String,
            manifest: Map<String, RipManifestEntry>,
            layout: SegmentOverrides.Snapshot = SegmentOverrides.Snapshot.EMPTY,
            members: Set<String>? = null,
        ): AlbumFileTimeline? {
            val segs = ArrayList<Segment>()
            for ((id, e) in manifest) {
                if (e.key != key) continue
                if (members != null && id !in members) continue
                (layout.startMs[id] ?: e.startMs)?.let { segs.add(Segment(id, it)) }
            }
            if (segs.isEmpty()) return null
            return AlbumFileTimeline(key, segs, layout.endMs, layout.detectedEndMs)
        }
    }
}
