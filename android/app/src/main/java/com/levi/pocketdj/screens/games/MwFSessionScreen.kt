package com.levi.pocketdj.screens.games

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.friends.MwFException
import com.levi.pocketdj.data.games.friends.MwFSettings
import com.levi.pocketdj.data.games.friends.MwFState
import com.levi.pocketdj.data.games.friends.MwFSuggestion
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.screens.jukebox.JukeboxQrCard
import com.levi.pocketdj.shell.NavRequestBus
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The live session screen (iOS `MusicWithFriendsSessionView`). It owns the 4 s poll via a
 * LaunchedEffect: leaving the screen cancels it, and it stops on its own once the session ended.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MwFSessionScreen(graph: AppGraph, sessionId: String, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val friends = graph.gamesGraph.friends
    val sessions by friends.sessions.collectAsState()
    val states by friends.lastState.collectAsState()
    val verbErrors by friends.lastErrors.collectAsState()
    val pollErrors by friends.pollErrors.collectAsState()
    val queueAccepted by friends.queueAccepted.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    val entry = sessions.firstOrNull { it.id == sessionId }
    val state: MwFState? = states[sessionId]
    val youId = entry?.memberId
    val isLeader = entry?.isLeader == true
    val ended = state?.ended == true

    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var suggestTitle by remember { mutableStateOf("") }
    var suggestArtist by remember { mutableStateOf("") }
    var suggestError by remember { mutableStateOf<String?>(null) }
    var showEndConfirm by remember { mutableStateOf(false) }
    val approving: SnapshotStateList<String> = remember { mutableStateListOf() }
    var downloadedPocketId by remember { mutableStateOf<String?>(null) }
    var downloadNote by remember { mutableStateOf<String?>(null) }
    var showDownloadDone by remember { mutableStateOf(false) }

    // The 4 s poll: auto-cancelled when the screen leaves composition.
    LaunchedEffect(sessionId) {
        while (isActive) {
            friends.refresh(sessionId)
            if (!MwFScreenLogic.shouldKeepPolling(friends.lastState.value[sessionId])) break
            delay(MwFScreenLogic.POLL_INTERVAL_MS)
        }
    }
    // 1 s clock for the turn countdown / relative labels.
    LaunchedEffect(sessionId) {
        while (isActive) { now = System.currentTimeMillis(); delay(1_000) }
    }

    Column(modifier.fillMaxSize().testTag("mwf-session-screen")) {
        TopAppBar(
            title = { Text(entry?.name ?: "Music with Friends", maxLines = 1) },
            navigationIcon = {
                IconButton(onClick = onClose, modifier = Modifier.testTag("mwf-session-back")) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
        )
        if (entry == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Session not found") }
            return@Column
        }
        val nowD = now.toDouble()
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Header: theme + expiry
            item {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(state?.theme ?: entry.theme.orEmpty(), style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag("mwf-theme"))
                    (state?.expiresAt ?: entry.expiresAt)?.let {
                        Text(MwFScreenLogic.expiresLabel(it, nowD), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("mwf-expires"))
                    }
                }
            }
            item {
                if (ended) {
                    Card(Modifier.fillMaxWidth().testTag("mwf-ended-banner")) {
                        Column(Modifier.padding(12.dp)) {
                            Text("Session over", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.tertiary)
                            state?.let { Text("Your score: ${friends.myScore(it)} — recorded to Scoreboard", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                } else {
                    val isYou = state?.turn?.memberId != null && state.turn.memberId == youId
                    Card(Modifier.fillMaxWidth().testTag("mwf-turn-banner")) {
                        Column(Modifier.padding(12.dp)) {
                            Text(
                                MwFScreenLogic.turnHeadline(state, youId),
                                style = MaterialTheme.typography.titleMedium,
                                color = if (isYou) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurface,
                            )
                            state?.turn?.deadline?.let {
                                Text(MwFScreenLogic.leftLabel(MwFScreenLogic.remainingSeconds(it, nowD)), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            // Invite
            entry.url?.takeIf { it.isNotBlank() }?.let { url ->
                item {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Invite friends", style = MaterialTheme.typography.titleSmall, modifier = Modifier.fillMaxWidth())
                        JukeboxQrCard(url, Modifier.testTag("mwf-share-qr"))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(
                                onClick = {
                                    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                                        .putExtra(Intent.EXTRA_TEXT, url)
                                    runCatching { context.startActivity(Intent.createChooser(send, "Share link").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                                },
                                modifier = Modifier.testTag("mwf-share-link"),
                            ) { Icon(Icons.Filled.Share, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Share link") }
                            OutlinedButton(onClick = { clipboard.setText(AnnotatedString(url)) }, modifier = Modifier.testTag("mwf-share-copy")) {
                                Icon(Icons.Filled.ContentCopy, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Copy Link")
                            }
                        }
                    }
                }
            }
            // Per-session verb error + poll error
            verbErrors[sessionId]?.let { err ->
                item { Text(err, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("mwf-session-error")) }
            }
            if (!ended) pollErrors[sessionId]?.let { perr ->
                item {
                    Column(Modifier.testTag("mwf-poll-error"), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Can’t reach the server — showing the last known state.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        Text(perr, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        state?.updatedAt?.let {
                            Text("Last updated ${MwFScreenLogic.agoLabel(it, nowD)} ago", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            // Leaderboard
            item { Text("Leaderboard", style = MaterialTheme.typography.titleSmall) }
            items(MwFScreenLogic.sortedMembers(state).size) { i ->
                val m = MwFScreenLogic.sortedMembers(state)[i]
                Row(Modifier.fillMaxWidth().testTag("mwf-member-${m.memberId}"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (m.isLeader == true) Icon(Icons.Filled.WorkspacePremium, "Leader", Modifier.size(16.dp), tint = MaterialTheme.colorScheme.tertiary)
                    Text(m.name ?: "Player")
                    if (m.memberId == youId) Text("(you)", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f))
                    Text("${m.score ?: 0}", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                }
            }
            // Composer
            if (!ended) item {
                val canSuggest = MwFScreenLogic.canSuggestNow(state, youId)
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Suggest a song", style = MaterialTheme.typography.titleSmall)
                    OutlinedTextField(suggestTitle, { suggestTitle = it }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("mwf-suggest-title"))
                    OutlinedTextField(suggestArtist, { suggestArtist = it }, label = { Text("Artist") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("mwf-suggest-artist"))
                    Button(
                        enabled = canSuggest && suggestTitle.isNotBlank(),
                        onClick = {
                            val t = suggestTitle.trim()
                            val a = suggestArtist.trim()
                            if (t.isEmpty()) return@Button
                            suggestError = null
                            scope.launch {
                                try {
                                    friends.suggest(sessionId, t, a)
                                    suggestTitle = ""; suggestArtist = ""
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: MwFException) {
                                    suggestError = MwFScreenLogic.suggestErrorMessage(e.code, e.message)
                                } catch (e: Exception) {
                                    suggestError = MwFScreenLogic.suggestErrorMessage(null, e.message)
                                }
                            }
                        },
                        modifier = Modifier.testTag("mwf-suggest-submit"),
                    ) { Text("Suggest") }
                    suggestError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("mwf-suggest-error")) }
                    if (!canSuggest) Text(MwFScreenLogic.waitHint(state), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            // Feed (newest first)
            item { Text("Suggestions", style = MaterialTheme.typography.titleSmall) }
            val feed = MwFScreenLogic.feed(state)
            if (feed.isEmpty()) item { Text("No suggestions yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            items(feed.size, key = { feed[it].id ?: "idx$it" }) { i ->
                val sg = feed[i]
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text("${sg.title ?: "?"} — ${sg.artist ?: "?"}", style = MaterialTheme.typography.bodyMedium)
                        Text(MwFScreenLogic.memberName(state, sg.memberId), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    MwFStatusChip(sg.status ?: "pending")
                    val sgId = sg.id
                    if (sg.status == "accepted" && sgId != null) {
                        OutlinedButton(
                            enabled = MwFScreenLogic.plusOneEnabled(sg, youId, ended),
                            onClick = { scope.launch { friends.plusOne(sessionId, sgId) } },
                            modifier = Modifier.testTag("mwf-plusone-$sgId"),
                        ) { Text("+1 (${sg.plusOnes?.size ?: 0})") }
                    }
                }
            }
            // Leader inbox + settings
            if (isLeader && !ended) {
                item { Text("Leader inbox", style = MaterialTheme.typography.titleSmall) }
                val inbox = MwFScreenLogic.pendingInbox(state)
                if (inbox.isEmpty()) item { Text("No pending suggestions.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(inbox.size, key = { "inbox-" + (inbox[it].id ?: it) }) { i ->
                    InboxRow(
                        sg = inbox[i], state = state, busy = inbox[i].id in approving,
                        onAccept = { sg ->
                            val sgId = sg.id ?: return@InboxRow
                            approving.add(sgId)
                            scope.launch { try { friends.approve(sessionId, sg) } finally { approving.remove(sgId) } }
                        },
                        onReject = { sg -> scope.launch { friends.reject(sessionId, sg) } },
                    )
                }
                item {
                    val s = state?.settings
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Session settings", style = MaterialTheme.typography.titleSmall)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("mwf-config-turn")) {
                            for ((secs, label) in MwFScreenLogic.TURN_CHOICES) {
                                FilterChip(
                                    selected = (s?.turnSeconds ?: 120) == secs,
                                    onClick = { scope.launch { friends.updateSettings(sessionId, MwFSettings(turnSeconds = secs)) } },
                                    label = { Text(label) },
                                )
                            }
                        }
                        SwitchRow("Accept suggestions outside turns", s?.acceptOutsideTurn ?: false, { on -> scope.launch { friends.updateSettings(sessionId, MwFSettings(acceptOutsideTurn = on)) } }, "mwf-config-outside")
                        SwitchRow("Turn ends on first suggestion", s?.turnEndsOnFirstSuggestion ?: true, { on -> scope.launch { friends.updateSettings(sessionId, MwFSettings(turnEndsOnFirstSuggestion = on)) } }, "mwf-config-first")
                        SwitchRow("Queue accepted songs", queueAccepted, { friends.setQueueAccepted(it) }, "mwf-queue-accepted")
                    }
                }
            }
            // Collection
            item {
                val count = state?.collection?.size ?: 0
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(MwFScreenLogic.collectionLine(count), style = MaterialTheme.typography.bodyMedium)
                    OutlinedButton(
                        enabled = count > 0,
                        onClick = {
                            val st = state ?: return@OutlinedButton
                            val r = friends.downloadCollection(sessionId, st)
                            downloadedPocketId = r?.pocketId
                            downloadNote = when {
                                r == null -> "None of these songs are in your library yet."
                                r.unresolved > 0 -> "Saved to My Collections as a pocket. ${r.unresolved} not in your library."
                                else -> "Saved to My Collections as a pocket."
                            }
                            showDownloadDone = true
                        },
                        modifier = Modifier.testTag("mwf-download-collection"),
                    ) { Text("Download to My Collections") }
                }
            }
            // End / Leave
            item {
                if (isLeader && !ended) {
                    TextButton(onClick = { showEndConfirm = true }, modifier = Modifier.testTag("mwf-end")) {
                        Text("End Session", color = MaterialTheme.colorScheme.error)
                    }
                } else if (!isLeader) {
                    TextButton(onClick = { friends.leave(sessionId); onClose() }, modifier = Modifier.testTag("mwf-leave")) {
                        Text("Leave", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }

    if (showEndConfirm) {
        AlertDialog(
            onDismissRequest = { showEndConfirm = false },
            title = { Text("End this session for everyone?") },
            confirmButton = {
                TextButton(onClick = { showEndConfirm = false; scope.launch { friends.endSession(sessionId) } }, modifier = Modifier.testTag("mwf-end-confirm")) {
                    Text("End Session", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { showEndConfirm = false }) { Text("Cancel") } },
        )
    }
    if (showDownloadDone) {
        val pid = downloadedPocketId
        AlertDialog(
            onDismissRequest = { showDownloadDone = false },
            title = { Text(if (pid != null) "Collection downloaded" else "Nothing to download") },
            text = { Text(downloadNote.orEmpty()) },
            confirmButton = {
                if (pid != null) {
                    TextButton(
                        onClick = { showDownloadDone = false; NavRequestBus.post(ShellRoute.Pocket(pid)) },
                        modifier = Modifier.testTag("mwf-download-open"),
                    ) { Text("Open") }
                }
            },
            dismissButton = { TextButton(onClick = { showDownloadDone = false }) { Text("OK") } },
        )
    }
}

@Composable
private fun InboxRow(
    sg: MwFSuggestion,
    state: MwFState?,
    busy: Boolean,
    onAccept: (MwFSuggestion) -> Unit,
    onReject: (MwFSuggestion) -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f)) {
            Text("${sg.title ?: "?"} — ${sg.artist ?: "?"}", style = MaterialTheme.typography.bodyMedium)
            Text(MwFScreenLogic.memberName(state, sg.memberId), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (busy) {
            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
        } else {
            Button(onClick = { onAccept(sg) }, modifier = Modifier.testTag("mwf-approve-${sg.id}")) { Text("Accept") }
            OutlinedButton(onClick = { onReject(sg) }, modifier = Modifier.testTag("mwf-reject-${sg.id}")) { Text("Reject") }
        }
    }
}
