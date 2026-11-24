package com.levi.pocketdj.playback.album

/**
 * The pure half of the engine-side album boundary (see [AlbumBoundaryArmer]): which song's end is armed at which file
 * position, and whether a given engine observation (current media id, item clip start, item playhead) has reached it.
 *
 * One boundary at a time; arming REPLACES it (a new token), so a stale message / poll of a superseded arm can never fire
 * the new song's end ("seek BEFORE re-arming"). A boundary fires at most once.
 */
class BoundaryGate {
    data class Armed(val songId: String, val fileMs: Long, val clipStartMs: Long, val token: Long) {
        /** The boundary in ITEM time (what a player message position and `currentPosition` use). */
        val itemMs: Long get() = fileMs - clipStartMs
    }

    var armed: Armed? = null
        private set
    private var token = 0L

    /** Arm [songId]'s end at absolute [fileMs]; null disarms. Returns the new arm (null when disarmed or unreachable). */
    fun arm(songId: String, fileMs: Long?, clipStartMs: Long): Armed? {
        token++
        armed = if (fileMs == null || fileMs < clipStartMs) null else Armed(songId, fileMs, clipStartMs, token)
        return armed
    }

    fun disarm() { arm("", null, 0L) }

    /** Is the engine currently holding the item this arm belongs to (the retarget's replace may not have landed yet)? */
    fun matches(a: Armed, mediaId: String?, itemClipStartMs: Long?): Boolean =
        mediaId == a.songId && itemClipStartMs == a.clipStartMs

    /** Poll fallback: the engine item matches the arm and its playhead has reached the boundary. */
    fun reached(mediaId: String?, itemClipStartMs: Long?, itemPositionMs: Long): Boolean {
        val a = armed ?: return false
        return matches(a, mediaId, itemClipStartMs) && itemPositionMs >= a.itemMs
    }

    /** A message / poll fired for [forToken]: returns the armed boundary (and consumes it) only if it is still current. */
    fun consume(forToken: Long): Armed? {
        val a = armed ?: return null
        if (a.token != forToken) return null
        armed = null
        return a
    }
}
