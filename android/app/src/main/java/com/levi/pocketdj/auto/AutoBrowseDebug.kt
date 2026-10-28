package com.levi.pocketdj.auto

import android.content.ComponentName
import android.content.Context
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import com.levi.pocketdj.playback.PlaybackService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * DEBUG-only emulator stand-in for the Android Auto host (no DHU on the emulator): connects a real
 * Media3 [MediaBrowser] to [PlaybackService] - the same binder path a head unit uses - then walks
 * the "Mix" and "Jukebox" subtrees logging every row (tag `PocketDJ.autodbg`) and optionally picks rows by title
 * (`pdj.autoPick="Deck A|SeedRip|Start Mix"`), exactly as a tap in the car would (`setMediaItem(mediaId)`).
 * Driven by `am start -e pdj.autoDump 1 [-e pdj.autoPick ...]`; never compiled into behavior in release.
 */
object AutoBrowseDebug {
    /** Held across invocations so the service stays bound (a real head unit stays connected). */
    private var held: MediaBrowser? = null
    private suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.await(): T =
        kotlinx.coroutines.suspendCancellableCoroutine { c ->
            addListener({ runCatching { get() }.fold({ c.resumeWith(Result.success(it)) }, { c.resumeWith(Result.failure(it)) }) }, Runnable::run)
        }

    private const val TAG = "PocketDJ.autodbg"

    fun run(context: Context, scope: CoroutineScope, picks: List<String>, roots: List<String>) {
        scope.launch(Dispatchers.Main) {
            runCatching {
                val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
                val browser = held ?: MediaBrowser.Builder(context, token).buildAsync().await().also { held = it }
                val root = browser.getLibraryRoot(null).await().value ?: error("no root")
                val top = children(browser, root.mediaId)
                Log.d(TAG, "ROOT: " + top.joinToString(" | ") { it.mediaMetadata.title.toString() })
                for (name in roots) {
                    val node = top.firstOrNull { it.mediaMetadata.title.toString().contains(name, true) }
                    if (node == null) { Log.d(TAG, "ROOT '$name' not present"); continue }
                    dump(browser, node, 0)
                }
                for (p in picks) {
                    val mix = children(browser, root.mediaId).firstOrNull { it.mediaMetadata.title.toString().contains("Mix", true) }
                    val target = mix?.let { find(browser, it, p, 0) }
                    if (target == null) { Log.d(TAG, "PICK '$p' not found"); continue }
                    Log.d(TAG, "PICK '$p' -> ${target.mediaId}")
                    Log.d(TAG, "cmdSetItem=${browser.isCommandAvailable(androidx.media3.common.Player.COMMAND_SET_MEDIA_ITEM)} cmdPrepare=${browser.isCommandAvailable(androidx.media3.common.Player.COMMAND_PREPARE)} state=${browser.playbackState}")
                    runCatching { browser.setMediaItem(target); browser.prepare() }
                    kotlinx.coroutines.delay(1500)
                    mix.let { dump(browser, it, 0) }
                }
            }.onFailure { Log.d(TAG, "failed: $it") }
        }
    }

    private suspend fun children(b: MediaBrowser, id: String): List<MediaItem> =
        b.getChildren(id, 0, 100, null).await().value?.toList().orEmpty()

    private suspend fun dump(b: MediaBrowser, node: MediaItem, depth: Int) {
        val m = node.mediaMetadata
        Log.d(TAG, "  ".repeat(depth) + "- ${m.title} [${m.subtitle ?: ""}] play=${m.isPlayable} browse=${m.isBrowsable}")
        if (depth < 2 && m.isBrowsable == true) children(b, node.mediaId).forEach { dump(b, it, depth + 1) }
    }

    private suspend fun find(b: MediaBrowser, node: MediaItem, token: String, depth: Int): MediaItem? {
        if (depth > 0 && node.mediaMetadata.title.toString().contains(token, true)) return node
        if (depth < 3 && node.mediaMetadata.isBrowsable == true) {
            for (c in children(b, node.mediaId)) find(b, c, token, depth + 1)?.let { return it }
        }
        return null
    }
}
