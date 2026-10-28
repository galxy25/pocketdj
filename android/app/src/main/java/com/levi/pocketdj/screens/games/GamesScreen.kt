package com.levi.pocketdj.screens.games

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Diamond
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import kotlinx.coroutines.CoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.data.games.RunRecord
import com.levi.pocketdj.data.games.friends.MusicWithFriendsStore
import com.levi.pocketdj.data.games.friends.MwFSessionEntry
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material.icons.filled.WorkspacePremium
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.withContext

/** What a scoreboard delete is about to wipe; the copy mirrors iOS. */
sealed class ScoreboardDeletion(val key: String) {
    data class Game(val game: GameKind) : ScoreboardDeletion("game-${game.token}")
    data object All : ScoreboardDeletion("all")

    val title: String
        get() = when (this) {
            is Game -> "Delete ${game.label} scores?"
            All -> "Delete every scoreboard?"
        }
    val message: String
        get() = when (this) {
            is Game -> "Removes every recorded ${game.label} run — best score and history — on this device and every device you sync with. This can't be undone."
            All -> "Removes every recorded run of every game on this device and every device you sync with. This can't be undone."
        }
    val confirmLabel: String
        get() = when (this) {
            is Game -> "Delete ${game.label} Scores"
            All -> "Delete All"
        }

