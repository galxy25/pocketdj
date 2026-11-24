package com.levi.pocketdj.playback.album

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.sequencer.AdvanceAttempt
import com.levi.pocketdj.playback.sequencer.AdvanceCause
import com.levi.pocketdj.playback.sequencer.AdvanceInterceptor
import com.levi.pocketdj.playback.sequencer.PlayerPort
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SetlistSequencer
import com.levi.pocketdj.playback.sequencer.StartAttempt
import com.levi.pocketdj.playback.sequencer.StartInterceptor
import com.levi.pocketdj.playback.sequencer.StartPath
import com.levi.pocketdj.playback.sequencer.TransitionCause
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The album run's engine glue (iOS `glideInSameFile` / `jumpInSameFile` / `retargetInPlace`): while ONE engine item
 * plays a whole vinyl side, the deck moves from song to song WITHOUT a load.
 *
 *  - **Glide** ([AdvanceInterceptor]): the natural boundary at the next song's start (armed by the engine through
 *    [PlayerPort.armBoundary]) ends the current row; when the next queued row is the record's next song the sequencer
 *    advances without a load and the same item is retargeted (a gap longer than [AlbumRun.GLIDE_TOLERANCE_MS] is
 *    skipped with an in-place seek FIRST).
 *  - **Skip** ([StartInterceptor]): a listener ⏭/⏮ onto another song of the loaded side seeks inside the file; a skip
 *    while paused starts playback.
 *
 * Either declines (the normal reload start runs) whenever [declines] says another owner has the audio (a DSP/Mix
 * engagement, Stem Lock, a held deck, Apple Music, a live capture, the DJ tail deck) or the engine holds no run item.
 */
class AlbumRunPlayer(
    private val seq: SetlistSequencer,
    private val port: PlayerPort,
    private val timelines: AlbumTimelineSource,
    private val scope: CoroutineScope,
    /** Another owner has the audio (DSP engaged / Stem Lock / Apple Music / live / DJ tail): never move in place. */
    private val declines: () -> Boolean = { false },
    private val log: (String) -> Unit = { NPLog.lane(NPLog.PLAYBACK, it.removePrefix("[playback] ")) },
) : AdvanceInterceptor, StartInterceptor {
    override val priority: Int = 100

    private fun usable(): Boolean = seq.isRunning && !seq.isHeldForResume && !declines()

    // ---- natural boundary -> glide ----------------------------------------------------------------------------

    override fun onNaturalEnd(attempt: AdvanceAttempt): Boolean {
        if (!usable()) return false
        val next = attempt.next ?: return false
        if (next.cleanOnlySkip) return false
        val st = port.albumFileState() ?: return false
        val fromBase = SongVariant.baseId(attempt.from.id)
        // The loaded run item must be the row that just ended (a stale boundary of another item never glides).
        if (SongVariant.baseId(st.mediaId) != fromBase) return false
        val tl = timelines.timeline(fromBase) ?: return false
        val cur = tl.segment(fromBase) ?: return false
        val nextSeg = tl.next(fromBase) ?: return false
        if (SongVariant.baseId(next.id) != nextSeg.songId) return false
        val step = AlbumRun.glideStep(st.fileMs, cur.startMs, nextSeg.startMs) ?: return false
        if (!seq.advanceWithoutLoad(AdvanceCause.NATURAL_END, StartPath.ALBUM_GLIDE, "glide", rendering = true)) {
            // Halted by the auto-advance gate / cascade breaker: the deck holds the row, so the side must not play on.
            scope.launch { runCatching { port.pause() } }
            return true
        }
        val queue = seq.state.value.queue
        val pos = seq.currentIndex()
        val item = queue.getOrNull(pos) ?: return true
        // Seek BEFORE re-arming the boundary, so a tick still carrying the old position can't fire the new song's end.
        if (step is AlbumRun.GlideStep.SeekThenRetarget) port.seekInFile(step.toFileMs)
        arm(queue, pos, tl, nextSeg.startMs, st.clipStartMs)
        log("[playback] album glide to=${item.id} index=${pos + 1}/${queue.size} file=${nextSeg.startMs}")
        scope.launch {
            // The cursor already moved: a failed retarget must not leave the engine item tagged with the old song.
            if (!retarget(item, startPlayback = false)) {
                log("[playback] album glide retarget failed - reloading song=${item.id}")
                port.armBoundary("", null, 0L)
                seq.reloadCurrentAfterFailedRetarget()
            }
        }
        return true
    }

    // ---- listener ⏭ / ⏮ -> in-place jump ----------------------------------------------------------------------

    override suspend fun tryClaim(attempt: StartAttempt): Boolean {
        // Only a fresh listener-driven start: never a resume, a cue, a repeat pass, or a natural advance.
        if (!attempt.fresh || attempt.resumeAtMs != null || attempt.inPlace) return false
        val cause = seq.lastTransitionCause
        if (cause != TransitionCause.USER && cause != TransitionCause.REMOTE) return false
        if (attempt.item.cleanOnlySkip || !usable()) return false
        val st = port.albumFileState() ?: return false
        val tl = timelines.timeline(attempt.item.id) ?: return false
        val loadedTl = timelines.timeline(st.mediaId) ?: return false
        if (loadedTl.key != tl.key) return false
        val target = AlbumRun.jumpTargetMs(attempt.item.id, tl, st.clipStartMs) ?: return false
        // Seek FIRST: the target's end boundary must never meet the old position.
        if (!port.seekInFile(target)) return false
        val queue = seq.state.value.queue
        arm(queue, attempt.index, tl, target, st.clipStartMs)
        val retargeted = retarget(attempt.item, startPlayback = !st.playing)
        if (!retargeted) return false
        if (!seq.completeClaimedStart(attempt.gen, StartPath.ALBUM_GLIDE, backend = "album-skip")) return true // superseded: its own start re-arms
        log("[playback] album jump in-place to=${attempt.item.id} index=${attempt.index + 1}/${queue.size} file=$target")
        // The engine is already sounding (or ▶ was just issued and its first-audio event will close the window).
        if (st.playing) seq.onFirstAudio(attempt.item.id, "album-skip")
        return true
    }

    // ---- shared ---------------------------------------------------------------------------------------------

    /** Arm the boundary for the row at [pos], now starting at [startMs]: next song's start in a run, its own end else. */
    private fun arm(queue: List<com.levi.pocketdj.playback.sequencer.QueueItem>, pos: Int, tl: com.levi.pocketdj.data.rips.AlbumFileTimeline, startMs: Long, clipStartMs: Long) {
        val item = queue.getOrNull(pos) ?: return
        val end = AlbumRun.boundaryMs(queue, pos, tl, startMs, seq.effectiveRepeatMode == RepeatMode.ONE, item.lengthMs)
        port.armBoundary(item.id, end, clipStartMs)
    }

    private suspend fun retarget(item: com.levi.pocketdj.playback.sequencer.QueueItem, startPlayback: Boolean): Boolean = try {
        port.retargetInPlace(item, startPlayback)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        log("[playback] album retarget failed song=${item.id} err=${e.message}")
        false
    }
}
