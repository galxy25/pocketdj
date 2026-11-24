package com.levi.pocketdj.widget

import com.levi.pocketdj.remote.RemoteControllerGate
import com.levi.pocketdj.remote.RemoteRedirect
import android.content.Context
import android.graphics.Bitmap
import androidx.core.graphics.drawable.toBitmap
import com.levi.pocketdj.playback.session.SessionSwitchboard
import kotlinx.coroutines.flow.asStateFlow
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.session.FavoriteCommand
import com.levi.pocketdj.shell.AppLifecycleObserver
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Connects the app graph to the widget: publishes the snapshot (WidgetSync), applies live widget
 * commands, and drains the offline queue on foreground. Started once from the shell graph.
 */
class WidgetBridge(private val app: AppGraph, private val ctx: Context) {
    private val store = WidgetFiles.snapshotStore(ctx)
    private val pending = WidgetFiles.pending(ctx)
    @Volatile private var started = false

    private val executor = WidgetCommandExecutor { cmd ->
        val pc = app.playbackController
        when (cmd.kind) {
            WidgetCommand.Kind.FAVORITE -> {
                val id = cmd.songId ?: return@WidgetCommandExecutor
                app.collectionsGraph.favoriteAccess.set(id, cmd.value == "1", cmd.appleMusicId)
            }
            WidgetCommand.Kind.REPEAT -> withContext(Dispatchers.Main) { pc.sequencer.setRepeatMode(RepeatMode.fromToken(cmd.value)) }
            WidgetCommand.Kind.SHUFFLE -> withContext(Dispatchers.Main) { pc.sequencer.setShuffle(cmd.value == "1") }
            WidgetCommand.Kind.NEXT -> withContext(Dispatchers.Main) { pc.sequencer.skipNext(fast = true) } // the widget's ⏭ is the 5 s sweep when DJ Mode mixes
            WidgetCommand.Kind.PREVIOUS -> withContext(Dispatchers.Main) { pc.sequencer.skipPrevious() }
            WidgetCommand.Kind.PLAY_PAUSE ->
                if (RemoteControllerGate.shared.forward(RemoteRedirect.PlayPause)) Unit
                else if (pc.nowPlaying.value?.isPlaying == true) pc.pause() else pc.resume()
            WidgetCommand.Kind.VERDICT_ACCEPT, WidgetCommand.Kind.VERDICT_REJECT -> withContext(Dispatchers.IO) {
                // The target is the one the command carries (the snapshot the user saw), never what plays now.
                val np = app.browseGraph.nowPlayingFeedback
                WidgetVerdicts.apply(cmd) { songId, scope, verdict ->
                    np.recordFor(songId, scope, verdict, RecFeedbackStore.Surface.WIDGET)
                }
            }
        }
    }

    private fun drainPending() {
        app.appScope.launch(Dispatchers.Default) {
            pending.drain().forEach { runCatching { executor.apply(it) } }
        }
    }

