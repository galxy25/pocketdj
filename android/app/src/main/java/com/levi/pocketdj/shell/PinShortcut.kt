package com.levi.pocketdj.shell

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.levi.pocketdj.MainActivity
import com.levi.pocketdj.R
import com.levi.pocketdj.assistant.ShortcutRanking
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID

/** Pure rules for a pinned home-screen collection shortcut. */
object PinShortcutSpec {
    private val RESERVED_IDS = setOf(NOW_PLAYING_SETLIST_ID, NOW_PLAYING_PLAYLIST_ID)

    /** Launcher short labels render badly past ~25 chars; the same cap as dynamic shortcuts. */
    const val MAX_LABEL = ShortcutRanking.MAX_LABEL

    /** The reserved Now Playing scratch set can never be pinned. */
    fun canPin(id: String, name: String): Boolean = id !in RESERVED_IDS && name.isNotBlank()

    fun label(name: String): String {
        val n = name.trim()
        return if (n.length <= MAX_LABEL) n else n.take(MAX_LABEL - 1) + "…"
    }

    /** Distinct from the dynamic `play_*` ids so publishing never replaces a pin. */
    fun shortcutId(kind: PlayKind, id: String): String = "pin_${kind.token}_$id"

    fun deepLink(kind: PlayKind, id: String): String = ShortcutRanking.deepLink(kind, id)
}

object PinShortcut {
    /** @return true when the launcher accepted the pin request (it then shows its own dialog). */
    fun request(context: Context, kind: PlayKind, id: String, name: String): Boolean {
        if (!PinShortcutSpec.canPin(id, name)) return false
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(context)) return false
        val label = PinShortcutSpec.label(name)
        val info = ShortcutInfoCompat.Builder(context, PinShortcutSpec.shortcutId(kind, id))
            .setShortLabel(label)
            .setLongLabel(name.trim())
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(
                Intent(Intent.ACTION_VIEW, Uri.parse(PinShortcutSpec.deepLink(kind, id)))
                    .setClassName(context, MainActivity::class.java.name),
            )
            .build()
        return ShortcutManagerCompat.requestPinShortcut(context, info, null)
    }
}

/** "Add to Home screen" overflow-menu row for a collection; renders nothing when not pinnable. */
@Composable
fun PinToHomeMenuItem(kind: PlayKind, id: String, name: String, dismiss: () -> Unit) {
    val context = LocalContext.current
    if (!PinShortcutSpec.canPin(id, name)) return
    // Hide the row entirely when the launcher cannot pin shortcuts.
    if (!ShortcutManagerCompat.isRequestPinShortcutSupported(context)) return
    DropdownMenuItem(
        text = { Text("Add to Home screen") },
        onClick = {
            dismiss()
            if (!PinShortcut.request(context, kind, id, name)) {
                android.widget.Toast.makeText(context, "Couldn't add to Home screen", android.widget.Toast.LENGTH_SHORT).show()
            }
        },
    )
}
