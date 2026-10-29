package com.levi.pocketdj.screens.settings.sections

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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
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
import com.levi.pocketdj.data.location.ListeningLocationAuthorization
import com.levi.pocketdj.data.location.ListeningLocationStore
import com.levi.pocketdj.data.location.LocationSettings
import com.levi.pocketdj.data.pockets.PocketsSettings
import com.levi.pocketdj.data.recs.RecsSettings
import com.levi.pocketdj.screens.settings.SettingsCaption
import com.levi.pocketdj.shell.SettingsSection
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Pure copy for the places & trips rows (iOS `ListeningLocationSettingsSection`). */
object ListeningLocationCopy {
    const val ID = "listeningLocation"
    /** Right under Recommendations (660), where the pockets toggle lives. */
    const val ORDER = 665
    const val TOGGLE = "Use places & trips in pockets"
    const val NO_PLACES = "No places yet. They appear after you've spent some time somewhere."
    const val ALWAYS_HINT = "Always lets PocketDJ notice trips between your places while music plays in the background."

    /**
     * Play User Data policy "prominent disclosure" (background location): shown in-app BEFORE every
     * system location prompt, names the data, the purpose, and that it is used when the app is
     * closed or not in use. Background ("Allow all the time") is a separate, later step.
     */
    const val DISCLOSURE_TITLE = "Use your location for places & trips?"
    const val DISCLOSURE_FOREGROUND =
        "PocketDJ collects location data to learn the places where you listen (home, gym, A, B, C…) and the trips " +
            "between them, so your listening pockets can match music to where you are. This includes when the app " +
            "is closed or not in use while music plays in the background, once you also choose \"Allow all the time\" " +
            "in the next step. This is optional: pockets work without it. Your location stays on this device; only " +
            "anonymous place labels are used in pockets. Turn it off any time with \"$TOGGLE\" in Settings, which " +
            "also erases your places."
    const val DISCLOSURE_BACKGROUND =
        "To notice trips between your places while music plays in the background, PocketDJ collects location data " +
            "even when the app is closed or not in use. This is optional. On the next screen choose \"Allow all the " +
            "time\". Your location stays on this device and is never used for ads. You can switch back to \"Allow only " +
            "while using the app\" in Android settings, or turn off \"$TOGGLE\" in PocketDJ Settings, at any time."
    const val DISCLOSURE_CONTINUE = "Continue"
    const val DISCLOSURE_DECLINE = "No thanks"
    const val PRECISE_HINT =
        "Approximate location is too coarse to learn places. Allow precise location so PocketDJ can recognise where you listen."
    const val ERASE = "Erase places & trips"
    const val ERASE_TITLE = "Erase your places and trips from this device?"
    const val ERASE_MESSAGE =
        "PocketDJ starts learning your places again from now. Pockets you already have keep their labels as \"Earlier place\"."
    const val FOOTER =
        "Your location never leaves this device. PocketDJ only learns which of your places, A, B, C…, you were at, " +
            "or that you were travelling between them. Those anonymous labels can be included with your listening " +
            "pockets. Turning pockets off also turns this off and erases your places."

    fun share(shareOfTime: Double): String = "${(shareOfTime * 100).roundToInt()} % of time"

    /** Which action the authorization row offers. */
    enum class AuthAction { NONE, OPEN_SETTINGS, ALLOW_ALWAYS, ALLOW_ALWAYS_IN_SETTINGS, REQUEST_FOREGROUND }

    fun authAction(a: ListeningLocationAuthorization, didRequestAlways: Boolean, canRequestAgain: Boolean = false): AuthAction = when (a) {
        ListeningLocationAuthorization.DENIED -> if (canRequestAgain) AuthAction.REQUEST_FOREGROUND else AuthAction.OPEN_SETTINGS
        ListeningLocationAuthorization.RESTRICTED -> AuthAction.OPEN_SETTINGS
        ListeningLocationAuthorization.WHEN_IN_USE ->
            if (didRequestAlways) AuthAction.ALLOW_ALWAYS_IN_SETTINGS else AuthAction.ALLOW_ALWAYS
        ListeningLocationAuthorization.NOT_DETERMINED -> AuthAction.REQUEST_FOREGROUND
        else -> AuthAction.NONE
    }
}

