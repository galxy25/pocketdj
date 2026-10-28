package com.levi.pocketdj.screens.jukebox

import android.content.Intent
import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCode2
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.jukebox.JukeboxDecisionAction
import com.levi.pocketdj.data.jukebox.JukeboxLink
import com.levi.pocketdj.data.jukebox.JukeboxGraph
import com.levi.pocketdj.data.jukebox.JukeboxRepository
import com.levi.pocketdj.data.jukebox.JukeboxSessionInfo
import com.levi.pocketdj.data.jukebox.JukeboxSettings
import com.levi.pocketdj.di.AppGraph

/**
 * Jukebox Hero, DJ side (specs/jukebox.md §6): three states — not configured
 * (points to Settings), create view, and the live session view (QR + session
 * toggles + on-air + request inbox + played history + end).
 *
 * The session engine is app-scoped ([JukeboxRepository]); this screen only
 * renders its state, so navigation away never stops the party.
 */
@Composable
fun JukeboxScreen(modifier: Modifier = Modifier, onOpenJoin: (String) -> Unit = {}) {
    val context = LocalContext.current
    val graph = remember(context) { JukeboxGraph.get(context) }
    val appGraph = remember(context) { AppGraph.get(context) }
    LaunchedEffect(Unit) { graph.repository.bootstrap() }

    val state by graph.repository.state.collectAsState()
    val settings by appGraph.settings.settings.collectAsState(initial = null)
    val joined by graph.joined.sessions.collectAsState()
    var joinDialog by remember { mutableStateOf(false) }
    val loadedSettings = settings ?: return
    val pocketDjName by appGraph.settings.flow(com.levi.pocketdj.onboarding.OnboardingPrefs.PROFILE_NAME)
        .collectAsState(initial = "")

    Column(modifier.fillMaxSize()) {
        // Guest strip: joined jukeboxes above whichever host state is showing (iOS safeAreaInset top).
        if (joined.isNotEmpty() || joinDialog || state.session != null) {
            JoinedSessionsStrip(
                sessions = joined,
                onOpen = onOpenJoin,
                onLeave = graph.joined::remove,
                onJoinByLink = { joinDialog = true },
            )
        }
        Box(Modifier.weight(1f)) {
            when {
                state.session != null -> LiveView(
                    state = state,
                    repository = graph.repository,
                )
                loadedSettings.jukeboxServerUrl.isBlank() -> NotConfiguredView(
                    onJoinByLink = if (joined.isEmpty()) ({ joinDialog = true }) else null,
                )
                else -> CreateView(
                    state = state,
                    defaultRequireToken = loadedSettings.jukeboxTokensRequiredByDefault,
                    defaultName = JukeboxSettings.defaultSessionName(pocketDjName),
                    onStart = graph.repository::start,
                    onJoinByLink = if (joined.isEmpty()) ({ joinDialog = true }) else null,
                )
            }
        }
    }
    if (joinDialog) {
        JoinByLinkDialog(
            onDismiss = { joinDialog = false },
            onJoin = { link ->
                graph.joined.addJoined(link)
                joinDialog = false
                onOpenJoin(link.jukeboxId)
            },
        )
    }
}

/** Manual "Join by link or id" entry (also the emulator-verifiable path without a deep link). */
@Composable
private fun JoinByLinkDialog(onDismiss: () -> Unit, onJoin: (JukeboxLink) -> Unit) {
    var text by remember { mutableStateOf("") }
    val link = JukeboxLink.parseLoose(text)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Join a jukebox") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                label = { Text("Link or id") },
                singleLine = true,
                isError = text.isNotBlank() && link == null,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(onClick = { link?.let(onJoin) }, enabled = link != null) { Text("Join") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ---- not configured --------------------------------------------------------

@Composable
private fun NotConfiguredView(modifier: Modifier = Modifier, onJoinByLink: (() -> Unit)? = null) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.QrCode2,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "Jukebox Hero",
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Guests scan a QR code to see what's playing and request songs. " +
                "Set the jukebox server URL in Settings to start a party.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        onJoinByLink?.let { TextButton(onClick = it) { Text("Join a jukebox by link\u2026") } }
    }
}

