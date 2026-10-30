package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.stats.PlayCountService
import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.asForYouCollections
import com.levi.pocketdj.data.collections.recommendationsOffIds
import com.levi.pocketdj.data.collections.suggestibleCollections
import com.levi.pocketdj.data.recs.ForYouFeedInputs
import com.levi.pocketdj.data.recs.ForYouFeedSnapshot
import com.levi.pocketdj.data.recs.ForYouFeedStore
import com.levi.pocketdj.data.recs.ForYouGrid
import com.levi.pocketdj.data.recs.ForYouRefreshSchedule
import com.levi.pocketdj.data.recs.ForYouSettings
import com.levi.pocketdj.data.recs.ForYouTile
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.ForYouTileRoute
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.data.recs.ZoneCatalog
import com.levi.pocketdj.data.recs.ZoneEngine
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// =====================================================================================
// Pure, JVM-tested pieces
// =====================================================================================

/** Adaptive tile grid geometry (iOS `GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)`). */
object ForYouTileLayout {
    const val MIN_TILE_DP = 150
    const val MAX_TILE_DP = 260
    const val SPACING_DP = 12
    const val PADDING_DP = 12
    const val CARD_HEIGHT_DP = 116

    /** How many columns fit in [widthDp] (>= 1), SwiftUI-adaptive style. */
    fun columns(widthDp: Int): Int {
        val avail = widthDp - 2 * PADDING_DP
        return maxOf(1, (avail + SPACING_DP) / (MIN_TILE_DP + SPACING_DP))
    }

    /** One tile's width, clamped to the iOS maximum. */
    fun tileWidthDp(widthDp: Int): Int {
        val cols = columns(widthDp)
        val avail = widthDp - 2 * PADDING_DP - (cols - 1) * SPACING_DP
        return minOf(MAX_TILE_DP, avail / cols)
    }
}

/** When the feed is rebuilt (the ONLY recompute). */
object ForYouRefreshPolicy {
    /**
     * After the catalog lands / the tab opens: a cold install (no cached result) always builds;
     * otherwise only a due schedule replaces the cache. Never while loading or already refreshing.
     */
    fun shouldRefreshAfterCatalog(catalogLoaded: Boolean, hasResult: Boolean, isRefreshing: Boolean, scheduleDue: Boolean): Boolean {
        if (!catalogLoaded || isRefreshing) return false
        return !hasResult || scheduleDue
    }

    /** Foreground / ON_RESUME: schedule only. */
    fun shouldRefreshOnResume(catalogLoaded: Boolean, isRefreshing: Boolean, scheduleDue: Boolean): Boolean =
        catalogLoaded && !isRefreshing && scheduleDue

    /** Cold install: a spinner only until the first build. */
    fun showSpinner(hasResult: Boolean): Boolean = !hasResult

    /** Only an ON_RESUME after a real pause is "coming back to the app" (addObserver replays the current state). */
    fun isRealResume(event: Lifecycle.Event, wasPaused: Boolean): Boolean =
        event == Lifecycle.Event.ON_RESUME && wasPaused
}

/**
 * Runs refresh work in a scope that OUTLIVES the screen (the app scope), one at a time. The UI only
 * triggers; leaving composition never cancels a build. Returns false when one is already running.
 */
class ForYouSingleFlight(private val scope: CoroutineScope) {
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)
    fun launch(block: suspend () -> Unit): Boolean {
        if (!running.compareAndSet(false, true)) return false
        scope.launch {
            try { block() } finally { running.set(false) }
        }
        return true
    }
}

/** SF-symbol name (from ForYouTiles) -> Material icon. */
internal fun forYouTileIcon(symbol: String): ImageVector = when (symbol) {
    "sparkles" -> Icons.Filled.AutoAwesome
    "waveform.circle.fill" -> Icons.Filled.GraphicEq
    "square.stack" -> Icons.Filled.Layers
    else -> Icons.AutoMirrored.Filled.QueueMusic
}

// =====================================================================================
// Inputs + refresh (snapshot on the caller, rank off-main)
// =====================================================================================

/** Builds [ForYouFeedInputs] from the live graph (iOS `ForYouTilesView.refresh`). */
internal object ForYouInputsFactory {
    @Volatile private var zoneMemo: Pair<MergedCatalog, ZoneCatalog>? = null

    fun zoneCatalog(catalog: MergedCatalog): ZoneCatalog {
        zoneMemo?.let { if (it.first === catalog) return it.second }
        return ZoneCatalog.from(catalog).also { zoneMemo = catalog to it }
    }

