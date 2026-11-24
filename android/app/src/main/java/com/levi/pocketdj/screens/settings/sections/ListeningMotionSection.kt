package com.levi.pocketdj.screens.settings.sections

import android.Manifest
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.levi.pocketdj.data.location.LocationSettings
import com.levi.pocketdj.data.motion.ActivityTransitionSource
import com.levi.pocketdj.data.motion.ListeningMotionStore
import com.levi.pocketdj.data.pockets.PocketsSettings
import com.levi.pocketdj.data.recs.RecsSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.shell.SettingsSection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure copy + state mapping for Settings > Pocket Wheel > motion (iOS `ListeningMotionSettingsSection`). */
object ListeningMotionCopy {
    const val ID = "listeningMotion"
    /** Right under the places & trips group (665). */
    const val ORDER = 667
    const val TOGGLE = "Notice walking & running"
    const val ADAPT_TOGGLE = "Adapt pocket runs to walking & running"
    const val ACCESS_LABEL = "Motion access"
    const val OPEN_SETTINGS = "Open Settings"
    const val DENIED_HINT =
        "Physical activity access is off for PocketDJ. Turn it on in Settings to tell a run from a commute."

    /**
     * Play User Data policy "prominent disclosure": shown in-app BEFORE the runtime request; names the data, the
     * purpose, that it runs when the app is closed or not in use, and where the data goes.
     */
    const val DISCLOSURE_TITLE = "Use your physical activity to notice walking & running?"
    const val DISCLOSURE =
        "PocketDJ uses Android's activity recognition to notice when you start or stop walking, running, cycling or " +
            "riding in a vehicle, and keeps a 7-day timeline of those changes on this phone. This also happens when " +
            "the app is closed or not in use, but only while \"$TOGGLE\" is on. It lets your pocket wheel tell a run " +
            "from a commute. The timeline never leaves this phone; with listening pockets on, only the activity of " +
            "each play (walking, running, and so on) is sent with your pockets. No location or step counts are ever " +
            "collected. This is optional: pockets work without it, and you can turn it off any time in Settings."
    const val DISCLOSURE_CONTINUE = "Continue"
    const val DISCLOSURE_DECLINE = "No thanks"

    const val FOOTER_POCKETS_ON =
        "PocketDJ notices when you were walking, running, cycling or in a car while a song played, so your pocket " +
            "wheel can tell a run from a commute. With listening pockets on, the activity of each play (walking, " +
            "running, and so on) is sent with your pockets. No location or step counts are ever sent."
    const val FOOTER_POCKETS_OFF =
        "PocketDJ notices when you were walking, running, cycling or in a car while a song played, so your pocket " +
            "wheel can tell a run from a commute. It uses the activity changes this phone reports and keeps them on " +
            "this phone for 7 days; no GPS, and nothing is sent anywhere."

    fun footer(pocketsEnabled: Boolean) = if (pocketsEnabled) FOOTER_POCKETS_ON else FOOTER_POCKETS_OFF

    enum class Access { ALLOWED, NOT_ASKED, DENIED }

    fun access(granted: Boolean, asked: Boolean): Access = when {
        granted -> Access.ALLOWED
        asked -> Access.DENIED
        else -> Access.NOT_ASKED
    }

    fun statusText(a: Access) = when (a) {
        Access.ALLOWED -> "Allowed"
        Access.NOT_ASKED -> "Not asked yet"
        Access.DENIED -> "Denied"
    }

    /** The system dialog is only worth launching when the permission was never asked (a denial may be permanent). */
    fun showsOpenSettings(a: Access) = a == Access.DENIED
}

/** Device-local flags of this section (never synced): the adapt toggle and "did we ever ask". */
object MotionPrefs {
    private const val PREFS = "pdj.wheel"
    private const val KEY_ASKED = "motionPermissionAsked"
    const val PERMISSION = Manifest.permission.ACTIVITY_RECOGNITION

    fun adaptToActivity(ctx: Context): Boolean =
        runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ListeningMotionStore.ADAPT_TO_ACTIVITY_KEY, false) }
            .getOrDefault(false)

    fun setAdaptToActivity(ctx: Context, on: Boolean) {
        runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ListeningMotionStore.ADAPT_TO_ACTIVITY_KEY, on).apply() }
    }

    fun asked(ctx: Context): Boolean =
        runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false) }.getOrDefault(false)

    fun markAsked(ctx: Context) {
        runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ASKED, true).apply() }
    }
}