// ---- create view -----------------------------------------------------------

@Composable
private fun CreateView(
    state: JukeboxRepository.UiState,
    defaultRequireToken: Boolean,
    defaultName: String,
    onStart: (name: String, requiresToken: Boolean) -> Unit,
    modifier: Modifier = Modifier,
    onJoinByLink: (() -> Unit)? = null,
) {
    var name by remember { mutableStateOf("") }
    // Seeded from the Settings default each time the create view appears (§6).
    var requireToken by remember { mutableStateOf(defaultRequireToken) }
    LaunchedEffect(defaultRequireToken) { requireToken = defaultRequireToken }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = "Start a jukebox",
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = "Guests scan a QR code to see what's playing and request songs.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        state.notice?.let { notice ->
            Text(
                text = notice,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Session name") },
            placeholder = { Text(defaultName) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        ToggleRow(
            title = "Require access token",
            // §9: intent only — never claim the link is gated.
            caption = "Saved with the session for a future guest-access gate.",
            checked = requireToken,
            onCheckedChange = { requireToken = it },
        )
        Button(
            onClick = { onStart(name, requireToken) },
            enabled = !state.starting,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (state.starting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
                Spacer(Modifier.width(8.dp))
            }
            Text(if (state.starting) "Starting…" else "Start Jukebox")
        }
        onJoinByLink?.let { TextButton(onClick = it) { Text("Join a jukebox by link\u2026") } }
    }
}

// ---- live view -------------------------------------------------------------

@Composable
private fun LiveView(
    state: JukeboxRepository.UiState,
    repository: JukeboxRepository,
    modifier: Modifier = Modifier,
) {
    val session = state.session ?: return
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var confirmEnd by remember { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 1. QR section.
        Text(
            text = session.name.ifBlank { JukeboxRepository.DEFAULT_SESSION_NAME },
            style = MaterialTheme.typography.headlineSmall,
            color = MaterialTheme.colorScheme.onBackground,
            textAlign = TextAlign.Center,
        )
        JukeboxQrCard(url = session.url)
        Text(
            text = "Scan to see what's playing and request a song",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, session.url)
                }
                context.startActivity(Intent.createChooser(send, "Share jukebox link"))
            }) { Text("Share") }
            TextButton(onClick = { clipboard.setText(AnnotatedString(session.url)) }) {
                Text("Copy link")
            }
        }
        state.transientError?.let { hint ->
            Text(
                text = "Reconnecting — $hint",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }

        // 2. Session section.
        SectionCard(title = "Session") {
            ToggleRow(
                title = "View + Hear",
                caption = if (state.hear) {
                    "Guests can also listen along to public rips from their phones."
                } else {
                    "View-only: guests see what's playing but don't hear audio."
                },
                checked = state.hear,
                onCheckedChange = repository::setHear,
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            ToggleRow(
                title = "Require access token",
                caption = "Saved with the session for a future guest-access gate.",
                checked = session.requiresToken ?: false,
                onCheckedChange = repository::setRequiresTokenIntent,
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            Text(
                text = expiryLine(session),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // 3. On air section.
        SectionCard(title = "On air") {
            OnAirBody(state)
        }

        // 4. Requests section.
        SectionCard(title = "Requests (${state.requests.size})") {
            if (state.requests.isEmpty()) {
                Text(
                    text = "No requests yet — waiting for guests.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                state.requests.forEachIndexed { index, row ->
                    if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline)
                    RequestRowView(
                        row = row,
                        mixOwns = state.mixOwns,
                        onDecide = { action -> repository.decide(row.request.id, action) },
                    )
                }
            }
        }

        // Played history (locally mirrors the broker's derivation, §1).
        if (state.played.isNotEmpty()) {
            SectionCard(title = "Played") {
                state.played.forEachIndexed { index, entry ->
                    if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline)
                    Column(modifier = Modifier.padding(vertical = 4.dp)) {
                        Text(
                            text = listOf(entry.title, entry.artist)
                                .filter { it.isNotBlank() }
                                .joinToString(" — "),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = DateUtils.getRelativeTimeSpanString(
                                entry.atMs,
                                System.currentTimeMillis(),
                                DateUtils.MINUTE_IN_MILLIS,
                            ).toString(),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        // 5. End section.
        Button(
            onClick = { confirmEnd = true },
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.error,
                contentColor = MaterialTheme.colorScheme.onError,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("End Jukebox") }
    }

    if (confirmEnd) {
        AlertDialog(
            onDismissRequest = { confirmEnd = false },
            title = { Text("End this jukebox?") },
            text = {
                Text(
                    "Guests' pages will show the party has ended. " +
                        "Playback on this device keeps going.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmEnd = false
                    repository.end()
                }) { Text("End Jukebox", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmEnd = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun OnAirBody(state: JukeboxRepository.UiState) {
    val context = LocalContext.current
    val nowPlaying by remember(context) {
        AppGraph.get(context).playbackController.nowPlaying
    }.collectAsState()

    val current = nowPlaying
    if (current == null) {
        Text(
            text = "Nothing playing — the first accepted request starts the music.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    } else {
        Text(
            text = listOfNotNull(current.title, current.artist)
                .filter { it.isNotBlank() }
                .joinToString(" — ")
                .ifBlank { current.songId },
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = if (state.upNextCount == 1) "1 up next" else "${state.upNextCount} up next",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RequestRowView(
    row: JukeboxRepository.RequestRow,
    mixOwns: Boolean = false,
    onDecide: (JukeboxDecisionAction) -> Unit,
) {
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Text(
            text = buildString {
                append("“${row.request.title}”")
                if (row.request.artist.isNotBlank()) append(" — ${row.request.artist}")
            },
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        when (val match = row.match) {
            is JukeboxRepository.Match.Searching -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                Text(
                    text = "Matching…",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            is JukeboxRepository.Match.None -> Text(
                text = "No match found",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            is JukeboxRepository.Match.Found -> Text(
                text = buildString {
                    append("Match: ${match.song.name} — ${match.song.artist}")
                    if (!match.playable) append(if (mixOwns) " (will burn into the mix)" else " (no audio yet)")
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (match.playable) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
        }
        // A live auto mix accepts a match that is not on disk yet (it burns + parks it), so only a
        // missing match disables the placement buttons while mixing.
        val found = row.match as? JukeboxRepository.Match.Found
        val playable = found != null && (found.playable || mixOwns)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { onDecide(JukeboxDecisionAction.DENIED) }) {
                Text(JukeboxDecisionAction.DENIED.label, color = MaterialTheme.colorScheme.error)
            }
            listOf(
                JukeboxDecisionAction.NEXT,
                JukeboxDecisionAction.END,
                JukeboxDecisionAction.RANDOM,
            ).forEach { action ->
                TextButton(onClick = { onDecide(action) }, enabled = playable) {
                    Text(action.label)
                }
            }
        }
    }
}

// ---- shared bits -----------------------------------------------------------

@Composable
private fun SectionCard(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            content()
        }
    }
}

@Composable
private fun ToggleRow(
    title: String,
    caption: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = caption,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

private fun expiryLine(session: JukeboxSessionInfo): String {
    val expiresAt = session.expiresAt?.toLong()
    return if (expiresAt != null) {
        val relative = DateUtils.getRelativeTimeSpanString(
            expiresAt,
            System.currentTimeMillis(),
            DateUtils.MINUTE_IN_MILLIS,
        )
        "Ends $relative; cleaned up 7 days after start."
    } else {
        "Sessions end after 24 hours and are cleaned up 7 days after start."
    }
}
