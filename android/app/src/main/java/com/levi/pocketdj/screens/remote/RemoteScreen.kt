package com.levi.pocketdj.screens.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.remote.NearbyRemoteStarter
import com.levi.pocketdj.remote.RemoteDeviceRole
import com.levi.pocketdj.remote.RemotePermissions
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import com.levi.pocketdj.screens.jukebox.JukeboxQrCard
import kotlinx.coroutines.delay

/**
 * The Remote half of the Jukebox panel (iOS `RemoteView`): start Listen Together / Backseat, invite or join, then drive
 * the shared session. Hidden until `ParityFlags.REMOTE` (the hub, P2-REM-8, gates it). Hosted by the panel, so no own
 * app bar; the root carries tag `remote-view`.
 */
@Composable
fun RemoteScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val graph = remember(context) { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val controller = graph.remoteGraph.controller
    val vm = remember(controller) {
        RemoteViewModel(
            controller = controller,
            starter = { RemoteStarters.current },
            songs = { graph.catalogRepository.state.value.catalog?.songsById?.values?.toList().orEmpty() },
            scope = scope,
        )
    }

    // P2-REM-9: Nearby needs Bluetooth / nearby-devices permissions, asked at start/join behind a rationale sheet.
    fun granted(p: String) = androidx.core.content.ContextCompat.checkSelfPermission(context, p) == android.content.pm.PackageManager.PERMISSION_GRANTED
    var ask by remember { mutableStateOf<Pair<Boolean, () -> Unit>?>(null) }
    var showRationale by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val pending = ask
        ask = null
        if (pending != null) {
            if (RemotePermissions.canProceed(RemotePermissions.REQUIRED.associateWith(::granted), pending.first)) pending.second()
            else controller.setStatus(RemotePermissions.DENIED_MESSAGE)
        }
    }
    val guard: (Boolean, () -> Unit) -> Unit = { hosting, action ->
        if (RemotePermissions.missing(hosting, ::granted).isEmpty()) action() else { ask = hosting to action; showRationale = true }
    }
    // A scanned invite (pocketdj://remote/join/<token>) joins once the permissions are in.
    val pendingJoin by graph.shellGraph.deepLinks.pendingRemoteJoin.collectAsState()
    LaunchedEffect(pendingJoin) {
        graph.shellGraph.deepLinks.takePendingRemoteJoin()?.let { token -> guard(false) { vm.joinWithCode(token) } }
    }
    if (showRationale) {
        val hosting = ask?.first ?: false
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showRationale = false; ask = null },
            title = { Text("Allow nearby access?") },
            text = { Text(RemotePermissions.rationale(hosting), Modifier.testTag("remote-permission-rationale")) },
            confirmButton = {
                TextButton({ showRationale = false; launcher.launch(RemotePermissions.missing(hosting, ::granted).toTypedArray()) }, modifier = Modifier.testTag("remote-permission-continue")) { Text("Continue") }
            },
            dismissButton = { TextButton({ showRationale = false; ask = null }) { Text("Not now") } },
        )
    }
    RemoteContent(controller, vm, modifier, guard)
}

@Composable
fun RemoteContent(
    controller: RemoteSessionController, vm: RemoteViewModel, modifier: Modifier = Modifier,
    /** Runs the action once the transport's permissions are granted (hosting = advertises; else scans). Default: no gate. */
    guard: (hosting: Boolean, action: () -> Unit) -> Unit = { _, action -> action() },
) {
    val active by controller.isActive.collectAsState()
    val status by controller.statusMessage.collectAsState()
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)
            .testTag("remote-view"),
    ) {
        status?.let {
            Surface(Modifier.fillMaxWidth().padding(vertical = 6.dp), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
                Text(it, Modifier.padding(12.dp).testTag("remote-status"), style = MaterialTheme.typography.bodyMedium)
            }
        }
        if (active) ActiveSession(controller, vm) else StartSection(vm, guard)
        Spacer(Modifier.height(24.dp))
    }
}

// ---- Start + Join ----

@Composable
private fun StartSection(vm: RemoteViewModel, guard: (Boolean, () -> Unit) -> Unit) {
    val starter = RemoteStarters.current
    val starting by vm.starting.collectAsState()
    val joining by vm.joining.collectAsState()
    val enabled = starter.available && starting == null && !joining
    RemoteSectionHeader("Start a session")
    RemoteStartCard(
        RemoteSessionMode.LISTEN_TOGETHER, "Everyone plays the same music in sync — anyone in the session can change it.",
        Icons.Filled.Group, starting == RemoteSessionMode.LISTEN_TOGETHER, enabled,
    ) { guard(true) { vm.begin(RemoteSessionMode.LISTEN_TOGETHER) } }
    RemoteStartCard(
        RemoteSessionMode.BACKSEAT, "Your device becomes the remote. A passenger’s phone on the car stereo plays the music.",
        Icons.Filled.DirectionsCar, starting == RemoteSessionMode.BACKSEAT, enabled,
    ) { guard(true) { vm.begin(RemoteSessionMode.BACKSEAT) } }
    Text(
        if (starter.available) "Invite someone nearby with a QR code or a short code. Each device plays from its own library."
        else "Sessions need a connection that isn’t available on this build yet. Each device plays from its own library.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 6.dp).testTag("remote-start-footer"),
    )
    JoinSection(vm, starter.available && starting == null && !joining, guard)
}

