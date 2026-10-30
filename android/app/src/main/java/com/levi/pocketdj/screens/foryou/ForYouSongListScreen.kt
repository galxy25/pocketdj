package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.stats.PlayCountService
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.recommendationsEnabled
import com.levi.pocketdj.data.recs.ForYouFeedStore
import com.levi.pocketdj.data.recs.ForYouGrid
import com.levi.pocketdj.data.recs.ForYouCollections
import com.levi.pocketdj.data.collections.asForYouCollections
import com.levi.pocketdj.data.collections.playableIdsForAnyCollection
import com.levi.pocketdj.data.collections.suggestionsExcludingMembers
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ForYouTileRoute
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.data.recs.ZoneEngine
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// =====================================================================================
// Pure state logic (JVM-tested)
// =====================================================================================

/** What a 👍 does on this list: add straight to the implied crate, or open the Add sheet. */
sealed interface ForYouAcceptPlan {
    data class AddToCrate(val target: AddTarget) : ForYouAcceptPlan
    data object OpenSheet : ForYouAcceptPlan
}

object ForYouSongListState {
    /** Live rows first, then the sunk tail (dimmed, still reachable so a lit 👎 can be undone). */
    fun visibleIds(partition: RecFeedbackStore.Partition): List<String> = partition.live + partition.sunk

    /**
     * Header. For the zone the blend IS the feature, so the count says what it is made of:
     * "N songs · B buried" (only LIVE buried rows count); every other list is "N songs".
     */
    fun blendSummary(kind: ForYouTileKind, partition: RecFeedbackStore.Partition, buriedIds: Set<String>): String {
        val n = partition.live.size
        val buried = if (kind == ForYouTileKind.ZONE) partition.live.count { it in buriedIds } else 0
        val songs = com.levi.pocketdj.screens.browse.Fmt.count(n, "song")
        return if (kind == ForYouTileKind.ZONE && buried > 0) "$songs · $buried buried" else songs
    }

    /** A collection tile with a resolvable target adds straight to it; the zone (and a dead id) opens the sheet. */
    fun acceptPlan(kind: ForYouTileKind, target: AddTarget?): ForYouAcceptPlan =
        if (kind == ForYouTileKind.COLLECTION && target != null) ForYouAcceptPlan.AddToCrate(target)
        else ForYouAcceptPlan.OpenSheet

    /**
     * The frozen ids as the list opens: a collection's already-members are NOT offers (read-time),
     * the zone drops permanently accepted rows; both through the SAME calls the card counts by.
     */
    fun frozenIds(
        route: ForYouTileRoute,
        frozen: List<String>,
        collections: ForYouCollections,
        feedback: RecFeedbackStore?,
    ): List<String> = when {
        route.kind == ForYouTileKind.COLLECTION && route.collectionId != null ->
            collections.suggestionsExcludingMembers(frozen, route.collectionId)
        else -> ForYouGrid.excludingAccepted(frozen, route.feedbackContext, feedback)
    }

    /** Tap on a row: the zone is a QUEUE (play from here); a collection list is an ADD list (open the song). */
    fun tapPlays(kind: ForYouTileKind): Boolean = kind == ForYouTileKind.ZONE

    /** The queue a tap-to-play starts: from the tapped row to the end of the VISIBLE list. */
    fun queueFrom(visible: List<String>, index: Int): List<String> =
        if (index in visible.indices) visible.subList(index, visible.size).toList() else emptyList()

    const val EMPTY_TITLE = "Nothing to suggest yet"
    const val EMPTY_CAPTION = "Play a few more songs and this fills in."
}

/** What the screen loaded: ids + the per-row decorations that ride the same frozen document. */
internal data class ForYouListData(
    val songIds: List<String> = emptyList(),
    val reasons: Map<String, String> = emptyMap(),
    val soundIds: Set<String> = emptySet(),
    val buriedIds: Set<String> = emptySet(),
)

// =====================================================================================
// Screen
// =====================================================================================

/**
 * A For You tile's list. Frozen ids FIRST (the same document the card counted); the on-demand
 * fallback (no frozen entry) ranks off-main and, for a collection with recs OFF, is a hard no-op
 * so a restored route can never run the sweep the switch exists to prevent.
 */