    /** Null until the catalog has landed (an empty-catalog ranking must never be stamped). */
    suspend fun build(graph: AppGraph): ForYouFeedInputs? = withContext(Dispatchers.IO) {
        val catalog = graph.catalogRepository.state.value.catalog ?: return@withContext null
        if (catalog.songs.isEmpty()) return@withContext null
        val now = System.currentTimeMillis().toDouble()
        // The timbre corpus first (memoized; fail-open to {} offline = pre-v2 ranking).
        val timbre = runCatching { graph.browseGraph.timbreCatalog.vectors() }.getOrDefault(emptyMap())
        val zc = zoneCatalog(catalog)
        val collections = graph.collections
        val feedback = graph.browseGraph.recFeedbackStore
        val history = PlayHistoryStore.get(graph.appContext)
        // Cumulative counts from PlayStatsStore (iOS ForYouView:301), snapshotted here on IO, never Main.
        val playStats = graph.servicesGraph.playStats
        // One-time: an upgrade from a pre-stats build has history but an empty stats doc.
        playStats.seedFromHistoryIfNeeded(history.events)
        val snap = PlayCountService(playStats).snapshot()
        val counts = snap.plays
        val last = snap.lastPlayedMs
        val penalty = snap.skipPenalty
        fun withSkips(fb: ZoneEngine.Feedback) = PlayCountService.withSkips(fb, penalty)

        val members = collections.suggestibleCollections()
        val recsOff = collections.recommendationsOffIds()
        ForYouFeedInputs(
            songs = catalog.songs,
            tracks = zc.tracks,
            genreBySongId = zc.genreBySongId,
            plays = history.recentPlaysForZone().map { ZoneEngine.Play(it.songId, it.playedAt) },
            playCount = counts,
            lastPlayedMs = last,
            skipPenalty = penalty,
            crates = members.map { ForYouFeedSnapshot.Crate(it.id, it.kind, it.name, it.songIds) },
            zoneFeedback = withSkips(feedback.zoneFeedback(ForYouTileKind.ZONE.raw, now)),
            crateFeedback = members.filter { it.id !in recsOff }
                .associate { it.id to withSkips(feedback.zoneFeedback(it.id, now)) },
            recsOffCrateIds = recsOff,
            timbre = timbre,
            nowMs = now,
        )
    }

    /**
     * The cloud ranker for In Da Zone, only when the user opted in (iOS: `recEngine.isEnabled`); null otherwise
     * so the zone ranks on device. [force] is the manual Refresh (skips the service's 15-min TTL).
     */
    internal fun cloudZoneProvider(svc: com.levi.pocketdj.data.recs.RecommendationService, force: Boolean):
        (suspend () -> List<com.levi.pocketdj.data.recs.ForYouCloudZoneRow>)? =
        if (svc.isEnabled) ({ svc.cloudZoneRanking(force) }) else null

    /** Refresh the durable feed (device zone, or the cloud ranking when the engine is on). */
    suspend fun refresh(graph: AppGraph, feed: ForYouFeedStore, force: Boolean = false) {
        val inputs = build(graph) ?: return
        withContext(Dispatchers.IO) {
            feed.refresh(inputs, cloudZone = cloudZoneProvider(graph.browseGraph.recService, force))
            // Background errand for the NEXT ranking (iOS scheduleAudioAnalysis): ids only, gated on the engine.
            runCatching { graph.browseGraph.recService.scheduleAudioAnalysis(feed.snapshot, inputs) }
        }
    }

    private val flights = java.util.WeakHashMap<AppGraph, ForYouSingleFlight>()

    /** Single-flight, app-scoped trigger; [shouldRun] is evaluated inside the flight (cheap, after the guard). */
    fun launchRefresh(graph: AppGraph, feed: ForYouFeedStore, force: Boolean = false, shouldRun: suspend () -> Boolean = { true }) {
        val flight = synchronized(flights) { flights.getOrPut(graph) { ForYouSingleFlight(graph.appScope) } }
        flight.launch {
            if (shouldRun()) refresh(graph, feed, force)
        }
    }

    suspend fun isScheduleDue(graph: AppGraph, snapshot: ForYouFeedSnapshot, nowMs: Double): Boolean {
        val s = ForYouSettings.load(graph.settings)
        return ForYouRefreshSchedule.isDue(nowMs, snapshot.refreshedAtMs, s.cadence, s.minutesOfDay, s.weekday)
    }
}

/** Stores the For You screens read; they touch files on first access, so resolve off-main. */
internal class ForYouStores(
    val feed: ForYouFeedStore,
    val feedback: RecFeedbackStore,
    val collections: CollectionsStore,
)

