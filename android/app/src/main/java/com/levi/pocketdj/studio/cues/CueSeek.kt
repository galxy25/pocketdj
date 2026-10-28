package com.levi.pocketdj.studio.cues

import com.levi.pocketdj.data.catalog.IndexSong

/**
 * Pure rules for the Studio Cues tab and its playback plumbing (iOS StudioCuesView routing ladder).
 *
 * The load-bearing invariant: the cue rides SEPARATELY from the song's true start. For a shared analog
 * album file the song begins at `entry.startMs` inside the album mp3; the cue is song-relative. The
 * absolute file position is `startMs + cue`, but the end boundary stays `startMs + durationMs`.
 * Pre-adding the cue into the start would push the boundary into the next song on the side.
 * (On Android the ExoPlayer clip does the offset: player positions are clip-relative, so the controller
 * seeks to [CuePlan.clipRelativeMs]; [CuePlan.absoluteMs] is what a raw-file player would seek to.)
 */
object CueSeek {
    /** Nudge step of the long-press menu (iOS: +-100 ms per tap). */
    const val NUDGE_MS = 100

    /** Where a cue lands. [durationMs] null = unknown (no clamp). */
    data class CuePlan(
        val songStartMs: Long,
        val durationMs: Long?,
        /** The cue clamped into the song: 0..durationMs. */
        val cueMs: Long,
        /** Seek for a clip-relative player (ExoPlayer with the song's ClippingConfiguration). */
        val clipRelativeMs: Long,
        /** Seek into the raw file (`songStartMs + cueMs`). */
        val absoluteMs: Long,
        /** Where the song ends in the raw file (`songStartMs + durationMs`); null when unknown. */
        val endBoundaryMs: Long?,
    )

    /**
     * [startMs] is the entry's offset inside a shared analog file (null/0 for digital or a per-song cut);
     * a cue past the song end is clamped to the end so a stale cue never seeks into the next song.
     */
    fun plan(startMs: Long?, durationMs: Long?, cueMs: Int): CuePlan {
        val start = (startMs ?: 0L).coerceAtLeast(0L)
        val dur = durationMs?.takeIf { it > 0 }
        val cue = cueMs.toLong().coerceAtLeast(0L).let { if (dur != null) it.coerceAtMost(dur) else it }
        return CuePlan(start, dur, cue, cue, start + cue, dur?.let { start + it })
    }

    /** Why a filled slot can or cannot play right now. */
    enum class Availability { PLAYABLE, STILL_RIPPING }

    /**
     * Burned files always seek; otherwise a finished rip in the manifest (durable mp3) or an Apple Music id
     * (play-then-seek). A song with neither resolves to a rip-in-flight/live HLS stream, which cannot seek:
     * its filled slots show a disabled "still ripping" state instead of silently playing from 0:00.
     */
    fun availability(isBurned: Boolean, hasDurableRip: Boolean, hasAppleMusicId: Boolean, amFullTrack: Boolean): Availability =
        if (isBurned || hasDurableRip || (hasAppleMusicId && amFullTrack)) Availability.PLAYABLE else Availability.STILL_RIPPING

    /** "m:ss.mmm" — cues are nudged in 100 ms steps, so sub-second digits are the feedback. */
    fun stamp(ms: Int): String {
        val c = ms.coerceAtLeast(0)
        val s = c / 1000
        return "${s / 60}:${(s % 60).toString().padStart(2, '0')}.${(c % 1000).toString().padStart(3, '0')}"
    }

    /** Fraction 0..1 of a cue/playhead along the timeline (denominator at least 1). */
    fun fraction(positionMs: Int, durationMs: Int): Float =
        (positionMs.toFloat() / maxOf(durationMs, 1)).coerceIn(0f, 1f)

    /** Position under a touch at fraction [f] of the timeline. */
    fun positionAt(f: Float, durationMs: Int): Int = (f.coerceIn(0f, 1f) * durationMs).toInt()

    /** The picker: tokens over title+artist; burned first then artist/title; empty query = cued + burned only. */
    fun search(
        songs: Collection<IndexSong>,
        query: String,
        isBurned: (String) -> Boolean,
        cuedSongIds: Set<String>,
        limit: Int = 120,
    ): List<IndexSong> {
        val toks = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val filtered = if (toks.isEmpty()) songs.filter { it.id in cuedSongIds || isBurned(it.id) }
        else songs.filter { s -> val hay = (s.name + " " + s.artist).lowercase(); toks.all { hay.contains(it) } }
        return filtered.sortedWith(
            compareByDescending<IndexSong> { isBurned(it.id) }
                .thenBy { it.artist.lowercase() }
                .thenBy { it.name.lowercase() },
        ).take(limit)
    }

    /** A window of the album-side waveform PNG, as fractions of its width. */
    data class Crop(val start: Float, val width: Float)

    /**
     * The analog album PNG covers the WHOLE shared file; this song is `[startMs, startMs+durationMs]` of it.
     * The denominator is the file's length: the max of the last song end across every manifest entry sharing
     * the file ([siblingEndsMs]) and the catalog album's measured [albumDurationSec]; a window never overruns
     * its own file. Null when the window isn't derivable (falls back to a plain bar).
     */
    fun analogCrop(startMs: Long?, durationMs: Long?, siblingEndsMs: List<Long>, albumDurationSec: Double?): Crop? {
        if (startMs == null || durationMs == null || durationMs <= 0) return null
        var total = siblingEndsMs.maxOrNull() ?: 0L
        if (albumDurationSec != null && albumDurationSec > 0) total = maxOf(total, (albumDurationSec * 1000).toLong())
        total = maxOf(total, startMs + durationMs)
        if (total <= 0) return null
        return Crop(startMs.toFloat() / total, durationMs.toFloat() / total)
    }
}
