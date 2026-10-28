package com.levi.pocketdj.mix.service

import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.levi.pocketdj.mix.engine.AutoDj
import com.levi.pocketdj.mix.engine.MixEngine
import com.levi.pocketdj.playback.session.SessionSwitchboard
import com.levi.pocketdj.playback.session.TransportOwner

/** The now-playing deck as the system card sees it. */
data class MixCard(
    val songId: String,
    val title: String,
    val artist: String,
    val artworkUri: String?,
    val durationMs: Long?,
    val positionMs: Long,
    /** Deck tempo (1.0 = unity): the card's position advances at this rate. */
    val rate: Float,
)

/** What the session adapter needs from the engine, so the mapping is testable with a fake. */
interface MixTransportPort {
    /** The nowPlayingDeck rule's card, or null when no deck is loaded. */
    fun card(): MixCard?
    /** A deck has play intent. */
    val isRunning: Boolean
    /** Next/previous mean something (a live Auto-DJ). */
    val canSkip: Boolean
    val skipFadeSeconds: Double
    val hasSounded: Boolean
    fun remotePlay()
    fun remotePause()
    fun remoteSkip(fadeSeconds: Double)
    fun pauseBoth()
}

/** The Media3 view of a [MixCard]; plain data so the mapping is JVM-testable. */
data class MixPlayerModel(
    val hasTrack: Boolean,
    val playbackState: Int,
    val playWhenReady: Boolean,
    val positionMs: Long,
    val durationMs: Long?,
    val rate: Float,
    val canSkip: Boolean,
    val commands: Player.Commands,
)

object MixPlayerStateMap {
    const val UID_PREV = "mix:prev"
    const val UID_NEXT = "mix:next"
    const val NEXT_FADE_SECONDS = 5.0

    fun commands(hasTrack: Boolean, canSkip: Boolean): Player.Commands {
        val b = Player.Commands.Builder()
        if (!hasTrack) return b.build()
        b.addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP, Player.COMMAND_GET_METADATA,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_TIMELINE,
        )
        if (canSkip) {
            b.addAll(
                Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            )
        }
        return b.build()
    }

    fun model(card: MixCard?, running: Boolean, canSkip: Boolean): MixPlayerModel {
        val has = card != null
        return MixPlayerModel(
            hasTrack = has,
            playbackState = if (has) Player.STATE_READY else Player.STATE_IDLE,
            playWhenReady = has && running,
            positionMs = (card?.positionMs ?: 0L).coerceAtLeast(0L),
            durationMs = card?.durationMs?.takeIf { it > 0 },
            rate = (card?.rate ?: 1f).coerceIn(0.25f, 4f),
            canSkip = has && canSkip,
            commands = commands(has, canSkip),
        )
    }

    fun currentIndex(m: MixPlayerModel) = if (m.canSkip) 1 else 0

    sealed interface Route {
        data object Next : Route
        data object Previous : Route
        data object None : Route
    }

    fun route(mediaItemIndex: Int, seekCommand: Int, currentIndex: Int): Route = when {
        seekCommand == Player.COMMAND_SEEK_TO_NEXT || seekCommand == Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> Route.Next
        seekCommand == Player.COMMAND_SEEK_TO_PREVIOUS || seekCommand == Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> Route.Previous
        mediaItemIndex > currentIndex -> Route.Next
        mediaItemIndex < currentIndex -> Route.Previous
        else -> Route.None
    }

    fun toMediaItem(c: MixCard): MediaItem = MediaItem.Builder()
        .setMediaId(c.songId)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(c.title)
                .setArtist(c.artist)
                .apply { c.artworkUri?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                .build(),
        )
        .build()
}

/**
 * While a Mix deck sounds, THIS is the MediaSession's player (decision D2, no MixService): the
 * notification / lock screen show the nowPlayingDeck track with a position that moves at the deck's
 * tempo; play/pause reach remotePlay/remotePause, next/previous reach remoteSkip. No heart. It is a
 * [TransportOwner]: last-STARTED owns, and starting it pauses the setlist player (the switchboard
 * calls every other owner's pauseForHandoff).
 */