private val toggleMutex = Mutex()
@Volatile private var latestToggle = false

internal fun listeningLocationSection() = SettingsSection(ListeningLocationCopy.ID, ListeningLocationCopy.ORDER) { host ->
    val graph = host.graph
    val ctx = LocalContext.current
    val pocketsOn by graph.settings.flow(PocketsSettings.LISTENING_POCKETS_ENABLED).collectAsState(initial = false)
    val recEngineOn by graph.settings.flow(RecsSettings.REC_ENGINE_ENABLED).collectAsState(initial = false)
    val store by produceState<ListeningLocationStore?>(null) {
        value = withContext(Dispatchers.IO) { graph.collectionsGraph.locationStore }
    }
    val s = store ?: return@SettingsSection
    if (!s.isSupported) return@SettingsSection
    val rev by s.revisionFlow.collectAsState()
    var showErase by remember { mutableStateOf(false) }

    fun resync() { host.scope.launch(Dispatchers.IO) { graph.collectionsGraph.locationPermissionChanged() } }
    fun openSettings() = runCatching { ctx.startActivity(LocationSettings.appSettingsIntent(ctx)) }

    val foreground = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        LocationSettings.markAsked(ctx)
        LocationSettings.recordForegroundResult(ctx, granted = it.values.any { g -> g })
        resync()
    }
    val background = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { resync() }
    // Prominent disclosure gate: (message, action) shown before any system location prompt.
    var disclosure by remember { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    fun requestForeground() {
        disclosure = ListeningLocationCopy.DISCLOSURE_FOREGROUND to {
            LocationSettings.recordDisclosureAccepted(ctx, background = false)
            foreground.launch(LocationSettings.FOREGROUND_PERMISSIONS)
        }
    }
    fun requestBackground() {
        disclosure = ListeningLocationCopy.DISCLOSURE_BACKGROUND to {
            LocationSettings.recordDisclosureAccepted(ctx, background = true)
            s.requestAlwaysUpgrade()
            background.launch(LocationSettings.BACKGROUND_PERMISSION)
        }
    }

    // Returning from system Settings (denied / Always hand-off) may have changed the grant.
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME && s.isEnabled) resync() }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    @Suppress("UNUSED_EXPRESSION") rev // recompose on engine changes
    val on = s.isEnabled
    // iOS: the whole group lives under the enabled rec engine; with pockets off the toggle shows disabled.
    if (!recEngineOn) return@SettingsSection

    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(ListeningLocationCopy.TOGGLE, modifier = Modifier.weight(1f))
        Switch(
            checked = on,
            enabled = LocationSettings.toggleEnabled(on, pocketsOn),
            onCheckedChange = { want ->
                if (!LocationSettings.canSetEnabled(want, pocketsOn)) return@Switch
                latestToggle = want
                host.scope.launch(Dispatchers.IO) {
                    // Writes are serialized and always apply the LATEST requested value, so a fast on->off
                    // can never leave the store enabled (or prompt) after the user switched it off.
                    val v = toggleMutex.withLock {
                        val v = latestToggle
                        s.setEnabled(v)
                        runCatching { graph.settings.set(PocketsSettings.LISTENING_LOCATION_ENABLED, v) }
                        v
                    }
                    if (v && latestToggle) {
                        if (!LocationSettings.current(ctx).isGranted) {
                            withContext(Dispatchers.Main) { if (latestToggle) requestForeground() }
                        } else resync()
                    }
                }
            },
            modifier = Modifier.testTag("pockets-location-toggle"),
        )
    }

    if (on) {
        val auth = s.authorization
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Location access")
            Text(
                LocationSettings.statusText(auth),
                color = if (auth.isGranted) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("pockets-location-status"),
            )
        }
        val canRetry = remember(auth, rev) {
            val act = generateSequence(ctx) { (it as? android.content.ContextWrapper)?.baseContext }.filterIsInstance<android.app.Activity>().firstOrNull()
            LocationSettings.canRequestAgain(
                LocationSettings.denials(ctx),
                act != null && LocationSettings.FOREGROUND_PERMISSIONS.any { p -> act.shouldShowRequestPermissionRationale(p) },
            )
        }
        if (auth.isGranted && LocationSettings.isApproximateOnly(ctx)) {
            TextButton(onClick = { requestForeground() }, modifier = Modifier.testTag("pockets-location-allow-precise")) { Text("Allow precise location") }
            SettingsCaption(ListeningLocationCopy.PRECISE_HINT)
        }
        when (ListeningLocationCopy.authAction(auth, s.didRequestAlways, canRetry)) {
            ListeningLocationCopy.AuthAction.OPEN_SETTINGS ->
                TextButton(onClick = { openSettings() }, modifier = Modifier.testTag("pockets-location-open-settings")) { Text("Open Settings") }
            ListeningLocationCopy.AuthAction.REQUEST_FOREGROUND ->
                TextButton(onClick = { requestForeground() }, modifier = Modifier.testTag("pockets-location-allow")) { Text("Allow location") }
            ListeningLocationCopy.AuthAction.ALLOW_ALWAYS -> {
                TextButton(
                    onClick = { requestBackground() },
                    modifier = Modifier.testTag("pockets-location-allow-always"),
                ) { Text("Allow Always") }
                SettingsCaption(ListeningLocationCopy.ALWAYS_HINT)
            }
            ListeningLocationCopy.AuthAction.ALLOW_ALWAYS_IN_SETTINGS -> {
                TextButton(onClick = { openSettings() }, modifier = Modifier.testTag("pockets-location-open-settings")) { Text("Allow Always in Settings") }
                SettingsCaption(ListeningLocationCopy.ALWAYS_HINT)
            }
            ListeningLocationCopy.AuthAction.NONE -> Unit
        }

        val places = s.placeLabels()
        if (places.isEmpty()) {
            Text(
                ListeningLocationCopy.NO_PLACES, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("pockets-location-no-places"),
            )
        } else {
            places.forEach { p ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp).testTag("pockets-location-place-${p.rank}"),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(p.label)
                    Text(ListeningLocationCopy.share(p.shareOfTime), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        s.tripLabels().forEach { t ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp).testTag("pockets-location-trip"),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(t.label)
                Text("${t.occurrences}×", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        TextButton(onClick = { showErase = true }, modifier = Modifier.testTag("pockets-location-erase")) {
            Text(ListeningLocationCopy.ERASE, color = MaterialTheme.colorScheme.error)
        }
    }
    SettingsCaption(ListeningLocationCopy.FOOTER)

    disclosure?.let { (message, proceed) ->
        AlertDialog(
            onDismissRequest = { disclosure = null },
            title = { Text(ListeningLocationCopy.DISCLOSURE_TITLE) },
            text = { Text(message, modifier = Modifier.testTag("pockets-location-disclosure")) },
            confirmButton = {
                TextButton(
                    onClick = { disclosure = null; proceed() },
                    modifier = Modifier.testTag("pockets-location-disclosure-continue"),
                ) { Text(ListeningLocationCopy.DISCLOSURE_CONTINUE) }
            },
            dismissButton = {
                TextButton(onClick = { disclosure = null }, modifier = Modifier.testTag("pockets-location-disclosure-decline")) {
                    Text(ListeningLocationCopy.DISCLOSURE_DECLINE)
                }
            },
        )
    }

    if (showErase) {
        AlertDialog(
            onDismissRequest = { showErase = false },
            title = { Text(ListeningLocationCopy.ERASE_TITLE) },
            text = { Text(ListeningLocationCopy.ERASE_MESSAGE) },
            confirmButton = {
                TextButton(
                    onClick = { showErase = false; host.scope.launch(Dispatchers.IO) { s.eraseAll() } },
                    modifier = Modifier.testTag("pockets-location-erase-confirm"),
                ) { Text(ListeningLocationCopy.ERASE, color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { showErase = false }) { Text("Cancel") } },
        )
    }
}
