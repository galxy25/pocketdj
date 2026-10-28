package com.levi.pocketdj.screens.history

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocket
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketHarmonic
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
import com.levi.pocketdj.data.pockets.ListeningPocketPattern
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Pure text for the detail (iOS `ListeningPocketDetailView` computed properties). */
internal object PocketDetailText {
    fun featureLine(f: ListeningPocketFeature, labeler: ListeningPocketLabeler): String {
        val share = ListeningPocketLabeler.pct(f.share)
        val base = f.baselineShare
        return if (base != null) "${labeler.label(f)}: $share of this pocket vs ${ListeningPocketLabeler.pct(base)} of your listening"
        else "${labeler.label(f)}: $share of this pocket"
    }

    fun numericLines(numeric: Map<String, ListeningPocketNumeric>): List<String> {
        val out = ArrayList<String>()
        numeric["bpm"]?.takeIf { it.defining }?.let {
            out += "${ListeningPocketLabeler.bpmText(it)}, ${ListeningPocketLabeler.tightness(it)}"
        }
        numeric["energy"]?.takeIf { it.defining }?.let {
            val lvl = if (it.center >= 0.6) "High energy" else if (it.center <= 0.4) "Low energy" else "Mid energy"
            out += "$lvl, ${ListeningPocketLabeler.tightness(it)}"
        }
        numeric["year"]?.takeIf { it.defining }?.let {
            val lo = it.lo.roundToInt(); val hi = it.hi.roundToInt()
            out += "${if (lo == hi) "$lo" else "$lo–$hi"} releases, ${ListeningPocketLabeler.tightness(it)}"
        }
        return out
    }

    fun harmonicLine(h: ListeningPocketHarmonic): String {
        var s = "Keys flow: ${ListeningPocketLabeler.pct(h.rate)} of changes go to a neighbouring key"
        h.baselineRate?.let { s += " vs ${ListeningPocketLabeler.pct(it)} usually" }
        return s
    }

    private fun cap(s: String) = s.replaceFirstChar { it.uppercase() }

    fun whenLines(p: ListeningPocket, labeler: ListeningPocketLabeler): List<String> {
        val out = ArrayList<String>()
        out += ListeningPocketLabeler.whenText(p.startMs, p.tzOffsetMin)
        val parts = listOfNotNull(p.dayType?.let(::cap), p.timeBucket?.let(::cap))
        if (parts.isNotEmpty()) out += parts.joinToString(" · ")
        var counts = "${p.memberCount} songs"
        if (p.skippedCount > 0) counts += " · ${p.skippedCount} skipped along the way"
        out += counts
        ctxLine(p.ctx, labeler)?.let { out += it }
        return out
    }

    fun whenLines(p: ListeningPocketPattern, labeler: ListeningPocketLabeler, nowMs: Double = System.currentTimeMillis().toDouble()): List<String> {
        val out = ArrayList<String>()
        val parts = listOfNotNull(p.dayType?.let { cap(it) + "s" }, p.timeBucket?.let(::cap))
        if (parts.isNotEmpty()) out += parts.joinToString(" · ")
        var times = "${p.occurrences} times on ${p.distinctDays} days"
        ListeningPocketLabeler.lastText(p.lastMs, nowMs)?.let { times += " · $it" }
        out += times
        ctxLine(p.ctx, labeler)?.let { out += it }
        return out
    }

    private fun ctxLine(ctx: ListeningContextTag?, labeler: ListeningPocketLabeler): String? =
        ctx?.let { if (it.isTrip) "On the trip ${labeler.contextLabel(it)}" else "At ${labeler.contextLabel(it)}" }
}

/** One pocket or one recurring pattern: what defines it, when/where, songs, Play, Save as playlist. */
@Composable
internal fun ListeningPocketDetailScreen(
    pocket: ListeningPocket?,
    pattern: ListeningPocketPattern?,
    labeler: ListeningPocketLabeler,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    BackHandler(onBack = onBack)
    val title = pocket?.title ?: pattern?.title ?: ""
    val features = pocket?.features ?: pattern?.features ?: emptyList()
    val numeric = pocket?.numeric ?: pattern?.numeric ?: emptyMap()
    val harmonic = pocket?.harmonic ?: pattern?.harmonic
    val songIds = pocket?.songIds ?: pattern?.songIds ?: emptyList()
    val whenLines = if (pocket != null) PocketDetailText.whenLines(pocket, labeler)
    else pattern?.let { PocketDetailText.whenLines(it, labeler) } ?: emptyList()
    val numericLines = PocketDetailText.numericLines(numeric)
    val catalog = graph.catalogRepository.state.value.catalog
    val history = remember { PlayHistoryStore.get(context) }
    var savedName by remember { mutableStateOf<String?>(null) }
    var playError by remember { mutableStateOf<String?>(null) }

    LazyColumn(modifier.fillMaxSize().testTag("pocket-detail")) {
        item(key = "top") {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onBack, modifier = Modifier.testTag("pocket-back")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                    Text(if (pattern != null) "Recurring pocket" else "Pocket", style = MaterialTheme.typography.titleSmall)
                }
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        enabled = songIds.isNotEmpty(),
                        onClick = {
                            scope.launch {
                                // iOS playNow(songIds:name:) passes no source, which historyContext resolves to .setlist; 'pocket' is for collection Pockets.
                                runCatching {
                                    graph.shellGraph.shellActions.playSongIds(songIds, title, source = PlayContext.SOURCE_SETLIST)
                                }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it else playError = it.message ?: "Couldn't play" }
                            }
                        },
                        modifier = Modifier.testTag("pocket-play"),
                    ) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Text("Play")
                    }
                    OutlinedButton(
                        enabled = songIds.isNotEmpty(),
                        onClick = { savedName = graph.collections.createPlaylist(title, songIds).name },
                        modifier = Modifier.testTag("pocket-save-playlist"),
                    ) { Text("Save as playlist") }
                }
                savedName?.let {
                    Text("Saved \"$it\" to your playlists.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("pocket-saved"))
                }
                playError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            }
        }
        item(key = "h-defines") { SectionHeader("What defines it") }
        val hLine = harmonic?.takeIf { it.defining }?.let { PocketDetailText.harmonicLine(it) }
        val defines = numericLines + listOfNotNull(hLine) + features.map { PocketDetailText.featureLine(it, labeler) }
        if (defines.isEmpty()) {
            item(key = "defines-none") {
                Line("Nothing stands out yet — it gets sharper as you listen more.", dim = true)
            }
        } else {
            itemsIndexed(defines, key = { i, _ -> "d$i" }) { _, t -> Line(t) }
        }
        item(key = "h-when") { SectionHeader("When & where") }
        itemsIndexed(whenLines, key = { i, _ -> "w$i" }) { _, t -> Line(t) }
        item(key = "h-songs") { SectionHeader(if (pattern != null) "Most played" else "Songs") }
        itemsIndexed(songIds, key = { i, _ -> "s$i" }) { _, id ->
            val song = catalog?.songsById?.get(id)
            // Unresolved (left the catalog / another device's library): the play's own snapshot.
            val snap = if (song == null) history.events.lastOrNull { it.songId == id } else null
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                Text(song?.name ?: snap?.title ?: "Unknown song", maxLines = 1, overflow = TextOverflow.Ellipsis)
                (song?.artist ?: snap?.artist)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun Line(text: String, dim: Boolean = false) {
    Text(text, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        color = if (dim) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
}
