package com.levi.pocketdj.screens.history.wheel

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.wheel.PocketMoment
import com.levi.pocketdj.data.pockets.wheel.PocketPaletteStore
import com.levi.pocketdj.data.pockets.wheel.PocketSwatch
import com.levi.pocketdj.data.pockets.wheel.PocketWheelSnapshot
import com.levi.pocketdj.ui.theme.PdjOnBackground
import com.levi.pocketdj.ui.theme.PdjOnSurfaceVariant
import com.levi.pocketdj.ui.theme.PdjOutline
import com.levi.pocketdj.ui.theme.PdjSurfaceContainerHigh
import com.levi.pocketdj.ui.theme.PdjSurfaceVariant
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/** Pure text + ordering for the moment card (iOS `PocketMomentCard` computed properties). Tested on the JVM. */
internal object PocketCardText {
    /** Collections by share, descending; ties by id ascending (iOS `sortedCollections`). The card shows the top 4. */
    fun sortedCollections(m: PocketMoment): List<Pair<String, Double>> =
        m.collections.entries.sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            .map { it.key to it.value }

    /** "NN %" with the same rounding as iOS `Int((share * 100).rounded())`. */
    fun percent(share: Double): String = "${(share * 100).roundToInt()} %"

    fun topArtists(m: PocketMoment): List<String> =
        m.artists.entries.sortedByDescending { it.value }.take(3).map { e -> e.key.replaceFirstChar { it.uppercase() } }

    fun topGenres(m: PocketMoment): List<String> =
        m.genres.entries.sortedByDescending { it.value }.take(3).map { InThePocketScorer.genreLabel(it.key) }

    fun tempo(m: PocketMoment): String? = m.bpmBand?.let { "${it.start.toInt()}–${it.endInclusive.toInt()} BPM" }

    fun eraText(m: PocketMoment): String? = m.era?.let { "${it.lo.roundToInt()}–${it.hi.roundToInt()}" }

    /**
     * The place/trip tag for one `ctx` key ("place:<id>", "trip:<id>"); null for "none" and malformed keys.
     */
    fun tagOf(key: String): ListeningContextTag? {
        if (key == "none") return null
        val i = key.indexOf(':')
        if (i < 0) return null
        val kind = key.substring(0, i)
        val id = key.substring(i + 1)
        return when (kind) {
            "trip" -> ListeningContextTag(kind = ListeningContextTag.KIND_TRIP, tripId = id, origin = "?")
            "place" -> ListeningContextTag.place(id)
            else -> ListeningContextTag.place(id)
        }
    }

    /** Up to 3 chips by weight; unknown places read "Earlier place" (a trip: "A trip"). */
    fun placeChips(m: PocketMoment, labelOf: (ListeningContextTag) -> String?): List<String> =
        m.ctx.entries.sortedByDescending { it.value }.mapNotNull { (key, _) ->
            val tag = tagOf(key) ?: return@mapNotNull null
            labelOf(tag) ?: if (tag.kind == ListeningContextTag.KIND_TRIP) "A trip" else "Earlier place"
        }.take(3)

    fun plays(m: PocketMoment) = "${m.directPlays}" to "plays"
    fun skips(m: PocketMoment) = percent(m.skipRate) to "skips"
    fun recurrence(m: PocketMoment) =
        if (m.isRecurring) "${m.distinctDays} days" to "recurring" else "once" to "one-off"

    /** The "Why this colour" body. */
    fun whyText(m: PocketMoment, names: Map<String, String>): String {
        val d = m.dominantCollectionId
            ?: return "No single playlist or pocket made up a quarter of what you played here, so this cell is drawn as mixed."
        val name = names[d] ?: "This collection"
        val pct = ((m.collections[d] ?: 0.0) * 100).roundToInt()
        var s = "$name is where $pct % of the music you played here came from"
        s += if (m.isRecurring) ", across ${m.distinctDays} different days." else ". It happened once, so it's drawn paler."
        s += " Colours are assigned automatically and stay the same on all your devices."
        return s
    }

    /** "N played · X % skipped" (a past run's strip). */
    fun runSummary(playedThrough: Int, skipRate: Double) = "$playedThrough played · ${percent(skipRate)} skipped"

    /** A run row's date label: Today / Yesterday / "Mon, Nov 3". */
    fun runLabel(startedAtMs: Double, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val day = Instant.ofEpochMilli(startedAtMs.toLong()).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        return when (day) {
            today -> "Today"
            today.minusDays(1) -> "Yesterday"
            else -> day.format(DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US))
        }
    }

    /** This cell's pocket is the one playing now. */
    fun isPlaying(actions: PocketWheelActions, m: PocketMoment): Boolean =
        actions.runProgress != null && actions.runProgress.key == m.key

    /** The Clear control exists whenever a run is live and the host supplied a clear action. */
    fun canClear(actions: PocketWheelActions): Boolean = actions.runProgress != null && actions.clearRun != null
}

private fun swatchColor(s: PocketSwatch): Color {
    val (r, g, b) = s.rgb(dark = true)
    return Color(r.toFloat(), g.toFloat(), b.toFloat())
}

/**
 * The detail card for one wheel cell: its moment, collections as coloured bars, top artists/genres, tempo, place chips,
 * plays + skip rate, play button (long-press: Clear), "Why this colour", and the past-runs strip.
 */
