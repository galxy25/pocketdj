package com.levi.pocketdj.screens.jukebox

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.jukebox.JukeboxGraph
import com.levi.pocketdj.data.jukebox.JukeboxGuestException
import com.levi.pocketdj.data.jukebox.JukeboxGuestState
import com.levi.pocketdj.data.jukebox.JukeboxLink
import com.levi.pocketdj.data.jukebox.JukeboxTuneIn
import com.levi.pocketdj.data.jukebox.TuneInSeekMath
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

const val JOIN_POLL_MS = 4_000L

/** Request-status colour bucket (kept pure for the screen + tests). */
enum class RequestTone { Pending, Accepted, Denied }

fun requestTone(status: String?): RequestTone = when (status) {
    "queued", "played" -> RequestTone.Accepted
    "denied" -> RequestTone.Denied
    else -> RequestTone.Pending
}

/**
 * The pushed guest panel for a joined jukebox (iOS `JukeboxJoinView`). It owns its own 4 s poll of the
 * public state.json (the `LaunchedEffect` is cancelled when the panel leaves composition, so nothing
 * polls in the background), submits requests with the install clientId, and can Tune In to the party.
 */
@Composable
fun JukeboxJoinScreen(
    jukeboxId: String,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember(context) { JukeboxGraph.get(context) }
    val appGraph = remember(context) { AppGraph.get(context) }
    val sessions by graph.joined.sessions.collectAsState()
    val entry = sessions.firstOrNull { it.id == jukeboxId }
    val link = remember(jukeboxId, entry?.guestBase) {
        JukeboxLink.forEntry(jukeboxId, entry?.guestBase)
    }

    var state by remember(jukeboxId) { mutableStateOf<JukeboxGuestState?>(null) }
    var loading by remember(jukeboxId) { mutableStateOf(true) }
    var error by remember(jukeboxId) { mutableStateOf<String?>(null) }
    var myIds by rememberSaveable(jukeboxId) { mutableStateOf(setOf<String>()) }
    var myKeys by rememberSaveable(jukeboxId) { mutableStateOf(setOf<String>()) }
    var clientId by remember { mutableStateOf("") }
    var reqTitle by remember { mutableStateOf("") }
    var reqArtist by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    val tuneIn = androidx.lifecycle.viewmodel.compose.viewModel<JukeboxTuneIn>(
        key = "jukebox-tunein-$jukeboxId",
        factory = object : androidx.lifecycle.ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T =
                JukeboxTuneIn(appGraph.appScope) { u -> appGraph.playbackController.stopUrl(u) } as T
        },
    )
    val tunedIn by tuneIn.tunedIn.collectAsState()
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { clientId = appGraph.settings.ensureInstallId() }

    // The 4 s poll. Runs only while this composable is on screen; stops on an ended session.
    LaunchedEffect(jukeboxId, link) {
        if (link == null) {
            loading = false
            error = "This jukebox link is invalid."
            return@LaunchedEffect
        }
        while (true) {
            try {
                val s = graph.guestClient.guestState(link)
                state = s
                loading = false
                error = null
                graph.joined.updateName(jukeboxId, s.name)
                if (s.isEnded) break
            } catch (e: CancellationException) {
                throw e
            } catch (e: JukeboxGuestException) {
                loading = false
                if (e.isEnded) {
                    state = (state ?: JukeboxGuestState.EMPTY).markEnded()
                    error = null
                    break
                }
                error = e.message
            } catch (e: Exception) {
                loading = false
                error = e.message ?: "Couldn't reach the jukebox"
            }
            delay(JOIN_POLL_MS)
        }
    }

    val current = state
    val ended = current?.isEnded == true
    val np = current?.nowPlaying
    val canTune = current?.canTuneIn == true

    // Tune In: start on toggle, and re-tune whenever the heard track changes (key includes the stream).
    val trackKey = TuneInSeekMath.trackKey(np)
    LaunchedEffect(tunedIn, trackKey, canTune, ended) {
        if (!tunedIn) return@LaunchedEffect
        val s = state
        val playing = s?.nowPlaying
        val url = playing?.streamUrl
        if (ended || s == null || playing == null || !canTune || url == null) {
            tuneIn.stop()
            return@LaunchedEffect
        }
        val seek = TuneInSeekMath.seekMs(
            positionMs = playing.positionMs,
            updatedAtMs = s.updatedAt,
            nowMs = System.currentTimeMillis(),
            lengthMs = playing.lengthMs,
        )
        tuneIn.noteStarted(url)
        appGraph.playbackController.playUrl(playing.title.orEmpty(), playing.artist, url, seek)
    }
    // Composition dispose deliberately does NOT stop the stream (rotation / mini-player push);
    // the entry-scoped JukeboxTuneIn stops it on pop, Stop, Leave or ended.

    fun submit() {
        val title = reqTitle.trim()
        val artist = reqArtist.trim()
        if (title.isEmpty() || submitting) return
        submitting = true
        scope.launch {
            try {
                val id = graph.guestClient.submitRequest(jukeboxId, current?.apiBase, title, artist)
                if (id != null) myIds = myIds + id
                myKeys = myKeys + JukeboxGuestState.requestKey(title, artist)
                error = null
                reqTitle = ""
                reqArtist = ""
            } catch (e: CancellationException) {
                throw e
            } catch (e: JukeboxGuestException) {
                if (e.isEnded) {
                    state = (state ?: JukeboxGuestState.EMPTY).markEnded()
                    error = null
                } else {
                    error = e.message
                }
            } catch (e: Exception) {
                error = e.message ?: "Request failed"
            }
            submitting = false
        }
    }

    fun leave() {
        tuneIn.stop()
        graph.joined.remove(jukeboxId)
        onClose()
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    current?.name ?: entry?.name ?: "Jukebox",
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = ::leave, modifier = Modifier.testTag("jukebox-join-leave")) {
                    Text("Leave", color = MaterialTheme.colorScheme.error)
                }
            }
        }
        if (current == null) {
            item {
                val err = error
                if (err != null) {
                    Text(err, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
                } else if (loading) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Connecting…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        if (ended) {
            item {
                Text(
                    com.levi.pocketdj.data.jukebox.JukeboxGuestClient.ENDED_MESSAGE,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp).testTag("jukebox-join-ended"),
                )
            }
        }
        if (np != null && np.hasContent) {
            item { SectionHeader("Now playing") }
            item {
                Column(Modifier.padding(horizontal = 16.dp).testTag("jukebox-join-nowplaying")) {
                    TrackLine(np.title, np.artist, headline = true)
                    if (canTune) {
                        OutlinedButton(
                            onClick = { if (tunedIn) tuneIn.stop() else tuneIn.requestTuneIn() },
                            modifier = Modifier.padding(top = 8.dp).testTag("jukebox-join-tunein"),
                        ) { Text(if (tunedIn) "Stop" else "Tune In") }
                    }
                }
            }
        }
        if (!ended) {
            item { SectionHeader("Request a song") }
            item {
                Column(
                    Modifier.padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = reqTitle, onValueChange = { reqTitle = it },
                        label = { Text("Title") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("jukebox-join-req-title"),
                    )
                    OutlinedTextField(
                        value = reqArtist, onValueChange = { reqArtist = it },
                        label = { Text("Artist (optional)") }, singleLine = true,
                        keyboardOptions = KeyboardOptions.Default,
                        modifier = Modifier.fillMaxWidth().testTag("jukebox-join-req-artist"),
                    )
                    Button(
                        onClick = ::submit,
                        enabled = reqTitle.isNotBlank() && !submitting,
                        modifier = Modifier.testTag("jukebox-join-request"),
                    ) {
                        if (submitting) {
                            CircularProgressIndicator(
                                Modifier.size(16.dp), strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary,
                            )
                            Spacer(Modifier.width(8.dp))
                        }
                        Text("Request")
                    }
                    if (current != null) error?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
        val up = current?.upNext.orEmpty()
        if (up.isNotEmpty()) {
            item { SectionHeader("Up next") }
            items(up.size) { i ->
                Box16 { TrackLine(up[i].title, up[i].artist) }
            }
        }
        val requests = current?.requests.orEmpty()
        if (requests.isNotEmpty()) {
            item { SectionHeader("Requests") }
            items(requests.size) { i ->
                val r = requests[i]
                val mine = current?.isMine(r, clientId, myIds, myKeys) == true
                val tone = requestTone(r.status)
                val bg = if (mine) MaterialTheme.colorScheme.primary.copy(alpha = 0.14f) else Color.Transparent
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(bg)
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .testTag(if (mine) "jukebox-join-request-mine" else "jukebox-join-request-other"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        TrackLine(r.title, r.artist, bold = mine)
                    }
                    Text(
                        (r.status ?: "pending").replaceFirstChar { it.uppercase() },
                        style = MaterialTheme.typography.labelMedium,
                        color = when (tone) {
                            RequestTone.Accepted -> MaterialTheme.colorScheme.primary
                            RequestTone.Denied -> MaterialTheme.colorScheme.error
                            RequestTone.Pending -> MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            }
        }
        val played = current?.played.orEmpty()
        if (played.isNotEmpty()) {
            item { SectionHeader("Recently played") }
            items(minOf(played.size, 10)) { i ->
                Box16 { TrackLine(played[i].title, played[i].artist) }
            }
        }
        item { Spacer(Modifier.size(16.dp)) }
    }
}

@Composable
private fun Box16(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) { content() }
}

@Composable
private fun SectionHeader(text: String) {
    Column(Modifier.padding(top = 12.dp)) {
        HorizontalDivider()
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun TrackLine(title: String?, artist: String?, headline: Boolean = false, bold: Boolean = false) {
    Column {
        Text(
            if (title.isNullOrEmpty()) "—" else title,
            style = if (headline) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium,
            fontWeight = if (bold) FontWeight.SemiBold else null,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (!artist.isNullOrEmpty()) {
            Text(
                artist,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