internal fun listeningMotionSection() = SettingsSection(ListeningMotionCopy.ID, ListeningMotionCopy.ORDER) { host ->
    val graph = host.graph
    val ctx = LocalContext.current
    val pocketsOn by graph.settings.flow(PocketsSettings.LISTENING_POCKETS_ENABLED).collectAsState(initial = false)
    val recEngineOn by graph.settings.flow(RecsSettings.REC_ENGINE_ENABLED).collectAsState(initial = false)
    val store = remember { graph.pocketsGraph.motionStore }
    var tick by remember { mutableIntStateOf(0) }   // bumps to recompose after a toggle / permission change
    var enabled by remember { mutableStateOf(store.isEnabled) }
    var adapt by remember { mutableStateOf(MotionPrefs.adaptToActivity(ctx)) }
    var disclosure by remember { mutableStateOf(false) }

    fun refreshState() { enabled = store.isEnabled; tick++ }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        MotionPrefs.markAsked(ctx)
        // The opt-in is kept even when denied (iOS parity): the status row then offers Open Settings.
        host.scope.launch(Dispatchers.IO) { store.setEnabled(true); withContext(Dispatchers.Main) { refreshState() } }
    }

    // Returning from system Settings may have granted it: register now.
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        var hadPermission = ActivityTransitionSource.hasPermission(ctx)
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME) {
                val has = ActivityTransitionSource.hasPermission(ctx)
                val newlyGranted = has && !hadPermission
                hadPermission = has
                // Register only when the permission has just flipped to granted (a re-register re-delivers a fresh ENTER).
                if (store.isEnabled && newlyGranted) {
                    host.scope.launch(Dispatchers.IO) { store.ensureRegistered(); withContext(Dispatchers.Main) { refreshState() } }
                } else refreshState()
            }
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    if (!recEngineOn) return@SettingsSection
    @Suppress("UNUSED_EXPRESSION") tick

    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(ListeningMotionCopy.TOGGLE, modifier = Modifier.weight(1f))
        Switch(
            checked = enabled,
            onCheckedChange = { want ->
                if (!want) {
                    host.scope.launch(Dispatchers.IO) { store.setEnabled(false); withContext(Dispatchers.Main) { refreshState() } }
                } else if (ActivityTransitionSource.hasPermission(ctx)) {
                    host.scope.launch(Dispatchers.IO) { store.setEnabled(true); withContext(Dispatchers.Main) { refreshState() } }
                } else {
                    disclosure = true   // prominent disclosure BEFORE the runtime request
                }
            },
            modifier = Modifier.testTag("wheel-motion-toggle"),
        )
    }

    if (enabled) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(ListeningMotionCopy.ADAPT_TOGGLE, modifier = Modifier.weight(1f))
            Switch(
                checked = adapt,
                onCheckedChange = { adapt = it; MotionPrefs.setAdaptToActivity(ctx, it) },
                modifier = Modifier.testTag("wheel-motion-adapt-toggle"),
            )
        }
        val access = ListeningMotionCopy.access(ActivityTransitionSource.hasPermission(ctx), MotionPrefs.asked(ctx))
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(ListeningMotionCopy.ACCESS_LABEL)
            Text(
                ListeningMotionCopy.statusText(access),
                color = if (access == ListeningMotionCopy.Access.ALLOWED) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("wheel-motion-status"),
            )
        }
        if (ListeningMotionCopy.showsOpenSettings(access)) {
            SettingsCaption(ListeningMotionCopy.DENIED_HINT)
            TextButton(
                onClick = { runCatching { ctx.startActivity(LocationSettings.appSettingsIntent(ctx)) } },
                modifier = Modifier.testTag("wheel-motion-open-settings"),
            ) { Text(ListeningMotionCopy.OPEN_SETTINGS) }
        } else if (access == ListeningMotionCopy.Access.NOT_ASKED) {
            TextButton(onClick = { disclosure = true }, modifier = Modifier.testTag("wheel-motion-allow")) { Text("Allow motion access") }
        }
    }
    SettingsCaption(ListeningMotionCopy.footer(pocketsOn))

    if (disclosure) {
        AlertDialog(
            onDismissRequest = { disclosure = false },
            title = { Text(ListeningMotionCopy.DISCLOSURE_TITLE) },
            text = { Text(ListeningMotionCopy.DISCLOSURE, modifier = Modifier.testTag("wheel-motion-disclosure")) },
            confirmButton = {
                TextButton(
                    onClick = { disclosure = false; permission.launch(MotionPrefs.PERMISSION) },
                    modifier = Modifier.testTag("wheel-motion-disclosure-continue"),
                ) { Text(ListeningMotionCopy.DISCLOSURE_CONTINUE) }
            },
            dismissButton = {
                TextButton(onClick = { disclosure = false }, modifier = Modifier.testTag("wheel-motion-disclosure-decline")) {
                    Text(ListeningMotionCopy.DISCLOSURE_DECLINE)
                }
            },
        )
    }
}
