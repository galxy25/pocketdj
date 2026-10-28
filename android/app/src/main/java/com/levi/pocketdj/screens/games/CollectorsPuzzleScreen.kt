package com.levi.pocketdj.screens.games

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.puzzle.CollectorsPuzzleEngine
import com.levi.pocketdj.data.games.puzzle.PuzzleRoundState
import com.levi.pocketdj.data.games.puzzle.PuzzleSampler
import com.levi.pocketdj.data.games.puzzle.PuzzleSettings
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Gem Collector: one screen switching on the engine phase (setup -> sampling -> countdown ->
 * running -> summary). The engine is app-scoped so a round survives leaving this screen; [onClose]
 * pops back to the Games home.
 */
@Composable
fun CollectorsPuzzleScreen(graph: AppGraph, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val engine = graph.gamesGraph.puzzleEngine
    val state by engine.state.collectAsState()
    val scoreboard = graph.gamesGraph.scoreboard

    Box(modifier.fillMaxSize()) {
        when (state.phase) {
            PuzzleRoundState.Phase.IDLE -> SetupForm(graph, engine, state)
            PuzzleRoundState.Phase.SAMPLING -> Column(
                Modifier.fillMaxSize(), Arrangement.Center, Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator()
                Text("Sampling…", Modifier.padding(top = 12.dp))
            }
            PuzzleRoundState.Phase.COUNTDOWN -> Box(Modifier.fillMaxSize().testTag("puzzle-countdown"), Alignment.Center) {
                Text(state.countdown.toString(), fontSize = 120.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
            }
            PuzzleRoundState.Phase.RUNNING -> RunningView(engine, state) { _ -> engine.beginFiling() }
            PuzzleRoundState.Phase.FINISHED -> SummaryView(
                state = state,
                best = scoreboard.bestScore(GameKind.CollectorsPuzzle) ?: state.score,
                onAgain = { engine.reset() },
                onDone = { engine.reset(); onClose() },
            )
        }
    }

    // The app-wide Add-to sheet, multi-select: each add is noted and the sheet stays open;
    // dismissal is the one settle point (score once, advance, re-arm audio).
    // Driven from ENGINE state (app-scoped), not local state: a rotation / tab switch that tears
    // this composition down must not strand a filing hold (frozen timer, dead card tap).
    state.filingSongId?.let { songId ->
        AddToCollectionSheet(
            item = AddToItem.Song(songId),
            onDismiss = { engine.endFiling(null) },
            onAdded = { engine.noteFiled(it) },
            stayOpenAfterAdd = true,
        )
    }
}

// ---- setup -----------------------------------------------------------------------------------

@Composable
private fun SetupForm(graph: AppGraph, engine: CollectorsPuzzleEngine, state: PuzzleRoundState) {
    val s = state.settings
    val store by produceState<CollectionsStore?>(null) { value = withContext(Dispatchers.IO) { graph.collections } }
    val scoreboard = graph.gamesGraph.scoreboard
    var showGenres by rememberSaveable { mutableStateOf(false) }
    var showReplace by rememberSaveable { mutableStateOf(false) }
    var showNewPocket by rememberSaveable { mutableStateOf(false) }
    var newPocketName by rememberSaveable { mutableStateOf("") }
    var stats by remember { mutableStateOf<PuzzleSampler.PoolStats?>(null) }

    // Debounced, single-flight (LaunchedEffect restarts on every change): year keystrokes
    // must not pile samples up.
    // The pool is the catalog: a cold start straight onto Games has none loaded yet, so kick the
    // load and re-count when it lands (else "0 songs match" sticks until Browse is visited).
    LaunchedEffect(Unit) { graph.catalogRepository.loadIfNeeded() }
    val catalogLoaded = graph.catalogRepository.state.collectAsState().value.catalog != null
    LaunchedEffect(s, catalogLoaded) {
        delay(300)
        stats = withContext(Dispatchers.Default) { engine.poolStats() }
    }

    if (showGenres) {
        PuzzleGenreScreen(
            selected = s.genreCategories,
            onToggle = { engine.updateSettings(s.copy(genreCategories = PuzzleScreenLogic.toggleIn(s.genreCategories, it))) },
            onBack = { showGenres = false },
        )
        return
    }

    val colState = store?.state?.collectAsState()
    val all: List<Pair<String, String>> = colState?.value?.let { st ->
        st.pockets.sortedBy { it.name.lowercase() }.map { it.id to it.name } +
            st.playlists.sortedBy { it.name.lowercase() }.map { it.id to it.name }
    }.orEmpty()
    val bias = listOf(PuzzleSettings.Bias.OFF, PuzzleSettings.Bias.FAVOR, PuzzleSettings.Bias.AVOID)

    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
            item {
                Text(
                    "Best: ${scoreboard.bestScore(GameKind.CollectorsPuzzle) ?: 0}",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
                SectionTitle("Round")
                PuzzleSegmented(
                    PuzzleScreenLogic.ROUND_LENGTHS, s.roundSeconds,
                    { engine.updateSettings(s.copy(roundSeconds = it)) }, "puzzle-round-length",
                )
                SectionTitle("Weighting")
                PuzzlePickerRow(
                    "Play count", bias.zip(listOf("Off", "Most played", "Least played")), s.playCountBias,
                    { engine.updateSettings(s.copy(playCountBias = it)) }, "puzzle-playcount-bias",
                )
                PuzzlePickerRow(
                    "Last played", bias.zip(listOf("Off", "Recent", "Not lately")), s.recencyBias,
                    { engine.updateSettings(s.copy(recencyBias = it)) }, "puzzle-recency-bias",
                )
                PuzzlePickerRow(
                    "Favorites", bias.zip(listOf("Off", "Favorites", "Non-favs")), s.favoriteBias,
                    { engine.updateSettings(s.copy(favoriteBias = it)) }, "puzzle-favorite-bias",
                )
                SectionTitle("Filters")
                Row(
                    Modifier.fillMaxWidth().clickable { showGenres = true }.padding(vertical = 12.dp).testTag("puzzle-genres"),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("Genres")
                    Text(PuzzleScreenLogic.genresLabel(s.genreCategories), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                YearRow("Year from", s.yearMin, { engine.updateSettings(s.copy(yearMin = it)) }, "puzzle-year-min")
                YearRow("Year to", s.yearMax, { engine.updateSettings(s.copy(yearMax = it)) }, "puzzle-year-max")
                PuzzlePickerRow(
                    "Collection filter",
                    listOf(
                        PuzzleSettings.MembershipMode.OFF to "Off",
                        PuzzleSettings.MembershipMode.IN_ANY to "In",
                        PuzzleSettings.MembershipMode.NOT_IN_ANY to "Not in",
                    ),
                    s.membershipMode, { engine.updateSettings(s.copy(membershipMode = it)) }, "puzzle-membership-mode",
                )
            }
            if (s.membershipMode != PuzzleSettings.MembershipMode.OFF) {
                items(all, key = { "m_" + it.first }) { (id, name) ->
                    PuzzleCheckRow(
                        name, id in s.membershipCollectionIds,
                        { engine.updateSettings(s.copy(membershipCollectionIds = PuzzleScreenLogic.toggleIn(s.membershipCollectionIds, id))) },
                        "puzzle-membership-$id",
                    )
                }
            }
            item {
                SectionTitle("Targets (optional, up to 3)")
                if (s.targetCollectionIds.isNotEmpty()) {
                    PuzzlePickerRow(
                        "Draw",
                        listOf(
                            PuzzleSettings.Similarity.OFF to "Anything",
                            PuzzleSettings.Similarity.ON to "Similar",
                            PuzzleSettings.Similarity.STRICT to "Very similar",
                        ),
                        s.similarity, { engine.updateSettings(s.copy(similarity = it)) }, "puzzle-similarity",
                    )
                }
            }
            items(all, key = { "t_" + it.first }) { (id, name) ->
                val idx = s.targetCollectionIds.indexOf(id)
                PuzzleCheckRow(
                    if (idx >= 0) "${idx + 1}. $name" else name, idx >= 0,
                    { engine.updateSettings(s.copy(targetCollectionIds = PuzzleScreenLogic.toggleTarget(s.targetCollectionIds, id))) },
                    "puzzle-target-$id",
                )
            }
            item {
                TextButton(onClick = { showNewPocket = true }, modifier = Modifier.testTag("puzzle-new-pocket")) { Text("New Pocket…") }
                Text(
                    PuzzleScreenLogic.setupFooter(s.targetCollectionIds.isNotEmpty()),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
            }
        }
        // Pinned bottom bar: reachable at any list length.
        Surface(tonalElevation = 3.dp, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                state.lastError?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, modifier = Modifier.testTag("puzzle-error"))
                }
                Text(
                    PuzzleScreenLogic.poolCountText(stats),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp).testTag("puzzle-pool-count"),
                )
                Button(
                    onClick = {
                        if (graph.gamesGraph.gameRunPlayer.isRunning) showReplace = true else engine.startRoundDetached()
                    },
                    enabled = PuzzleScreenLogic.startEnabled(stats),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("puzzle-start"),
                ) { Text("Start Round") }
            }
        }
    }

    if (showReplace) {
        AlertDialog(
            onDismissRequest = { showReplace = false },
            title = { Text("Start round?") },
            text = { Text("This replaces your current queue.") },
            confirmButton = {
                TextButton(onClick = { showReplace = false; engine.startRoundDetached() }, modifier = Modifier.testTag("puzzle-confirm-replace")) {
                    Text("Start", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { showReplace = false }) { Text("Cancel") } },
        )
    }
    if (showNewPocket) {
        AlertDialog(
            onDismissRequest = { showNewPocket = false; newPocketName = "" },
            title = { Text("New Pocket") },
            text = { OutlinedTextField(newPocketName, { newPocketName = it }, label = { Text("Name") }, singleLine = true) },
            confirmButton = {
                TextButton(enabled = store != null, onClick = {
                    val name = newPocketName.trim()
                    if (name.isNotEmpty()) {
                        store?.let { st ->
                            val p = st.createPocket(name, emptyList(), null)
                            engine.updateSettings(s.copy(targetCollectionIds = PuzzleScreenLogic.appendTargetIfRoom(s.targetCollectionIds, p.id)))
                        }
                    }
                    showNewPocket = false; newPocketName = ""
                }) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { showNewPocket = false; newPocketName = "" }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun YearRow(label: String, value: Int?, onChange: (Int?) -> Unit, tag: String) {
    // Local text so partial typing ("19") is not rewritten; the model gets the parsed value.
    var text by remember(tag) { mutableStateOf(PuzzleScreenLogic.yearText(value)) }
    LaunchedEffect(value) { if (PuzzleScreenLogic.parseYear(text) != value) text = PuzzleScreenLogic.yearText(value) }
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        OutlinedTextField(
            value = text,
            onValueChange = { text = it; onChange(PuzzleScreenLogic.parseYear(it)) },
            placeholder = { Text("Any") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.width(110.dp).testTag(tag),
        )
        if (value != null || text.isNotEmpty()) {
            IconButton(onClick = { text = ""; onChange(null) }) { Icon(Icons.Filled.Clear, contentDescription = "Clear") }
        }
    }
}

// ---- running ---------------------------------------------------------------------------------

@Composable
private fun RunningView(engine: CollectorsPuzzleEngine, state: PuzzleRoundState, onFile: (IndexSong) -> Unit) {
    var remaining by remember { mutableIntStateOf(engine.remainingSeconds()) }
    LaunchedEffect(Unit) {
        while (true) {
            remaining = engine.remainingSeconds()
            delay(500)
        }
    }
    val song = state.current
    val targets = state.settings.targetCollectionIds
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            PuzzleScreenLogic.timerText(remaining),
            fontSize = 44.sp, fontWeight = FontWeight.SemiBold,
            color = if (PuzzleScreenLogic.timerUrgent(remaining)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.testTag("puzzle-timer"),
        )
        Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceVariant) {
            Text(
                "★ ${state.score}", style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp).testTag("puzzle-score"),
            )
        }
        if (song != null) {
            Card(Modifier.fillMaxWidth().clickable { onFile(song) }.testTag("puzzle-current")) {
                Column(Modifier.padding(16.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(song.name, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                    Text(song.artist, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    song.year?.let { Text(it.toString(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        } else if (state.poolExhausted) {
            Text("Catalog exhausted!", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.primary)
            Text("Every matching song has been shown.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            CircularProgressIndicator()
        }
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            targets.forEachIndexed { i, cid ->
                Button(
                    onClick = { engine.assign(i) }, enabled = song != null,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("puzzle-assign-$i"),
                ) { Text(engine.collectionName(cid), maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
            val fileModifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("puzzle-file")
            val fileLabel = PuzzleScreenLogic.fileButtonLabel(targets.isNotEmpty())
            if (targets.isEmpty()) {
                Button(onClick = { song?.let(onFile) }, enabled = song != null, modifier = fileModifier) { Text(fileLabel) }
            } else {
                OutlinedButton(onClick = { song?.let(onFile) }, enabled = song != null, modifier = fileModifier) { Text(fileLabel) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { engine.skip() }, enabled = song != null, modifier = Modifier.testTag("puzzle-skip")) { Text("Skip") }
            TextButton(onClick = { engine.endRound() }, modifier = Modifier.testTag("puzzle-end")) {
                Text("End Round", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

// ---- summary ---------------------------------------------------------------------------------

@Composable
private fun SummaryView(state: PuzzleRoundState, best: Int, onAgain: () -> Unit, onDone: () -> Unit) {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        item {
            Column(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("★ ${state.score}", fontSize = 56.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("puzzle-summary-score"))
                if (state.isNewHighScore) Text(PuzzleScreenLogic.NEW_HIGH_SCORE, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                Text("Best: $best", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (state.assigned.isNotEmpty()) {
            item { SectionTitle("Filed this round") }
            items(state.assigned.size) { i ->
                val row = state.assigned[i]
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(Modifier.weight(1f)) {
                        Text(row.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(row.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Text(PuzzleScreenLogic.filedRowLabel(row.collectionName), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 8.dp))
                }
                HorizontalDivider()
            }
        }
        item {
            Column(Modifier.padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onAgain, modifier = Modifier.fillMaxWidth().testTag("puzzle-again")) { Text("Play Again") }
                OutlinedButton(onClick = onDone, modifier = Modifier.fillMaxWidth().testTag("puzzle-done")) { Text("Done") }
            }
        }
    }
}
