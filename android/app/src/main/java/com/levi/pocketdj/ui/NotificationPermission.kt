package com.levi.pocketdj.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/**
 * Q14 (Levi 2026-10-29: "request all permissions needed for the app to run smoothly and full
 * featured"). POST_NOTIFICATIONS (Android 13+) is asked CONTEXTUALLY, at the first action that
 * produces a progress notification (Burn, a Mix collection download), never as a wall at launch.
 * Asked once per install: after a "Don't allow" the user turns it on in system Settings (Android
 * itself stops showing the dialog after repeated denials). The media-playback notification is
 * exempt from this permission, so playback never triggers it.
 */
object NotificationPermission {
    private const val PREFS = "pdj_permissions"
    private const val KEY_ASKED = "post_notifications_asked"

    /** Pure rule (JVM-tested). */
    fun shouldAsk(sdkInt: Int, granted: Boolean, askedBefore: Boolean): Boolean =
        sdkInt >= 33 && !granted && !askedBefore

    fun granted(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    internal fun askedBefore(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false)

    internal fun markAsked(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ASKED, true).apply()
    }
}

/** A callback that asks for POST_NOTIFICATIONS when [NotificationPermission.shouldAsk] says so; no-op otherwise. */
@Composable
fun rememberNotificationPermissionRequester(): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    return remember(context, launcher) {
        {
            if (NotificationPermission.shouldAsk(
                    Build.VERSION.SDK_INT,
                    NotificationPermission.granted(context),
                    NotificationPermission.askedBefore(context),
                )
            ) {
                NotificationPermission.markAsked(context)
                runCatching { launcher.launch(Manifest.permission.POST_NOTIFICATIONS) }
            }
        }
    }
}