@Composable
fun ForYouSongListScreen(
    route: ForYouTileRoute,
    onBack: () -> Unit,
    onOpenSong: (String) -> Unit,
    onOpenCollection: (kind: String, id: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val stores = rememberForYouStores(graph)
    if (stores == null) {
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalog = catalogState.catalog
    val fbState by stores.feedback.state.collectAsState()
    val colState by stores.collections.state.collectAsState()
    val scope = rememberCoroutineScope()
    val fbScope = route.feedbackContext

    var data by remember(route.tileId) { mutableStateOf<ForYouListData?>(null) }
    var added by remember(route.tileId) { mutableStateOf(setOf<String>()) }
    var addSheetFor by remember { mutableStateOf<AddToItem?>(null) }
    var menu by remember { mutableStateOf(false) }

    LaunchedEffect(route.tileId, catalog != null) {
        if (data != null) return@LaunchedEffect
        // null = inputs unavailable (no catalog yet): stay unloaded so the catalog-keyed re-run builds.
        loadForYouList(graph, stores, route)?.let { data = it }
    }

    val d = data
    val partition = remember(d, fbState.revision) {
        stores.feedback.partition(d?.songIds.orEmpty(), fbScope)
    }
    val visible = ForYouSongListState.visibleIds(partition)

    fun start(ids: List<String>, shuffle: Boolean) {
        if (ids.isEmpty()) return
        scope.launch {
            playForYouIds(graph, stores.feedback, fbScope, route.title, ids, shuffle)
                .onFailure { Toast.makeText(context, it.message ?: "Couldn't start playback", Toast.LENGTH_SHORT).show() }
        }
    }

    fun accept(id: String) {
        val target = route.collectionId?.let { cid ->
            when {
                stores.collections.playlist(cid) != null -> AddTarget(AddTarget.Kind.PLAYLIST, cid)
                stores.collections.pocket(cid) != null -> AddTarget(AddTarget.Kind.POCKET, cid)
                else -> null
            }
        }
        when (val plan = ForYouSongListState.acceptPlan(route.kind, target)) {
            is ForYouAcceptPlan.AddToCrate -> {
                stores.collections.addSong(id, plan.target)
                added = added + id
            }
            ForYouAcceptPlan.OpenSheet -> addSheetFor = AddToItem.Song(id)
        }
    }

    Column(modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
            IconButton(onClick = onBack, modifier = Modifier.testTag("foryou-list-back")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Text(
                route.title, style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            // The transport plays partition.live and NOTHING else; all-thumbed-down greys it.
            IconButton(onClick = { start(partition.live, false) }, enabled = partition.live.isNotEmpty(), modifier = Modifier.testTag("foryou-list-play")) {
                Icon(Icons.Filled.PlayArrow, contentDescription = "Play")
            }
            IconButton(onClick = { start(partition.live, true) }, enabled = partition.live.isNotEmpty(), modifier = Modifier.testTag("foryou-list-shuffle")) {
                Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle")
            }
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("foryou-list-more")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "More")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text("Add all to…") },
                        enabled = partition.live.isNotEmpty(),
                        onClick = { menu = false; addSheetFor = AddToItem.Songs(partition.live) },
                        modifier = Modifier.testTag("foryou-list-add-all"),
                    )
                    val cid = route.collectionId
                    if (route.kind == ForYouTileKind.COLLECTION && cid != null) {
                        val pl = stores.collections.playlist(cid)
                        val pk = stores.collections.pocket(cid)
                        val name = pl?.name ?: pk?.name
                        if (name != null) {
                            DropdownMenuItem(
                                text = { Text("Open $name") },
                                onClick = { menu = false; onOpenCollection(if (pl != null) "playlist" else "pocket", cid) },
                                modifier = Modifier.testTag("foryou-list-open-collection"),
                            )
                        }
                    }
                }
            }
        }

        when {
            d == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            visible.isEmpty() -> EmptyList()
            else -> LazyColumn(Modifier.fillMaxSize().testTag("foryou-list")) {
                item(key = "header") {
                    Text(
                        ForYouSongListState.blendSummary(route.kind, partition, d.buriedIds),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp).testTag("foryou-list-summary"),
                    )
                }
                itemsIndexed(visible, key = { _, id -> id }) { index, id ->
                    val song = catalog?.songsById?.get(id)
                    val sunk = stores.feedback.isSuppressed(id, fbScope)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .alpha(if (sunk) 0.45f else 1f)
                            .clickable {
                                if (ForYouSongListState.tapPlays(route.kind)) start(ForYouSongListState.queueFrom(visible, index), false)
                                else if (song != null) onOpenSong(id)
                            }
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                    ) {
                        Column(Modifier.weight(1f).testTag("foryou-song-$id")) {
                            Text(song?.name ?: id, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                if (!song?.artist.isNullOrEmpty()) {
                                    Text(
                                        song?.artist.orEmpty(), style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f, fill = false),
                                    )
                                }
                                if (id in d.buriedIds) Badge("Buried", MaterialTheme.colorScheme.tertiary, "foryou-buried-$id")
                                if (id in d.soundIds) Badge("Sounds like", MaterialTheme.colorScheme.primary, "foryou-soundmatch-$id")
                            }
                            d.reasons[id]?.takeIf { it.isNotEmpty() }?.let { why ->
                                Text(
                                    why, style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        // 👍 IS the add; the ✓ states ownership only after the add lands.
                        RecFeedbackButtons(id, fbScope, stores.feedback, catalog, onAccept = { accept(id) })
                        if (id in added) {
                            Icon(
                                Icons.Filled.CheckCircle, contentDescription = "Added",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(22.dp).testTag("foryou-added-$id"),
                            )
                        }
                    }
                }
            }
        }
    }

    addSheetFor?.let { item ->
        AddToCollectionSheet(
            item = item,
            onDismiss = { addSheetFor = null },
            onAdded = {
                added = when (item) {
                    is AddToItem.Song -> added + item.id
                    is AddToItem.Songs -> added + item.ids
                    else -> added
                }
            },
        )
    }
}