@UnstableApi
class MixSessionPlayer(
    looper: Looper,
    private val port: MixTransportPort,
    private val board: SessionSwitchboard = SessionSwitchboard.shared,
) : SimpleBasePlayer(looper), TransportOwner {

    override val engine: String = "mix"
    override val sessionPlayer: Player get() = this
    override val hasSounded: Boolean get() = port.hasSounded

    init { board.register(this) }

    /** A Mix deck started sounding: claim the session (pausing the setlist player). */
    fun onAudioStarted() {
        board.setOwner(this)
        invalidateState()
    }

    /** The subject / transport changed, or the 1 Hz heartbeat: re-publish. */
    fun refresh() = invalidateState()

    override fun pauseForHandoff() {
        // Another owner started (a Browse song): silence both decks. Not a remote pause.
        port.pauseBoth()
    }

    private fun model() = MixPlayerStateMap.model(port.card(), port.isRunning, port.canSkip)

    override fun getState(): State {
        val m = model()
        val b = State.Builder()
            .setAvailableCommands(m.commands)
            .setPlaybackState(m.playbackState)
            .setPlayWhenReady(m.playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE)
            .setPlaybackParameters(androidx.media3.common.PlaybackParameters(m.rate))
        val c = port.card() ?: return b.build()
        val cur = MediaItemData.Builder(c.songId)
            .setMediaItem(MixPlayerStateMap.toMediaItem(c))
            .apply { m.durationMs?.let { setDurationUs(it * 1000L) } }
            .setIsSeekable(false)
            .build()
        val list = if (m.canSkip) {
            listOf(
                MediaItemData.Builder(MixPlayerStateMap.UID_PREV).build(), cur,
                MediaItemData.Builder(MixPlayerStateMap.UID_NEXT).build(),
            )
        } else listOf(cur)
        b.setPlaylist(list).setCurrentMediaItemIndex(MixPlayerStateMap.currentIndex(m))
        b.setContentPositionMs(
            if (m.playWhenReady) PositionSupplier.getExtrapolating(m.positionMs, m.rate)
            else PositionSupplier.getConstant(m.positionMs),
        )
        return b.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) port.remotePlay() else port.remotePause()
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        port.remotePause()
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (MixPlayerStateMap.route(mediaItemIndex, seekCommand, MixPlayerStateMap.currentIndex(model()))) {
            MixPlayerStateMap.Route.Next -> port.remoteSkip(MixPlayerStateMap.NEXT_FADE_SECONDS)
            MixPlayerStateMap.Route.Previous -> port.remoteSkip(port.skipFadeSeconds)
            MixPlayerStateMap.Route.None -> Unit   // decks are not seekable from the card
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        board.unregister(this)
        return Futures.immediateVoidFuture()
    }
}

/** [MixTransportPort] over the real engine + Auto-DJ. [art] resolves a card's artwork URL (catalog). */
class EngineMixTransportPort(
    private val engine: MixEngine,
    private val dj: AutoDj,
    private val art: (albumId: String?) -> String?,
) : MixTransportPort {
    override fun card(): MixCard? {
        val d = engine.nowPlayingDeck ?: return null
        val t = engine.loaded(d) ?: return null
        val dur = engine.duration(d)
        return MixCard(
            songId = t.songId, title = t.title, artist = t.artist, artworkUri = art(t.albumId),
            durationMs = if (dur > 0) (dur * 1000).toLong() else null,
            positionMs = (engine.position(d) * 1000).toLong(),
            rate = engine.rate(d).toFloat(),
        )
    }
    override val isRunning get() = engine.isRunning
    override val canSkip get() = dj.isMixing
    override val skipFadeSeconds get() = dj.skipFadeSeconds
    override val hasSounded get() = engine.hasSoundedThisProcess
    override fun remotePlay() = dj.remotePlay()
    override fun remotePause() = dj.remotePause()
    override fun remoteSkip(fadeSeconds: Double) = dj.remoteSkip(fadeSeconds)
    override fun pauseBoth() = engine.pauseBoth()
}