    fun start() {
        if (started) return
        started = true
        WidgetCommandBus.executor = executor
        AppLifecycleObserver.widgetDrain = { drainPending() }
        // Cold start: ON_START already ran against the no-op default hook, so drain now too.
        drainPending()
        app.appScope.launch(Dispatchers.Default) {
            val pc = app.playbackController
            val fav = app.collectionsGraph.favorites
            // Who owns audio: when Mix sounds, the widget goes idle.
            // ANS-SHELL-1: event-driven (SessionSwitchboard listener), no 1 Hz poll.
            val ownerState = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
            SessionSwitchboard.shared.addListener { ownerState.value = SessionSwitchboard.shared.current?.engine }
            ownerState.value = SessionSwitchboard.shared.current?.engine // seed AFTER registering: no lost change
            val owner = ownerState.asStateFlow()
            // Verdict revisions (the store is lazy: polled until recs have started, then reactive).
            val recRev = kotlinx.coroutines.flow.flow {
                var fb = app.browseGraph.nowPlayingFeedbackIfReady()
                while (fb == null) { emit(-1); kotlinx.coroutines.delay(3_000); fb = app.browseGraph.nowPlayingFeedbackIfReady() }
                emitAll(app.browseGraph.recFeedbackStore.state.map { it.revision })
            }
            val inputs = combine(pc.nowPlaying, pc.sequencer.state, fav.state, app.catalogRepository.state, combine(owner, recRev) { o, _ -> o }) { np0, seq, _, cat, eng ->
                val np = if (eng == MIX_ENGINE) null else np0
                val songId = np?.songId
                val seam = FavoriteCommand.seam
                val song = songId?.let { cat.catalog?.songsById?.get(it) }
                val target = if (np != null) app.browseGraph.nowPlayingFeedbackIfReady()?.currentTarget() else null
                val verdict = target?.let { app.browseGraph.recFeedbackStore.verdict(it.songId, it.scope) }
                WidgetInputs(
                    songId = songId,
                    title = np?.title,
                    artist = np?.artist,
                    albumId = np?.albumId,
                    isPlaying = np?.isPlaying == true,
                    upNext = if (np != null && seq.isRunning) seq.upcomingPlayable.take(WidgetSync.UP_NEXT_MAX)
                        .map { NowPlayingSnapshot.Track(it.uid, it.id, it.title, it.artist.orEmpty()) } else emptyList(),
                    isFavorite = FavoriteCommand.filled(seam, songId),
                    favoriteAvailable = FavoriteCommand.visible(seam, songId),
                    appleMusicId = song?.appleMusicId,
                    // The EFFECTIVE mode: a forced-off repeat (album run, etc.) must not show as lit.
                    repeatMode = if (seq.isRunning) seq.effectiveRepeatMode.token else "off",
                    recVerdict = verdict?.takeIf { it != RecFeedbackStore.Verdict.CLEARED }?.raw.orEmpty(),
                    recScope = if (target != null && target.songId == songId) target.scope else "",
                    shuffleEnabled = seq.isRunning && seq.shuffleEnabled,
                    artSourceReady = cat.catalog != null,
                )
            }.distinctUntilChanged()
            WidgetSync(this, inputs, store, ::fetchCover) { refreshNowPlayingWidget(ctx) }.start()
        }
    }

    private suspend fun fetchCover(key: CoverKey): ByteArray? {
        val catalog = app.catalogRepository.state.value.catalog ?: return null
        val album = key.albumId?.let { catalog.albumsById[it] }
            ?: catalog.songsById[key.songId]?.albumId?.let { catalog.albumsById[it] }
            ?: return null
        for (url in app.albumArtworkStore.artUrls(album)) {
            val res = ctx.imageLoader.execute(
                ImageRequest.Builder(ctx).data(url).size(512).allowHardware(false).build(),
            )
            val bmp = (res as? SuccessResult)?.drawable?.toBitmap() ?: continue
            return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        }
        return null
    }

    private companion object {
        const val MIX_ENGINE = "mix"
    }
}

/**
 * Applies a widget 👍/👎 to the target the command CARRIES (iOS `WidgetCommandChannel.Pending`: songId + scope
 * + verdict, nothing resolved at drain time). A command with no song or scope (a widget from before this
 * build, a snapshot with no recommendation scope) is dropped, never redirected at whatever is current.
 * Returns whether it was applied.
 */
object WidgetVerdicts {
    fun apply(cmd: WidgetCommand, record: (songId: String, scope: String, verdict: RecFeedbackStore.Verdict) -> Unit): Boolean {
        if (!cmd.isVerdict) return false
        val songId = cmd.songId?.takeIf { it.isNotEmpty() } ?: return false
        val scope = cmd.scope?.takeIf { it.isNotEmpty() } ?: return false
        val verdict = if (cmd.kind == WidgetCommand.Kind.VERDICT_ACCEPT) RecFeedbackStore.Verdict.ACCEPTED
        else RecFeedbackStore.Verdict.REJECTED
        record(songId, scope, verdict)
        return true
    }
}
