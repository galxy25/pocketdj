package com.levi.pocketdj.widget

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.KeyEvent
import androidx.glance.appwidget.updateAll
import com.levi.pocketdj.playback.PlaybackService
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Applies a widget command against the live app graph. Installed by the shell when the graph is up. */
fun interface WidgetCommandExecutor {
    suspend fun apply(cmd: WidgetCommand)
}

object WidgetCommandBus {
    /** Non-null only while this process has a live graph; null => the receiver queues instead. */
    @Volatile var executor: WidgetCommandExecutor? = null
}

object WidgetFiles {
    fun dir(ctx: Context) = File(ctx.filesDir, "widget")
    fun snapshotStore(ctx: Context) = NowPlayingSnapshotStore(dir(ctx))
    fun pending(ctx: Context) = PendingWidgetCommands(File(dir(ctx), "pending-commands.json"))
}

/** Intents the Glance actions fire. */
object WidgetIntents {
    const val ACTION_COMMAND = "com.levi.pocketdj.widget.COMMAND"
    private const val X_KIND = "kind"
    private const val X_SONG = "songId"
    private const val X_AM = "appleMusicId"
    private const val X_VALUE = "value"

    /** A media-button key sent straight to the playback service (starts it when the process is dead). */
    fun mediaButton(ctx: Context, keyCode: Int): Intent =
        Intent(Intent.ACTION_MEDIA_BUTTON)
            .setComponent(ComponentName(ctx, PlaybackService::class.java))
            .setData(Uri.parse("pdj-widget://key/$keyCode"))
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))

    fun command(ctx: Context, kind: WidgetCommand.Kind, songId: String?, appleMusicId: String?, value: String?): Intent =
        Intent(ACTION_COMMAND)
            .setComponent(ComponentName(ctx, WidgetActionReceiver::class.java))
            // Distinct data => distinct PendingIntents per (kind, song, value).
            .setData(Uri.parse("pdj-widget://cmd/${kind.name}/${Uri.encode(songId ?: "")}/${Uri.encode(value ?: "")}"))
            .putExtra(X_KIND, kind.name)
            .putExtra(X_SONG, songId)
            .putExtra(X_AM, appleMusicId)
            .putExtra(X_VALUE, value)

    fun parse(intent: Intent, nowMs: Long): WidgetCommand? {
        val kind = runCatching { WidgetCommand.Kind.valueOf(intent.getStringExtra(X_KIND) ?: return null) }.getOrNull()
            ?: return null
        return WidgetCommand(kind, intent.getStringExtra(X_SONG), intent.getStringExtra(X_AM), intent.getStringExtra(X_VALUE), nowMs)
    }
}

/**
 * Receives ♥ / repeat / shuffle taps. With a live graph the command is applied now; otherwise it
 * is queued (with the songId the user SAW) and drained on the next foreground.
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != WidgetIntents.ACTION_COMMAND) return
        val app = context.applicationContext
        val cmd = WidgetIntents.parse(intent, System.currentTimeMillis()) ?: return
        val pending = goAsync()
        scope.launch {
            try {
                val exec = WidgetCommandBus.executor
                if (exec != null) {
                    exec.apply(cmd)
                } else {
                    WidgetFiles.pending(app).enqueue(cmd)
                    optimisticUpdate(app, cmd)
                }
            } catch (_: Throwable) {
            } finally {
                pending.finish()
            }
        }
    }

    /** Show the tap immediately even though the app is not running (the real apply happens later). */
    private suspend fun optimisticUpdate(ctx: Context, cmd: WidgetCommand) {
        val store = WidgetFiles.snapshotStore(ctx)
        val snap = store.read()
        val next = when (cmd.kind) {
            WidgetCommand.Kind.FAVORITE -> if (snap.songId == cmd.songId) snap.copy(isFavorite = cmd.value == "1") else snap
            WidgetCommand.Kind.REPEAT -> snap.copy(repeatMode = cmd.value ?: snap.repeatMode)
            WidgetCommand.Kind.SHUFFLE -> snap.copy(shuffleEnabled = cmd.value == "1")
            else -> snap
        }
        if (store.write(next)) NowPlayingWidget().updateAll(ctx)
    }

    private companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