@Composable
internal fun rememberForYouStores(graph: AppGraph): ForYouStores? {
    // Warm lazies resolve synchronously so the cached grid paints on the first frame.
    val warm = remember(graph) {
        if (graph.browseGraph.forYouStoresReady) {
            ForYouStores(graph.browseGraph.forYouFeedStore, graph.browseGraph.recFeedbackStore, graph.collections)
        } else null
    }
    if (warm != null) return warm
    val stores by produceState<ForYouStores?>(null, graph) {
        value = withContext(Dispatchers.IO) {
            ForYouStores(graph.browseGraph.forYouFeedStore, graph.browseGraph.recFeedbackStore, graph.collections)
        }
    }
    return stores
}

/** Start [ids] as the Now Playing queue and stamp the feedback scope so transports can file verdicts. */
internal suspend fun playForYouIds(
    graph: AppGraph,
    feedback: RecFeedbackStore,
    scope: String,
    title: String,
    ids: List<String>,
    shuffle: Boolean,
): Result<Unit> = runCatching {
    graph.shellGraph.shellActions.playSongIds(ids, title, shuffle, PlayContext.SOURCE_BROWSER)
    feedback.beginPlayback(scope, ids)
}

// =====================================================================================
// The tiles screen
// =====================================================================================

/**
 * History ▸ For You: the CACHED grid. Cards are derived from the frozen snapshot + live feedback +
 * live collections (never a re-rank); the ranking recomputes only on [refreshToken] bumps (menu
 * Refresh), the first build after the catalog lands, or a due schedule (tab open + ON_RESUME).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ForYouTilesScreen(
    refreshToken: Int,
    onOpenTile: (ForYouTileRoute) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val stores = rememberForYouStores(graph)
    if (stores == null) {
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    val feedState by stores.feed.state.collectAsState()
    val fbState by stores.feedback.state.collectAsState()
    val colState by stores.collections.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalogLoaded = catalogState.catalog != null
    val scope = rememberCoroutineScope()
    var recsOffNotice by remember { mutableStateOf<String?>(null) }

    val snapshot = feedState.snapshot
    // The derivation key IS the by-construction link to the song list: same ForYouGrid function.
    // The New tile's count / Coming soon / empty note come from the release feed (BRW-14). The service reads its
    // file on first touch, so it is resolved off-main; the grid shows 0 until it is there.
    val releaseFeed by produceState(graph.browseGraph.releaseFeedIfReady()) {
        if (value == null) value = withContext(Dispatchers.IO) { graph.browseGraph.releaseFeed }
    }
    val releaseRev = releaseFeed?.revisionFlow?.collectAsState()?.value ?: 0
    val releaseSource = remember(releaseFeed) { releaseFeed?.let { com.levi.pocketdj.data.recs.ReleaseFeedForYouSource(it) } }
    val tiles = remember(feedState.revision, snapshot.refreshedAtMs, fbState.revision, colState.revision, releaseRev, releaseSource) {
        ForYouGrid.tiles(snapshot, stores.collections.asForYouCollections(), stores.feedback, releaseSource)
    }
    val updatedLabel = remember(feedState.revision, snapshot.refreshedAtMs) {
        ForYouFeedStore.updatedLabel(snapshot.refreshedAtMs)
    }

    // First population (gated on the catalog) or a due schedule; re-armed when the catalog lands.
    LaunchedEffect(catalogLoaded) {
        if (!catalogLoaded) return@LaunchedEffect
        ForYouInputsFactory.launchRefresh(graph, stores.feed) {
            val s = stores.feed.state.value
            val due = ForYouInputsFactory.isScheduleDue(graph, s.snapshot, System.currentTimeMillis().toDouble())
            ForYouRefreshPolicy.shouldRefreshAfterCatalog(true, s.snapshot.hasResult, s.isRefreshing, due)
        }
    }
    // The schedule's second read point: coming back to the app (never a timer / WorkManager).
    DisposableEffect(catalogLoaded) {
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        var wasPaused = false
        val obs = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE) wasPaused = true
            if (ForYouRefreshPolicy.isRealResume(event, wasPaused)) {
                wasPaused = false
                ForYouInputsFactory.launchRefresh(graph, stores.feed) {
                    val s = stores.feed.state.value
                    val due = ForYouInputsFactory.isScheduleDue(graph, s.snapshot, System.currentTimeMillis().toDouble())
                    ForYouRefreshPolicy.shouldRefreshOnResume(catalogLoaded, s.isRefreshing, due)
                }
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }
    // The owner's Refresh (menu): works under every cadence, manual included.
    var lastToken by remember { mutableStateOf(refreshToken) }
    LaunchedEffect(refreshToken) {
        if (refreshToken != lastToken) {
            lastToken = refreshToken
            ForYouInputsFactory.launchRefresh(graph, stores.feed, force = true)
        }
    }

    Column(modifier.fillMaxSize()) {
        FreshnessBar(label = if (feedState.isRefreshing) "Refreshing…" else updatedLabel, refreshing = feedState.isRefreshing)
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val widthDp = maxWidth.value.toInt()
            val cols = ForYouTileLayout.columns(widthDp)
            if (snapshot.hasResult) LazyVerticalGrid(
                columns = GridCells.Fixed(cols),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(ForYouTileLayout.PADDING_DP.dp),
                horizontalArrangement = Arrangement.spacedBy(ForYouTileLayout.SPACING_DP.dp),
                verticalArrangement = Arrangement.spacedBy(ForYouTileLayout.SPACING_DP.dp),
                modifier = Modifier.fillMaxSize().testTag("foryou-grid"),
            ) {
                items(tiles, key = { it.id }) { tile ->
                    TileWithMenu(
                        tile = tile,
                        snapshot = snapshot,
                        stores = stores,
                        onOpen = { onOpenTile(tile.route) },
                        onPlay = { ids, shuffle ->
                            scope.launch {
                                playForYouIds(graph, stores.feedback, tile.route.feedbackContext, tile.title, ids, shuffle)
                                    .onFailure { Toast.makeText(context, it.message ?: "Couldn't start playback", Toast.LENGTH_SHORT).show() }
                            }
                        },
                        onRecsOff = { recsOffNotice = CollectionRecsCopy.offNotice(tile.title) },
                    )
                }
            }
            if (ForYouRefreshPolicy.showSpinner(snapshot.hasResult)) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                    CircularProgressIndicator(Modifier.padding(40.dp))
                }
            }
        }
    }

    recsOffNotice?.let { msg ->
        AlertDialog(
            onDismissRequest = { recsOffNotice = null },
            title = { Text("Recommendations off") },
            text = { Text(msg, modifier = Modifier.testTag("foryou-recs-off-notice")) },
            confirmButton = { TextButton(onClick = { recsOffNotice = null }) { Text("OK") } },
        )
    }
}

@Composable
private fun FreshnessBar(label: String, refreshing: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Icon(
            Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(14.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 8.dp).weight(1f).testTag("foryou-updated-at"),
        )
        if (refreshing) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TileWithMenu(
    tile: ForYouTile,
    snapshot: ForYouFeedSnapshot,
    stores: ForYouStores,
    onOpen: () -> Unit,
    onPlay: (ids: List<String>, shuffle: Boolean) -> Unit,
    onRecsOff: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        ForYouTileCard(
            tile = tile,
            modifier = Modifier
                .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
                .testTag("foryou-tile-${tile.id}"),
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            // LIVE rows only: the sunk tail renders on the tile's own screen, never as a queue.
            val live = remember(menu, tile.id, snapshot.refreshedAtMs) {
                if (!menu || tile.route.kind == ForYouTileKind.NEW) emptyList()
                else {
                    val scope = tile.route.feedbackContext
                    val ids = ForYouGrid.songIds(tile, snapshot, stores.collections.asForYouCollections(), stores.feedback)
                    stores.feedback.partition(ids, scope).live
                }
            }
            DropdownMenuItem(
                text = { Text("Play") },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
                enabled = live.isNotEmpty(),
                onClick = { menu = false; onPlay(live, false) },
                modifier = Modifier.testTag("foryou-tile-${tile.id}-play"),
            )
            DropdownMenuItem(
                text = { Text("Shuffle") },
                leadingIcon = { Icon(Icons.Filled.Shuffle, null) },
                enabled = live.isNotEmpty(),
                onClick = { menu = false; onPlay(live, true) },
                modifier = Modifier.testTag("foryou-tile-${tile.id}-shuffle"),
            )
            tile.route.collectionId?.let { cid ->
                HorizontalDivider()
                CollectionRecsToggle(
                    collections = stores.collections,
                    collectionId = cid,
                    idPrefix = "foryou-tile-col-$cid",
                    onTurnedOff = { menu = false; onRecsOff() },
                )
            }
        }
    }
}

@Composable
private fun ForYouTileCard(tile: ForYouTile, modifier: Modifier = Modifier) {
    val tint = Color(0xFF000000L or tile.tintHex)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        border = BorderStroke(1.dp, if (tile.isPinned) tint.copy(alpha = 0.55f) else MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier.fillMaxWidth().height(ForYouTileLayout.CARD_HEIGHT_DP.dp),
    ) {
        // Tighter rhythm so the 2-line subtitle fits the fixed card height (it truncated to 1 line).
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(forYouTileIcon(tile.symbol), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
                Spacer(Modifier.weight(1f))
                Text("${tile.count}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            }
            Text(tile.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                tile.subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