@Composable
private fun JoinSection(vm: RemoteViewModel, enabled: Boolean, guard: (Boolean, () -> Unit) -> Unit) {
    val starter = RemoteStarters.current
    var code by remember { mutableStateOf("") }
    var invalid by remember { mutableStateOf(false) }
    val hosts by starter.discovered.collectAsState()
    DisposableEffect(starter) { vm.startDiscovery(); onDispose { vm.stopDiscovery() } }
    RemoteSectionHeader("Join a session")
    Text(
        "Scan the host’s QR code with your camera app, enter the code, or pick a nearby host.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        OutlinedTextField(
            value = code, onValueChange = { code = it; invalid = false }, singleLine = true,
            label = { Text("Code or link") }, isError = invalid,
            supportingText = if (invalid) ({ Text("That doesn’t look like a session code.") }) else null,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
            modifier = Modifier.weight(1f).testTag("remote-join-code"),
        )
        Spacer(Modifier.padding(4.dp))
        Button(
            onClick = { if (RemoteJoinCode.parse(code) == null) invalid = true else { val c = code; code = ""; guard(false) { vm.joinWithCode(c) } } },
            enabled = enabled && code.isNotBlank(), modifier = Modifier.testTag("remote-join"),
        ) { Text("Join") }
    }
    if (hosts.isNotEmpty()) {
        Text("Nearby", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 10.dp))
        var confirm by remember { mutableStateOf<DiscoveredHost?>(null) }
        for (h in hosts) {
            Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(h.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    h.mode?.let { Text(it.title, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                OutlinedButton({ confirm = h }, enabled = enabled, modifier = Modifier.testTag("remote-host-${h.id}")) { Text("Join") }
            }
        }
        confirm?.let { h ->
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { confirm = null },
                title = { Text("Join ${h.name}?") },
                text = { Text("You’ll hear this session’s music on this device, and can change what’s playing.") },
                confirmButton = { TextButton({ confirm = null; guard(false) { vm.joinHost(h) } }) { Text("Join") } },
                dismissButton = { TextButton({ confirm = null }) { Text("Cancel") } },
            )
        }
    }
}

// ---- Active session ----

@Composable
private fun ActiveSession(controller: RemoteSessionController, vm: RemoteViewModel) {
    val pausedHere by controller.pausedHere.collectAsState()
    val invite by RemoteStarters.current.invite.collectAsState()
    if (pausedHere) PausedHereCard(vm)
    if (controller.isHost && invite != null) InviteCard(invite!!, (RemoteStarters.current as? NearbyRemoteStarter)?.authDigits)
    SessionSection(controller, vm)
    ParticipantsSection(controller)
    NowPlayingSection(controller, vm)
    UpNextSection(controller, vm)
    AddSection(vm)
}

@Composable
private fun InviteCard(invite: RemoteInvite, authDigits: kotlinx.coroutines.flow.StateFlow<String?>? = null) {
    val digits = authDigits?.collectAsState()?.value
    RemoteSectionHeader("Invite")
    Column(Modifier.fillMaxWidth().testTag("remote-invite"), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
        JukeboxQrCard(invite.url)
        Text(invite.code, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 10.dp).testTag("remote-invite-code"))
        Text("Scan with a camera app, or enter this code under Join.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        digits?.let { Text("Connecting: $it. Check the same digits show on the other phone.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("remote-auth-digits")) }
    }
}

@Composable
private fun PausedHereCard(vm: RemoteViewModel) {
    Surface(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("remote-paused-here"), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Icon(Icons.Filled.Pause, null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.padding(4.dp))
                Text("Paused on this device — tap ▶ to rejoin", Modifier.weight(1f))
                Button({ vm.rejoin() }, Modifier.testTag("remote-rejoin")) { Text("Rejoin") }
            }
            Text("The session kept playing on the other devices.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SessionSection(controller: RemoteSessionController, vm: RemoteViewModel) {
    val mode by controller.mode.collectAsState()
    val role by controller.localRole.collectAsState()
    val peers = collectPeers(controller)
    val hostName = if (controller.isHost) "This device" else peers.firstOrNull { it.isHost }?.name ?: "Connecting…"
    RemoteSectionHeader("Session")
    Text("Mode: ${mode.title}", Modifier.testTag("remote-mode"))
    Text("Host: $hostName", Modifier.testTag("remote-host"))
    Text("This device", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 8.dp))
    Row(Modifier.testTag("remote-role"), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(role == RemoteDeviceRole.SPEAKER, { vm.setRole(RemoteDeviceRole.SPEAKER) }, { Text("Speaker") }, Modifier.testTag("remote-role-speaker"))
        FilterChip(role == RemoteDeviceRole.CONTROLLER, { vm.setRole(RemoteDeviceRole.CONTROLLER) }, { Text("Remote control") }, Modifier.testTag("remote-role-controller"))
    }
    Text(
        if (role == RemoteDeviceRole.SPEAKER) "This device plays the session’s music." else "This device plays nothing — it controls the speakers.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    TextButton({ vm.leave() }, Modifier.testTag("remote-leave")) {
        Text("Leave Session", color = MaterialTheme.colorScheme.error)
    }
}

