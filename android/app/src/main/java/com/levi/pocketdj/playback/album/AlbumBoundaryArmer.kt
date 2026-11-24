package com.levi.pocketdj.playback.album

import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlaybackContract

/**
 * Service-side album boundary (design D6): arms the end of the CURRENT song of a run item with
 * `ExoPlayer.createMessage(..).setPosition(..)` - exact, and delivered even when the app is in Doze - with a 250 ms poll
 * as the fallback (a message is dropped by a seek past it and can race a retarget's replace). Both paths go through
 * [BoundaryGate], so a boundary fires at most once and a superseded arm never fires.
 *
 * Not a clip end: a clip change forces a re-prepare, and the run is ONE item played through.
 */
class AlbumBoundaryArmer(
    private val player: ExoPlayer,
    private val onBoundary: (songId: String) -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private val gate = BoundaryGate()
    private var scheduledToken = -1L
    private var scheduled: androidx.media3.exoplayer.PlayerMessage? = null
    @Volatile private var expectedRetarget: String? = null
    @Volatile private var expectedAtMs = 0L

    private val poll = object : Runnable {
        override fun run() {
            val a = gate.armed ?: return
            val item = player.currentMediaItem
            val clip = clipStartOf(item)
            // Self-heal: the arm may have been made before its item (or the retarget's replace) landed.
            if (scheduledToken != a.token && gate.matches(a, item?.mediaId, clip)) schedule(a)
            if (gate.reached(item?.mediaId, clip, player.currentPosition)) fire(a.token)
            if (gate.armed != null) handler.postDelayed(this, POLL_MS)
        }
    }

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = rescheduleIfNeeded()
        override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) = rescheduleIfNeeded()
    }

    init { player.addListener(listener) }

    /** Arm [songId]'s end at [fileMs] (absolute in the shared file); null disarms. Main thread. */
    fun arm(songId: String, fileMs: Long?, clipStartMs: Long) {
        cancelMessage()
        val a = gate.arm(songId, fileMs, clipStartMs)
        handler.removeCallbacks(poll)
        if (a == null) return
        NPLog.lane(NPLog.PLAYBACK, "album arm song=$songId fileMs=$fileMs clip=$clipStartMs")
        rescheduleIfNeeded()
        handler.postDelayed(poll, POLL_MS)
    }

    /** The controller is about to retitle the current item to [songId] in place: its transition is not a new play. */
    fun expectRetarget(songId: String) {
        expectedRetarget = songId
        expectedAtMs = android.os.SystemClock.elapsedRealtime()
    }

    /** True once per [expectRetarget]: the service's History recorder skips that transition (the sequencer records the play). */
    fun consumeRetarget(songId: String): Boolean {
        val fresh = android.os.SystemClock.elapsedRealtime() - expectedAtMs <= RETARGET_WINDOW_MS
        if (expectedRetarget != songId || !fresh) return false
        expectedRetarget = null
        return true
    }

    fun release() {
        handler.removeCallbacks(poll)
        cancelMessage()
        gate.disarm()
        player.removeListener(listener)
    }

    private fun rescheduleIfNeeded() {
        val a = gate.armed ?: return
        if (scheduledToken == a.token) return
        val item = player.currentMediaItem
        if (gate.matches(a, item?.mediaId, clipStartOf(item))) schedule(a)
    }

    private fun schedule(a: BoundaryGate.Armed) {
        cancelMessage()
        scheduledToken = a.token
        val token = a.token
        scheduled = player.createMessage { _, _ -> fire(token) }
            .setLooper(handler.looper)
            .setPosition(player.currentMediaItemIndex, a.itemMs)
            .setDeleteAfterDelivery(true)
            .send()
    }

    private fun cancelMessage() {
        scheduled?.cancel()
        scheduled = null
        scheduledToken = -1L
    }

    private fun fire(token: Long) {
        val a = gate.consume(token) ?: return
        handler.removeCallbacks(poll)
        cancelMessage()
        NPLog.lane(NPLog.PLAYBACK, "album boundary song=${a.songId} fileMs=${a.fileMs}")
        onBoundary(a.songId)
    }

    private fun clipStartOf(item: MediaItem?): Long? =
        item?.requestMetadata?.extras?.getLong(PlaybackContract.EXTRA_CLIP_START_MS, -1L)?.takeIf { it >= 0 }

    private companion object {
        const val POLL_MS = 250L
        const val RETARGET_WINDOW_MS = 3_000L
    }
}