    companion object {
        fun fromKey(key: String): ScoreboardDeletion? = when {
            key == "all" -> All
            key.startsWith("game-") -> GameKind.fromToken(key.removePrefix("game-"))?.let(::Game)
            else -> null
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GamesScreen(
    store: GameScoreboardStore,
    modifier: Modifier = Modifier,
    onOpenPuzzle: (() -> Unit)? = null,
    onOpenInThePocket: (() -> Unit)? = null,
    deleteScope: CoroutineScope? = null,
    friends: MusicWithFriendsStore? = null,
    onNewSession: (() -> Unit)? = null,
    onJoinSession: (() -> Unit)? = null,
    onOpenSession: ((String) -> Unit)? = null,
) {
    val state by store.state.collectAsState()
    val scope = rememberCoroutineScope()
    // The pending key survives rotation / tab switches; the dialog re-derives from it.
    var pendingKey by rememberSaveable { mutableStateOf<String?>(null) }
    val pending = pendingKey?.let(ScoreboardDeletion::fromKey)

    val runs = state.runs
    fun best(game: GameKind) = runs.filter { it.game == game.token }.maxOfOrNull { it.score }
    val stats = remember(state.revision) { store.inThePocketStats() }

    LazyColumn(
        modifier = modifier.fillMaxWidth().testTag("games-list"),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            GameCard(
                icon = Icons.Filled.Diamond,
                title = GameKind.CollectorsPuzzle.label,
                blurb = "Timed rush — file songs into any collection. One point per song.",
                line = "Best: ${best(GameKind.CollectorsPuzzle) ?: 0}",
                tag = "games-card-puzzle",
                lineTag = "games-best-collectorsPuzzle",
                onClick = onOpenPuzzle,
            )
        }
        item {
            GameCard(
                icon = Icons.Filled.GraphicEq,
                title = GameKind.InThePocket.label,
                blurb = "3–4 songs picked for right now. Play them all without skipping.",
                line = stats.summary(),
                tag = "games-card-inthepocket",
                lineTag = "games-stats-inThePocket",
                onClick = onOpenInThePocket,
            )
        }
        item {
            GameCard(
                icon = Icons.Filled.Groups,
                title = GameKind.MusicWithFriends.label,
                blurb = "Turn-based suggestions with friends. Points for accepted songs.",
                line = "Best: ${best(GameKind.MusicWithFriends) ?: 0}",
                tag = "games-card-friends",
                lineTag = "games-best-musicWithFriends",
                onClick = null,
            )
        }
        if (friends != null) {
            item {
                MwFSessionRows(
                    friends = friends,
                    onNew = { onNewSession?.invoke() },
                    onJoin = { onJoinSession?.invoke() },
                    onOpen = { onOpenSession?.invoke(it) },
                )
            }
        }
        item {
            ScoreboardTitleRow(
                hasRuns = runs.isNotEmpty(),
                onDeleteAll = { pendingKey = ScoreboardDeletion.All.key },
            )
        }
        if (runs.isEmpty()) {
            item {
                Text(
                    "No runs yet — play a game!",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("games-scoreboard-empty"),
                )
            }
        } else {
            for (game in GameKind.entries) {
                val bestRun = store.bestRun(game) ?: continue
                item(key = "board-${game.token}") {
                    GameBlock(
                        game = game,
                        best = bestRun,
                        recent = store.recentRuns(game, 5),
                        onDeleteGame = { pendingKey = ScoreboardDeletion.Game(game).key },
                        onDeleteAll = { pendingKey = ScoreboardDeletion.All.key },
                    )
                }
            }
        }
    }

    pending?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingKey = null },
            title = { Text(target.title) },
            text = { Text(target.message) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingKey = null
                        // App-scoped when provided so a confirmed delete survives UI teardown.
                        (deleteScope ?: scope).launch {
                            withContext(Dispatchers.IO) {
                                when (target) {
                                    is ScoreboardDeletion.Game -> store.delete(target.game)
                                    ScoreboardDeletion.All -> store.deleteAll()
                                }
                            }
                        }
                    },
                    modifier = Modifier.testTag("games-scoreboard-delete-confirm"),
                ) { Text(target.confirmLabel, color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { pendingKey = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun GameCard(
    icon: ImageVector,
    title: String,
    blurb: String,
    line: String,
    tag: String,
    lineTag: String,
    onClick: (() -> Unit)?,
) {
    Card(
        modifier = Modifier.fillMaxWidth().testTag(tag)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it },
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(blurb, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    line,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.testTag(lineTag),
                )
            }
        }
    }
}

/** The title is an ordinary row (like iOS): long-press AND the ⋯ both open the same menu; empty board = neither. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ScoreboardTitleRow(hasRuns: Boolean, onDeleteAll: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth()
                .let { if (hasRuns) it.combinedClickable(onClick = {}, onLongClick = { menu = true }) else it },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Scoreboard",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).testTag("games-scoreboard-header"),
            )
            if (hasRuns) {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("games-scoreboard-menu")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "Scoreboard options")
                }
            }
        }
        DropdownMenu(expanded = menu && hasRuns, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Delete All Scoreboards") },
                leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                onClick = { menu = false; onDeleteAll() },
                modifier = Modifier.testTag("games-scoreboard-delete-all"),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GameBlock(
    game: GameKind,
    best: RunRecord,
    recent: List<RunRecord>,
    onDeleteGame: () -> Unit,
    onDeleteAll: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        // The whole block (best row + every run row) is the long-press target.
        Column(
            Modifier.fillMaxWidth()
                .combinedClickable(onClick = {}, onLongClick = { menu = true })
                .testTag("games-scoreboard-game-${game.token}")
                .semantics { contentDescription = "${game.label}, best ${best.score}" },
        ) {
            Text(game.label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Best ${best.score}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.tertiary)
                Text(dateLabel(best.at), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                best.settingsSummary?.let {
                    Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            recent.forEachIndexed { i, run ->
                Row(
                    Modifier.fillMaxWidth().padding(top = 4.dp).testTag("games-run-${game.token}-$i"),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("★ ${run.score}", style = MaterialTheme.typography.labelMedium)
                    Text(dateLabel(run.at), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f))
                    run.settingsSummary?.let {
                        Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            HorizontalDivider(Modifier.padding(top = 8.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Delete ${game.label} Scores") },
                leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                onClick = { menu = false; onDeleteGame() },
                modifier = Modifier.testTag("games-scoreboard-delete-${game.token}"),
            )
            DropdownMenuItem(
                text = { Text("Delete All Scoreboards") },
                onClick = { menu = false; onDeleteAll() },
                modifier = Modifier.testTag("games-scoreboard-delete-all-from-${game.token}"),
            )
        }
    }
}

private fun dateLabel(atMs: Double): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(atMs.toLong()))

/** Session rows + New / Join buttons under the Music with Friends card (iOS `GamesView` friends section). */
@Composable
private fun MwFSessionRows(
    friends: MusicWithFriendsStore,
    onNew: () -> Unit,
    onJoin: () -> Unit,
    onOpen: (String) -> Unit,
) {
    val sessions by friends.sessions.collectAsState()
    val states by friends.lastState.collectAsState()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (entry in sessions) {
            MwFSessionRow(entry, states[entry.id]?.let { friends.myScore(it) }, onClick = { onOpen(entry.id) })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = onNew, modifier = Modifier.testTag("mwf-new")) { Text("New Session") }
            OutlinedButton(onClick = onJoin, modifier = Modifier.testTag("mwf-join")) { Text("Join Session") }
        }
    }
}

@Composable
private fun MwFSessionRow(entry: MwFSessionEntry, score: Int?, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().clickable(onClick = onClick).testTag("mwf-session-${entry.id}")) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (entry.isLeader) Icon(Icons.Filled.WorkspacePremium, "Leader", tint = MaterialTheme.colorScheme.tertiary)
                Text(entry.name ?: "Music with Friends", style = MaterialTheme.typography.bodyLarge)
            }
            entry.theme?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                entry.expiresAt?.let {
                    Text(MwFScreenLogic.expiresLabel(it, System.currentTimeMillis().toDouble()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (score != null) Text("your score: $score", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}
