package com.levi.pocketdj.data.location

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * Permission + copy helpers for the Android location source. The mapping functions are pure
 * (JVM-tested); the Context-taking ones are thin wrappers.
 *
 * Permission model (iOS WhenInUse/Always, mapped): COARSE/FINE granted => WHEN_IN_USE (the
 * foreground prompt asks both so the user may pick "approximate"; dwell detection wants ~200 m
 * accuracy, so an approximate-only grant yields movement hints but no visits);
 * BACKGROUND granted as well => ALWAYS.
 */
object LocationSettings {
    val FOREGROUND_PERMISSIONS = arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
    const val BACKGROUND_PERMISSION = Manifest.permission.ACCESS_BACKGROUND_LOCATION
    private const val PREFS = "pdj.location"
    private const val KEY_ASKED = "askedForeground"

    fun authorization(coarse: Boolean, fine: Boolean, background: Boolean, askedBefore: Boolean): ListeningLocationAuthorization = when {
        (coarse || fine) && background -> ListeningLocationAuthorization.ALWAYS
        coarse || fine -> ListeningLocationAuthorization.WHEN_IN_USE
        askedBefore -> ListeningLocationAuthorization.DENIED
        else -> ListeningLocationAuthorization.NOT_DETERMINED
    }

    /** iOS `statusText` verbatim, so the copy matches across platforms. */
    fun statusText(a: ListeningLocationAuthorization): String = when (a) {
        ListeningLocationAuthorization.ALWAYS -> "Always"
        ListeningLocationAuthorization.WHEN_IN_USE -> "While using the app"
        ListeningLocationAuthorization.DENIED -> "Denied"
        ListeningLocationAuthorization.RESTRICTED -> "Restricted"
        ListeningLocationAuthorization.NOT_DETERMINED -> "Not yet asked"
        ListeningLocationAuthorization.UNSUPPORTED -> "Unavailable"
    }

    /** Turning ON needs pockets ON; turning OFF is never blocked. */
    fun canSetEnabled(on: Boolean, pocketsOn: Boolean): Boolean = !on || pocketsOn

    /** The toggle is inert only when it is off AND pockets are off (nothing to turn on, nothing to turn off). */
    fun toggleEnabled(locationOn: Boolean, pocketsOn: Boolean): Boolean = locationOn || pocketsOn

    fun current(ctx: Context): ListeningLocationAuthorization {
        fun granted(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        return authorization(
            coarse = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            fine = granted(Manifest.permission.ACCESS_FINE_LOCATION),
            // Pre-Q has no separate background permission: foreground grant covers it.
            background = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || granted(BACKGROUND_PERMISSION),
            askedBefore = asked(ctx),
        )
    }

    fun asked(ctx: Context): Boolean = runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false) }.getOrDefault(false)

    fun markAsked(ctx: Context) {
        runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ASKED, true).apply() }
    }

    /** App-details screen in system Settings (the denied / Always hand-off). */
    fun appSettingsIntent(ctx: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}