/** The roster as UI rows, recomposing when any input of [RemoteSessionController.peers] changes. */
@Composable
private fun collectPeers(controller: RemoteSessionController): List<RemoteSessionController.Peer> {
    val roster by controller.roster.collectAsState()
    val info by controller.peerInfo.collectAsState()
    val unavail by controller.unavailableByPeer.collectAsState()
    val localUnavail by controller.localUnavailable.collectAsState()
    val role by controller.localRole.collectAsState()
    val host by controller.hostId.collectAsState()
    return remember(roster, info, unavail, localUnavail, role, host) { controller.peers }
}

/** "Unavailable on …" lookup that is re-created (so rows recompose) whenever availability changes. */
@Composable
private fun collectUnavailableOn(controller: RemoteSessionController): (String) -> List<String> {
    val unavail by controller.unavailableByPeer.collectAsState()
    val localUnavail by controller.localUnavailable.collectAsState()
    val info by controller.peerInfo.collectAsState()
    return remember(unavail, localUnavail, info) { { rid -> controller.unavailableDevices(rid) } }
}

@Composable
private fun ParticipantsSection(controller: RemoteSessionController) {
    val peers = collectPeers(controller)
    RemoteSectionHeader("Participants")
    for (p in peers) RemotePeerRow(p)
}

@Composable
private fun NowPlayingSection(controller: RemoteSessionController, vm: RemoteViewModel) {
    val state by controller.state.collectAsState()
    val unavailableOn = collectUnavailableOn(controller)
    RemoteSectionHeader("Now Playing")
    val cur = state?.currentRow
    if (cur == null) {
        Text(
            if (controller.isHost) "Nothing queued yet — add songs below." else "Waiting for the host…",
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("remote-empty"),
        )
        return
    }
    Column(Modifier.testTag("remote-now-playing")) {
        Text(cur.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(cur.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        RemoteQueueUi.unavailableText(unavailableOn(cur.rid))?.let { RemoteWarning(it) }
    }
    var pos by remember { mutableLongStateOf(controller.positionNow()) }
    LaunchedEffect(state) { while (true) { pos = controller.positionNow(); delay(500) } }
    RemoteScrubber(pos, cur.row.lengthMs, vm::seek)
    RemoteTransportRow(state?.isPlaying == true, vm::previous, vm::playPause, vm::next)
    val repeat = state?.repeatMode ?: RepeatMode.OFF
    val shuffle = state?.shuffleEnabled == true
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        IconButton(vm::cycleRepeat, Modifier.testTag("remote-repeat")) {
            Icon(
                if (repeat == RepeatMode.ONE) Icons.Filled.RepeatOne else Icons.Filled.Repeat, "Repeat",
                tint = if (repeat == RepeatMode.OFF) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
            )
        }
        IconButton(vm::toggleShuffle, Modifier.testTag("remote-shuffle")) {
            Icon(
                Icons.Filled.Shuffle, "Shuffle",
                tint = if (shuffle) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun UpNextSection(controller: RemoteSessionController, vm: RemoteViewModel) {
    val state by controller.state.collectAsState()
    val unavailableOn = collectUnavailableOn(controller)
    val rows = remember(state) { RemoteQueueUi.upcoming(state) }
    if (rows.isEmpty()) return
    RemoteSectionHeader("Up Next")
    RemoteUpNextList(
        rows, unavailableOn = unavailableOn,
        onPlayNow = vm::playNow, onPlayNext = vm::playNext, onRemove = vm::remove, onReorder = vm::reorder,
    )
}

@Composable
private fun AddSection(vm: RemoteViewModel) {
    val query by vm.query.collectAsState()
    val results by vm.results.collectAsState()
    RemoteSectionHeader("Add Songs")
    OutlinedTextField(
        value = query, onValueChange = vm::setQuery, singleLine = true, label = { Text("Search your library") },
        modifier = Modifier.fillMaxWidth().testTag("remote-search"),
    )
    for (song in results) {
        RemoteSearchRow(
            song,
            onNow = { vm.add(song, AddPlacement.NOW) }, onNext = { vm.add(song, AddPlacement.NEXT) }, onEnd = { vm.add(song, AddPlacement.END) },
        )
    }
}
