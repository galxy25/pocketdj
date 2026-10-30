package com.levi.pocketdj.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.core.graphics.drawable.toBitmap
import com.levi.pocketdj.playback.session.SessionSwitchboard
import kotlinx.coroutines.flow.asStateFlow
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.session.FavoriteCommand
import com.levi.pocketdj.shell.AppLifecycleObserver
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
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
            WidgetCommand.Kind.NEXT -> withContext(Dispatchers.Main) { pc.sequencer.skipNext() }
            WidgetCommand.Kind.PREVIOUS -> withContext(Dispatchers.Main) { pc.sequencer.skipPrevious() }
            WidgetCommand.Kind.PLAY_PAUSE ->
                if (pc.nowPlaying.value?.isPlaying == true) pc.pause() else pc.resume()
            WidgetCommand.Kind.VERDICT_ACCEPT, WidgetCommand.Kind.VERDICT_REJECT -> Unit // no For You verdicts on Android
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
            val inputs = combine(pc.nowPlaying, pc.sequencer.state, fav.state, app.catalogRepository.state, owner) { np0, seq, _, cat, eng ->
                val np = if (eng == MIX_ENGINE) null else np0
                val songId = np?.songId
                val seam = FavoriteCommand.seam
                val song = songId?.let { cat.catalog?.songsById?.get(it) }
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
                    repeatMode = if (seq.isRunning) seq.repeatMode.token else "off",
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
