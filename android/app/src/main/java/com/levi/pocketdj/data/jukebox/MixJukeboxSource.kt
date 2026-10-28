package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable

/**
 * The slice of the running Mix the jukebox needs - a seam so payload composition and placement are
 * JVM-testable without audio (production adapter: `MixGraph`, over `AutoDj` + `AutoQueueSeams`).
 */
interface MixJukeboxPort {
    /** An auto mix is running (iOS `mix.isRunning || mix.autoMixing`, narrowed to the auto-queue owner). */
    val autoMixing: Boolean
    val onAir: OnAir?
    /** The auto queue's not-yet-reached tail (guests' "up next"). */
    val upcoming: List<MixLoadable>
    /** Consumed head, newest first. */
    val played: List<MixLoadable>
    fun insert(item: AutoMixItem, action: JukeboxDecisionAction)

    data class OnAir(
        val songId: String,
        val title: String,
        val artist: String,
        val positionMs: Long?,
        val durationMs: Long?,
        val buffering: Boolean,
    )
}

/** What the Mix reports to the jukebox loop: the on-air deck track + the auto queue tail. */
data class MixJukeboxSnapshot(
    val songId: String,
    val title: String,
    val artist: String,
    val durationMs: Long?,
    val positionMs: Long?,
    val buffering: Boolean,
    val upNext: List<JukeboxStatePayload.Track>,
)

/**
 * Jukebox <-> Mix seam (iOS `JukeboxStore.stateSnapshot` Mix branch + `acceptIntoMix` +
 * `drainPendingMixInserts`). While an auto mix rides a broadcast the SETLIST is the shared concept:
 * guests see the on-air deck track and the queue's tail, and accepted requests are INSERTED into the auto
 * queue (never before the first uncommitted slot - in-mix actions take precedence). A Mix deck can only
 * load a burned (or streamable) file, so an unloadable match kicks the burn and PARKS the insert until
 * the file lands (15 min deadline); a mix that ended meanwhile lets the insert go.
 *
 * Hear mode is unaffected: the repository still gates `streamUrl` on a public rip.
 */
class MixJukeboxSource(
    private val port: () -> MixJukeboxPort?,
    /** A deck can load [songId] right now (burned, or ripped + streamable). */
    private val isLoadable: (String) -> Boolean,
    /** Kick the rip+burn pipeline for [song]; failures are the pipeline's to report. */
    private val requestBurn: suspend (IndexSong) -> Unit = {},
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private class Pending(val loadable: MixLoadable, val durationMs: Int, val action: JukeboxDecisionAction, val deadlineMs: Long)

    private val pending = ArrayList<Pending>()

    /** The Mix owns the audio and is auto-mixing with a track on air. */
    val isLive: Boolean get() = port()?.let { it.autoMixing && it.onAir != null } == true

    /** Null unless [isLive]. */
    fun snapshot(): MixJukeboxSnapshot? {
        val p = port() ?: return null
        if (!p.autoMixing) return null
        val on = p.onAir ?: return null
        return MixJukeboxSnapshot(
            songId = on.songId, title = on.title, artist = on.artist,
            durationMs = on.durationMs, positionMs = on.positionMs, buffering = on.buffering,
            upNext = p.upcoming.map { JukeboxStatePayload.Track(it.title, it.artist) },
        )
    }

    /** Titles/artists of the consumed head, newest first (feeds the played-history mirror when wanted). */
    fun playedTracks(): List<JukeboxStatePayload.Track> =
        port()?.takeIf { it.autoMixing }?.played.orEmpty().map { JukeboxStatePayload.Track(it.title, it.artist) }

    /**
     * Offer an accepted request to the Mix. false = the Mix is not auto-mixing (caller falls back to the
     * ExoPlayer queue). true = handled: inserted now, or parked behind a burn.
     */
    suspend fun place(song: IndexSong, action: JukeboxDecisionAction): Boolean {
        val p = port() ?: return false
        if (!p.autoMixing || !action.isPlacement) return false
        val loadable = MixLoadable(
            songId = song.id, title = song.name, artist = song.artist, bpm = song.bpm,
            camelot = song.camelot, key = song.key, albumId = song.albumId, lengthMs = song.length?.toInt(),
        )
        val duration = loadable.lengthMs ?: FALLBACK_LENGTH_MS
        if (isLoadable(song.id)) {
            p.insert(AutoMixItem(loadable, duration), action)
        } else {
            synchronized(pending) { pending += Pending(loadable, duration, action, nowMs() + PENDING_TTL_MS) }
            requestBurn(song)
        }
        return true
    }

    /** Loop tick: land parked inserts whose file arrived. Expired ones and ones whose mix ended are dropped. */
    fun drainPending() {
        val due: List<Pending>
        synchronized(pending) {
            if (pending.isEmpty()) return
            val now = nowMs()
            val keep = ArrayList<Pending>()
            val land = ArrayList<Pending>()
            for (x in pending) {
                when {
                    now > x.deadlineMs -> Unit
                    isLoadable(x.loadable.songId) -> land += x
                    else -> keep += x
                }
            }
            pending.clear(); pending.addAll(keep)
            due = land
        }
        val p = port()?.takeIf { it.autoMixing } ?: return // mix ended while the burn ran: let it go
        due.forEach { p.insert(AutoMixItem(it.loadable, it.durationMs), it.action) }
    }

    val pendingCount: Int get() = synchronized(pending) { pending.size }

    companion object {
        /** Same fallback the Auto-DJ uses for an unknown length. */
        const val FALLBACK_LENGTH_MS = 180_000
        const val PENDING_TTL_MS = 15 * 60 * 1000L
    }
}

/** Process-wide hand-off so the app-scoped repository can find the Mix without a graph dependency cycle. */
object MixJukeboxSeam {
    @Volatile var source: MixJukeboxSource? = null
}
