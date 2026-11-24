package com.levi.pocketdj.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.remote.InMemoryRemoteTarget
import com.levi.pocketdj.remote.LoopbackHub
import com.levi.pocketdj.remote.RemoteQueueModel
import com.levi.pocketdj.remote.RemoteRow
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import com.levi.pocketdj.remote.RemoteSongResolver
import com.levi.pocketdj.remote.SharedClock
import com.levi.pocketdj.screens.remote.RemoteContent
import com.levi.pocketdj.screens.remote.RemoteStarters
import com.levi.pocketdj.screens.remote.RemoteViewModel

/**
 * Debug showcase for the Remote screen (P2-REM-7): two in-memory devices over a [LoopbackHub], the host running a
 * speaker that advances on commands, the guest's screen shown full-screen. Debug builds only (reached from Settings > Debug).
 */
@Composable
internal fun RemoteLoopbackDialog(songs: List<IndexSong>, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val rig = remember {
        val hub = LoopbackHub()
        fun mk(id: String, name: String): Triple<RemoteSessionController, InMemoryRemoteTarget, com.levi.pocketdj.remote.LoopbackTransport> {
            val link = hub.join(id)
            val target = InMemoryRemoteTarget()
            val clock = SharedClock()
            val c = RemoteSessionController(
                target = target, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
                deviceName = { name }, platform = "android", clock = clock, scope = scope,
            )
            c.speaker = com.levi.pocketdj.remote.RemoteReconciler(c, target, clock)
            return Triple(c, target, link)
        }
        val host = mk("a-host", "Showcase speaker")
        val guest = mk("b-guest", "This phone")
        val rows = songs.take(6).map { s ->
            RemoteRow("r-${s.id}", SessionRow(songId = s.id, title = s.name, artist = s.artist, lengthMs = s.length ?: 180_000))
        }
        val seed = RemoteQueueModel(rows = rows, index = 0, isPlaying = true, anchor = System.currentTimeMillis().toDouble(), revision = 1)
        host.first.attach(host.third, RemoteSessionMode.LISTEN_TOGETHER, asHost = true, seed = seed)
        guest.first.attach(guest.third, RemoteSessionMode.LISTEN_TOGETHER, asHost = false)
        Triple(host, guest, hub)
    }
    val (host, guest, hub) = rig
    val vm = remember { RemoteViewModel(guest.first, { RemoteStarters.current }, { songs }, scope) }
    val hostState by host.first.state.collectAsState()
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { runCatching { guest.first.leave() }; runCatching { host.first.leave() }; runCatching { hub.end() } }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.padding(top = 32.dp)) {
                Text("Speaker (host) rev=${hostState?.revision} log=${host.second.log.takeLast(3)}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp))
                OutlinedButton(onClick = onDismiss, modifier = Modifier.padding(horizontal = 16.dp)) { Text("Close loopback") }
                RemoteContent(guest.first, vm, Modifier.weight(1f))
            }
        }
    }
}