@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
fun PocketMomentCard(
    moment: PocketMoment,
    snapshot: PocketWheelSnapshot,
    palette: PocketPaletteStore,
    actions: PocketWheelActions,
    labelOf: (ListeningContextTag) -> String?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    nowMs: () -> Long = { System.currentTimeMillis() },
) {
    var showWhy by remember { mutableStateOf(false) }
    var clearMenu by remember { mutableStateOf(false) }
    val names = snapshot.collectionNames
    Column(
        modifier.fillMaxWidth()
            .background(PdjSurfaceVariant, RoundedCornerShape(14.dp))
            .border(1.dp, PdjOutline, RoundedCornerShape(14.dp))
            .padding(14.dp).testTag("pocket-card"),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(modeIcon(moment.key.mode), contentDescription = null, tint = PdjOnSurfaceVariant)
            Text(moment.key.longLabel, color = PdjOnBackground, style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).padding(start = 8.dp).testTag("pocket-card-title"))
            IconButton(onClick = onClose, modifier = Modifier.testTag("pocket-card-close")) {
                Icon(Icons.Filled.Close, contentDescription = "Close", tint = PdjOnSurfaceVariant)
            }
        }
        val colls = PocketCardText.sortedCollections(moment)
        if (colls.isEmpty()) {
            Text("No collection yet — these were singles.", color = PdjOnSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for ((id, share) in colls.take(4)) {
                    val name = names[id] ?: "Collection"
                    Row(
                        Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = "$name ${PocketCardText.percent(share)}" },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(name, color = PdjOnBackground, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.width(110.dp))
                        Box(Modifier.weight(1f).height(8.dp).clip(CircleShape).background(PdjSurfaceContainerHigh).testTag("pocket-card-bar-$id")) {
                            Box(Modifier.fillMaxWidth(share.toFloat().coerceIn(0.04f, 1f)).height(8.dp)
                                .background(swatchColor(palette.swatch(id)), CircleShape))
                        }
                        Text(PocketCardText.percent(share), color = PdjOnSurfaceVariant, fontSize = 11.sp,
                            modifier = Modifier.width(44.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val artists = PocketCardText.topArtists(moment)
            val genres = PocketCardText.topGenres(moment)
            if (artists.isNotEmpty()) FeatureRow("Artists", artists.joinToString(", "))
            if (genres.isNotEmpty()) FeatureRow("Genres", genres.joinToString(", "))
            PocketCardText.tempo(moment)?.let { FeatureRow("Tempo", it) }
            PocketCardText.eraText(moment)?.let { FeatureRow("Era", it) }
        }
        val chips = PocketCardText.placeChips(moment, labelOf)
        if (chips.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                chips.forEach { t ->
                    Text(t, color = PdjOnBackground, fontSize = 11.sp,
                        modifier = Modifier.background(PdjSurfaceContainerHigh, CircleShape).padding(horizontal = 8.dp, vertical = 4.dp))
                }
            }
        }
        Row(Modifier.testTag("pocket-card-stats"), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Stat(PocketCardText.plays(moment))
            Stat(PocketCardText.skips(moment))
            Stat(PocketCardText.recurrence(moment))
        }
        actions.playMoment?.let { play ->
            Box {
                androidx.compose.material3.Surface(
                    color = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    shape = RoundedCornerShape(50),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                        .combinedClickable(
                            role = Role.Button,
                            onClick = { play(moment.key) },
                            onLongClick = { if (PocketCardText.canClear(actions)) clearMenu = true },
                            onLongClickLabel = if (PocketCardText.canClear(actions)) "Clear this pocket" else null,
                        )
                        .testTag("pocket-card-play"),
                ) {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Text("Play this pocket", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 6.dp))
                    }
                }
                DropdownMenu(expanded = clearMenu, onDismissRequest = { clearMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Clear this pocket") },
                        onClick = { clearMenu = false; actions.clearRun?.invoke() },
                        modifier = Modifier.testTag("pocket-card-clear-menu"),
                    )
                }
            }
        }
        if (PocketCardText.isPlaying(actions, moment) && PocketCardText.canClear(actions)) {
            OutlinedButton(onClick = { actions.clearRun?.invoke() }, modifier = Modifier.fillMaxWidth().testTag("pocket-card-clear")) {
                Icon(Icons.Filled.Close, contentDescription = null)
                Text("Clear this pocket", modifier = Modifier.padding(start = 6.dp))
            }
        }
        Column {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .combinedClickable(role = Role.Button, onClick = { showWhy = !showWhy })
                    .testTag("pocket-card-why"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Why this colour", color = PdjOnSurfaceVariant, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Icon(if (showWhy) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = null, tint = PdjOnSurfaceVariant)
            }
            if (showWhy) {
                Text(PocketCardText.whyText(moment, names), color = PdjOnSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("pocket-card-why-text"))
            }
        }
        val rows = actions.runHistory?.invoke(moment.key).orEmpty()
        if (rows.isNotEmpty()) {
            Column(Modifier.testTag("pocket-card-runs"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Past runs", color = PdjOnSurfaceVariant, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                for (r in rows.take(5)) {
                    Row(Modifier.fillMaxWidth()) {
                        Text(PocketCardText.runLabel(r.startedAtMs, nowMs()), color = PdjOnBackground, fontSize = 12.sp, modifier = Modifier.weight(1f))
                        Text(PocketCardText.runSummary(r.playedThrough, r.skipRate), color = PdjOnSurfaceVariant, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun FeatureRow(k: String, v: String) {
    Row(verticalAlignment = Alignment.Top) {
        Text(k, color = PdjOnSurfaceVariant, fontSize = 12.sp, modifier = Modifier.width(60.dp))
        Text(v, color = PdjOnBackground, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun Stat(p: Pair<String, String>) {
    Column {
        Text(p.first, color = PdjOnBackground, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleSmall)
        Text(p.second, color = PdjOnSurfaceVariant, fontSize = 11.sp)
    }
}
