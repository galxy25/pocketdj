package com.levi.pocketdj.screens.games

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicNone
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.levi.pocketdj.data.games.inthepocket.FeedbackDictationController
import com.levi.pocketdj.data.games.inthepocket.InThePocketRound
import com.levi.pocketdj.data.games.inthepocket.InThePocketStore
import com.levi.pocketdj.data.games.inthepocket.SystemFeedbackSpeechEngine
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * "In the Pocket": PocketDJ bets on 3-4 songs you'll play straight through - right now - using what
 * your listening pockets found. Every round is training data for them, and the feedback field (type,
 * or tap the mic and talk) says how the pocket felt. Port of InThePocketView.
 */
@Composable
fun InThePocketScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val games = graph.gamesGraph
    // The real bridge is assigned asynchronously after launch: observe it so an early open recomposes onto it.
    val servicesBridge by games.servicesBridgeFlow.collectAsState()
    val bridge = servicesBridge ?: games.pocketsBridge
    val enabled by bridge.isEnabled.collectAsState()
    if (!enabled && bridge === com.levi.pocketdj.data.pockets.NoPocketsBridge) {
        // No pockets service in this build (iOS third branch).
        Box(modifier.fillMaxSize().testTag("itp-unavailable"), contentAlignment = Alignment.Center) {
            Text(InThePocketScreenLogic.UNAVAILABLE_TEXT, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    if (!enabled) {
        PocketsOptInView(games.pocketsOptIn, modifier)
        return
    }
    InThePocketContent(games.inThePocket, games.scoreboard, bridge, modifier)
}

@Composable
private fun InThePocketContent(
    game: InThePocketStore,
    scoreboard: com.levi.pocketdj.data.games.GameScoreboardStore,
    bridge: com.levi.pocketdj.data.pockets.PocketsBridge,
    modifier: Modifier,
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by game.state.collectAsState()
    val scoreState by scoreboard.state.collectAsState()
    val stats = remember(scoreState.revision) { scoreboard.inThePocketStats() }

    // ---- dictation (on-device only) ----
    var pending by remember { mutableStateOf<CompletableDeferred<Boolean>?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        pending?.complete(ok); pending = null
    }
    val dictation = remember {
        FeedbackDictationController(SystemFeedbackSpeechEngine(ctx.applicationContext) {
            if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED) true
            else {
                pending?.complete(false)
                val d = CompletableDeferred<Boolean>()
                pending = d
                launcher.launch(Manifest.permission.RECORD_AUDIO)
                d.await()
            }
        })
    }
    val dictState by dictation.state.collectAsState()

    // ---- feedback draft ----
    var draft by remember { mutableStateOf("") }
    var rating by remember { mutableStateOf<Int?>(null) }
    var draftRoundId by remember { mutableStateOf<UUID?>(null) }

    fun saveFeedback() {
        val id = draftRoundId ?: return
        if (game.rounds.none { it.id == id }) return
        game.saveFeedback(id, draft, rating)
    }
    val saveNow by rememberUpdatedState(::saveFeedback)

    LaunchedEffect(state.currentRoundId) {
        if (draftRoundId != state.currentRoundId) {
            dictation.stop()
            draftRoundId = state.currentRoundId
            draft = state.current?.feedback ?: ""
            rating = state.current?.rating
        }
    }
    LaunchedEffect(Unit) {
        game.resumeTrackingIfNeeded()
        bridge.refreshIfStale()
    }
    // Leaving the screen stops dictation and saves.
    DisposableEffect(Unit) {
        onDispose { dictation.stop(); saveNow() }
    }

    val round = state.current
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).testTag("itp-screen"),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Card { Column(Modifier.padding(12.dp)) { StatsRow(stats) } }
        if (round != null) {
            Card {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    RoundCard(game, round, state.currentSongIndex, state.buildState,
                        onBuild = { scope.launch { game.buildRound() } },
                        onNewRound = { saveFeedback(); game.dismissCurrent() })
                }
            }
            if (round.startedAtMs != null) {
                Card {
                    Column(Modifier.padding(12.dp)) {
                        Text("How does it feel?", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                        FeedbackEditor(
                            round = round, draft = draft, rating = rating, dictation = dictation, dictState = dictState,
                            onDraft = { draft = InThePocketScreenLogic.clampDraft(it) },
                            onRating = { rating = InThePocketScreenLogic.toggledRating(rating, it); saveFeedback() },
                            onMic = { scope.launch { dictation.toggle(draft) { draft = InThePocketScreenLogic.clampDraft(it) } } },
                            onSave = { dictation.stop(); saveFeedback() },
                        )
                    }
                }
            }
        } else {
            Card {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(InThePocketScreenLogic.BUILD_BLURB, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    (state.buildState as? InThePocketStore.BuildState.Failed)?.let {
                        Text(it.message, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("itp-build-error"))
                    }
                    val building = state.buildState is InThePocketStore.BuildState.Building
                    Button(
                        onClick = { scope.launch { game.buildRound() } },
                        enabled = !building,
                        modifier = Modifier.fillMaxWidth().testTag("itp-build"),
                    ) {
                        if (building) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 8.dp), strokeWidth = 2.dp)
                        Text(InThePocketScreenLogic.buildButtonLabel(building))
                    }
                }
            }
        }
        Text(InThePocketScreenLogic.PRIVACY_NOTE, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("itp-privacy-note"))
    }
}