@Composable
private fun Badge(text: String, color: androidx.compose.ui.graphics.Color, tag: String) {
    Surface(shape = RoundedCornerShape(3.dp), color = color.copy(alpha = 0.22f), modifier = Modifier.testTag(tag)) {
        Text(
            text, color = color, fontSize = 9.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
        )
    }
}

@Composable
private fun EmptyList() {
    Column(
        Modifier.fillMaxSize().padding(30.dp).testTag("foryou-songlist-empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Filled.GraphicEq, contentDescription = null, modifier = Modifier.size(34.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(ForYouSongListState.EMPTY_TITLE, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
        Text(
            ForYouSongListState.EMPTY_CAPTION, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
    }
}

/** Frozen ids first; otherwise rank on demand OFF the main thread. NEW has its own screen -> empty. */
private suspend fun loadForYouList(graph: AppGraph, stores: ForYouStores, route: ForYouTileRoute): ForYouListData? =
    withContext(Dispatchers.Default) {
        val tileId = route.tileId
        val cols = stores.collections.asForYouCollections()
        val frozen = stores.feed.songIds(tileId)
        if (frozen != null) {
            val ids = ForYouSongListState.frozenIds(route, frozen, cols, stores.feedback)
            val buried = if (route.kind == ForYouTileKind.ZONE) {
                stores.feed.snapshot.zoneBuriedIds.toSet().intersect(frozen.toSet())
            } else emptySet()
            return@withContext ForYouListData(
                songIds = ids,
                reasons = stores.feed.reasons(tileId),
                soundIds = stores.feed.soundIds(tileId),
                buriedIds = buried,
            )
        }
        when (route.kind) {
            ForYouTileKind.NEW -> ForYouListData()
            ForYouTileKind.ZONE -> {
                val inputs = ForYouInputsFactory.build(graph) ?: return@withContext null
                val counts = inputs.playCount
                val q = ZoneEngine.inDaZone(
                    songs = inputs.songs, genreBySongId = inputs.genreBySongId,
                    otherCollections = inputs.crates.map { it.songIds }, plays = inputs.plays,
                    playCount = { counts[it] ?: 0 }, lastPlayedMs = inputs.lastPlayedMs,
                    feedback = inputs.zoneFeedback, timbre = inputs.timbre, nowMs = inputs.nowMs,
                )
                ForYouListData(
                    songIds = q.songIds,
                    buriedIds = q.picks.filter { it.pool == ZoneEngine.Pool.REDISCOVERY }.map { it.songId }.toSet(),
                )
            }
            ForYouTileKind.COLLECTION -> {
                // The second door to the same work, and it has to be shut too: recs OFF => no sweep.
                val cid = route.collectionId
                if (cid == null || !stores.collections.recommendationsEnabled(cid)) return@withContext ForYouListData()
                val inputs = ForYouInputsFactory.build(graph) ?: return@withContext null
                val counts = inputs.playCount
                val ranked = ZoneEngine.explainedSuggestions(
                    memberSongIds = stores.collections.playableIdsForAnyCollection(cid),
                    tracks = inputs.tracks, playCount = { counts[it] ?: 0 },
                    feedback = inputs.crateFeedback[cid]
                        ?: PlayCountService.withSkips(
                            stores.feedback.zoneFeedback(route.feedbackContext, inputs.nowMs),
                            inputs.skipPenalty,
                        ), timbre = inputs.timbre,
                )
                ForYouListData(
                    songIds = ranked.rows.map { it.songId },
                    reasons = ranked.rows.filter { it.why.isNotEmpty() }.associate { it.songId to it.why },
                    soundIds = ranked.soundAdmitted,
                )
            }
        }
    }