@Composable
private fun RoundCard(
    game: InThePocketStore,
    round: InThePocketRound,
    currentSongIndex: Int?,
    buildState: InThePocketStore.BuildState,
    onBuild: () -> Unit,
    onNewRound: () -> Unit,
) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Text(InThePocketScreenLogic.chipsLine(game.chips(round)), style = MaterialTheme.typography.labelLarge,
        fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("itp-chips"))
    Text(InThePocketScreenLogic.modeNote(round.mode), style = MaterialTheme.typography.bodySmall, color = dim,
        modifier = Modifier.testTag("itp-mode-${round.mode.name.lowercase()}"))
    ProgressDots(round)
    round.songs.forEachIndexed { i, s -> SongRow(s, i, isCurrent = currentSongIndex == i && round.isActive) }
    val outcome = round.outcome
    if (outcome != null) {
        Text(InThePocketScreenLogic.outcomeText(outcome), style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("itp-outcome"))
    } else if (round.isActive) {
        Text(InThePocketScreenLogic.PLAYING_NOTE, style = MaterialTheme.typography.bodySmall, color = dim)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        when {
            round.startedAtMs == null -> {
                Button(onClick = { game.start() }, modifier = Modifier.testTag("itp-start")) { Text("Start") }
                OutlinedButton(
                    onClick = onBuild,
                    enabled = buildState !is InThePocketStore.BuildState.Building,
                    modifier = Modifier.testTag("itp-reroll"),
                ) { Text("Different songs") }
            }
            round.isActive ->
                OutlinedButton(onClick = { game.endActiveRound() }, modifier = Modifier.testTag("itp-end")) {
                    Text("End round", color = MaterialTheme.colorScheme.error)
                }
            else -> Button(onClick = onNewRound, modifier = Modifier.testTag("itp-new")) { Text("New round") }
        }
    }
}

@Composable
private fun FeedbackEditor(
    round: InThePocketRound,
    draft: String,
    rating: Int?,
    dictation: FeedbackDictationController,
    dictState: FeedbackDictationController.State,
    onDraft: (String) -> Unit,
    onRating: (Int) -> Unit,
    onMic: () -> Unit,
    onSave: () -> Unit,
) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val saved = InThePocketScreenLogic.feedbackSaved(round, draft, rating)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            for (n in 1..5) {
                val on = (rating ?: 0) >= n
                IconButton(onClick = { onRating(n) }, modifier = Modifier.size(40.dp).testTag("itp-rating-$n")) {
                    Icon(
                        if (on) Icons.Filled.Star else Icons.Filled.StarBorder,
                        contentDescription = "$n star${if (n == 1) "" else "s"}",
                        tint = if (on) MaterialTheme.colorScheme.primary else dim,
                    )
                }
            }
            Text("optional", style = MaterialTheme.typography.labelSmall, color = dim, modifier = Modifier.padding(start = 6.dp))
        }
        Row(verticalAlignment = Alignment.Top) {
            OutlinedTextField(
                value = draft, onValueChange = onDraft,
                placeholder = { Text(InThePocketScreenLogic.FEEDBACK_HINT) },
                minLines = 3, maxLines = 8,
                modifier = Modifier.weight(1f).testTag("itp-feedback"),
            )
            // Hidden entirely when the engine can't dictate on-device (no cloud fallback).
            if (InThePocketScreenLogic.micVisible(dictation.isAvailable)) {
                val listening = dictState == FeedbackDictationController.State.Listening
                IconButton(
                    onClick = onMic,
                    enabled = InThePocketScreenLogic.micEnabled(
                        denied = dictState == FeedbackDictationController.State.Denied,
                        unavailable = dictState == FeedbackDictationController.State.Unavailable,
                        requesting = dictState == FeedbackDictationController.State.Requesting),
                    modifier = Modifier.size(48.dp).testTag("itp-mic"),
                ) {
                    Icon(
                        if (listening) Icons.Filled.Mic else Icons.Filled.MicNone,
                        contentDescription = if (listening) "Stop dictation" else "Dictate feedback",
                        tint = if (listening) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
        FeedbackDictationController.explanationFor(dictState)?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = dim, modifier = Modifier.testTag("itp-mic-explanation"))
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(InThePocketScreenLogic.counterText(draft), style = MaterialTheme.typography.labelSmall,
                color = dim, modifier = Modifier.weight(1f).testTag("itp-feedback-counter"))
            TextButton(onClick = onSave, enabled = !saved, modifier = Modifier.testTag("itp-feedback-save")) {
                Text(if (saved) "Saved" else "Save")
            }
        }
    }
}
