package com.levi.pocketdj.screens.foryou

import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.ManageAccounts
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.recs.ArtistReleaseEntry
import com.levi.pocketdj.data.recs.ForYouTileKind
import com.levi.pocketdj.data.recs.LikeAddState
import com.levi.pocketdj.data.recs.LikedReleaseSelection
import com.levi.pocketdj.data.recs.LikedRow
import com.levi.pocketdj.data.recs.ReleaseEmptyReason
import com.levi.pocketdj.data.recs.ReleaseFeedItem
import com.levi.pocketdj.data.recs.ReleaseStatus
import com.levi.pocketdj.data.recs.ReleaseStreamTrack
import com.levi.pocketdj.data.recs.ReleaseStreaming
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.levi.pocketdj.screens.discover.AlbumLibraryWriteRetry
import kotlinx.coroutines.flow.map

/**
 * Pure presentation logic of the New screen (iOS `NewReleasesView`'s helpers). Every function takes the
 * feedback maps as plain data so the rules are unit-tested without the store or the UI.
 */
object NewReleasesPresentation {
    /** The reserved scope for this tile: the same string `ForYouTileRoute.feedbackContext` yields for NEW. */
    val SCOPE: String = ForYouTileKind.NEW.raw

    /**
     * Releases already thumbed up, taken off these two sections. A thumbs-up now ADDS the record, so an accepted
     * release is on its way out of the feed for real (owned) - until it is, it lives in "Liked - not added"
     * rather than sitting in two places. Applied BEFORE [sunkLast]. [keeping] exempts the pre-orders that are
     * already added on the Apple Music side: those stay in Coming soon, badged "Pre-added".
     */
    fun offered(
        items: List<ReleaseFeedItem>,
        accepted: Map<String, Double>,
        keeping: Set<String> = emptySet(),
    ): List<ReleaseFeedItem> =
        if (accepted.isEmpty()) items
        else items.filter { accepted[it.feedbackId] == null || (it.entry.releaseId?.let(keeping::contains) ?: false) }

    // ---- "Liked - not added" copy (pure) ----

    /** The row's button: Retry Apple Music (recorded, write unproven), Retry (failed), else Add. */
    fun likedActionTitle(row: LikedRow): String = when {
        row.retryWriteOnly -> "Retry Apple Music"
        row.state == LikeAddState.FAILED -> "Retry"
        else -> "Add"
    }

    /** The row's state line; null for a plain not-yet-added row. */
    fun likedStatusLine(row: LikedRow, nowMs: Double): String? = when {
        row.inFlight -> "Adding…"
        row.retryWriteOnly -> row.message ?: LikeAddWording.NOT_CONFIRMED
        row.state == LikeAddState.AWAITING_RELEASE -> row.release.releaseAtMs
            ?.let { "Coming ${relative(it, nowMs).lowercase()} — will add on release day" }
            ?: "Will add on release day"
        row.state == LikeAddState.OFFLINE -> row.message ?: NewReleaseLikeAdder.OFFLINE_MESSAGE
        else -> row.message
    }

    /**
     * A rejected release SINKS to the bottom of its section (the same rule as every recommendation surface):
     * the row must stay on screen so the lit thumbs-down that undoes it stays reachable.
     */
    fun sunkLast(items: List<ReleaseFeedItem>, tombstones: Map<String, Double>): List<ReleaseFeedItem> =
        if (tombstones.isEmpty()) items
        else items.filter { tombstones[it.feedbackId] == null } + items.filter { tombstones[it.feedbackId] != null }

    /**
     * The PLAY list: the offered releases minus the thumbed-down tail. The transport gates on THIS, never on
     * the render list - gating on the render list left play lit over an empty queue once every release was
     * thumbed down, and the tap did nothing at all.
     */
    fun live(items: List<ReleaseFeedItem>, tombstones: Map<String, Double>): List<ReleaseFeedItem> =
        if (tombstones.isEmpty()) items else items.filter { tombstones[it.feedbackId] == null }

    fun canPlay(starting: Boolean, liveOutNow: List<ReleaseFeedItem>): Boolean = !starting && liveOutNow.isNotEmpty()

    /**
     * Deliberately coarse ("3 days ago"): the window is 30 days. Future dates get their OWN wording - an
     * age-in-days phrasing collapses every pre-order to "Today", the screen stating the opposite of the truth.
     */
    fun relative(atMs: Double, nowMs: Double): String {
        val days = Math.round((nowMs - atMs) / 86_400_000.0).toInt()
        if (days < 0) {
            val ahead = -days
            return if (ahead == 1) "Tomorrow" else "In $ahead days"
        }
        return when (days) {
            0 -> "Today"
            1 -> "Yesterday"
            else -> "$days days ago"
        }
    }

    /** Apple's artwork URLs are templates with literal `{w}`/`{h}`; unsubstituted they 404. */
    fun artworkUrl(template: String?, size: Int): String? =
        template?.replace("{w}", size.toString())?.replace("{h}", size.toString())

    fun albumUrl(releaseId: String): String = "https://music.apple.com/us/album/$releaseId"

    // ---- empty-state copy: four genuinely different causes hid behind one blank screen ----

    fun emptyTitle(r: ReleaseEmptyReason): String = when (r) {
        ReleaseEmptyReason.Checking -> "Checking for new releases…"
        ReleaseEmptyReason.NotAuthorized -> "Apple Music isn’t connected"
        is ReleaseEmptyReason.Unreachable -> "Couldn’t reach Apple Music"
        ReleaseEmptyReason.NotCheckedYet -> "Nothing checked yet"
        ReleaseEmptyReason.NothingNew -> "Nothing new in the last 30 days"
    }

    fun emptyDetail(r: ReleaseEmptyReason): String = when (r) {
        ReleaseEmptyReason.Checking -> "Looking up what the artists you’ve played in the last 30 days have put out."
        ReleaseEmptyReason.NotAuthorized -> "Turn on Apple Music in Settings so PocketDJ can look up new releases."
        is ReleaseEmptyReason.Unreachable -> "${r.message} This retries by itself the next time you play something."
        ReleaseEmptyReason.NotCheckedYet -> "Play something — the artists you listen to get checked for new releases."
        ReleaseEmptyReason.NothingNew -> "The artists you’ve played lately haven’t released anything this month."
    }

    fun emptyIcon(r: ReleaseEmptyReason) = when (r) {
        ReleaseEmptyReason.Checking -> Icons.Filled.Refresh
        ReleaseEmptyReason.NotAuthorized -> Icons.Filled.ManageAccounts
        is ReleaseEmptyReason.Unreachable -> Icons.Filled.CloudOff
        ReleaseEmptyReason.NotCheckedYet -> Icons.Filled.HourglassEmpty
        ReleaseEmptyReason.NothingNew -> Icons.Filled.AutoAwesome
    }
}

/**
 * The **New** tile's screen: Out now / Coming soon, thumbs scoped `new`, a "Check for new releases" menu
 * item, and play / shuffle over the out-now releases through `am:<storeId>` rows (cloud mode for an unowned
 * record). Playing an unowned release is Apple Music DRM playback - device-only to verify.
 */
@Composable
fun NewReleasesScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val browse = graph.browseGraph
    val stores = rememberForYouStores(graph)
    val feed by produceState(browse.releaseFeedIfReady()) {
        if (value == null) value = withContext(Dispatchers.IO) { browse.releaseFeed }
    }
    val service = feed
    // The like-adder reads the release feed's file on first touch: resolved off Main, like the feed itself.
    // A failed build must not blank the screen for good: fall back to a null adder (pure feedback, as on iOS).
    val likeAdderResult by produceState<Result<NewReleaseLikeAdder>?>(null) {
        value = withContext(Dispatchers.IO) { runCatching { NewReleaseLikeAdder.get(graph) } }
    }
    val adder = likeAdderResult?.getOrNull()
    if (stores == null || service == null || likeAdderResult == null) {
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    val feedback = stores.feedback
    val rev by service.revisionFlow.collectAsState()
    val fbState by feedback.state.collectAsState()
    val catalog = graph.catalogRepository.state.collectAsState().value.catalog
    val seqState by graph.playbackGraph.sequencer.state.collectAsState()
    val scope = rememberCoroutineScope()

    var starting by remember { mutableStateOf(false) }
    var startError by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var dismissedUnplayableFor by remember { mutableStateOf<Long?>(null) }

    val likedState by (adder?.store?.state ?: EMPTY_LIKED_STATE).collectAsState()
    val busy by (adder?.busy ?: EMPTY_BUSY).collectAsState()
    val canWrite by remember { graph.settings.settings.map { it.hasAppleMusic } }.collectAsState(false)
    val discoverSnap by graph.browseGraph.discoverAdds.state.collectAsState()

    val now = remember(rev, fbState.revision, likedState.revision) { System.currentTimeMillis().toDouble() }
    val accepted = remember(fbState.revision) { feedback.acceptedInScope(NewReleasesPresentation.SCOPE) }
    val tombstones = remember(fbState.revision) { feedback.activeTombstones(NewReleasesPresentation.SCOPE, now) }
    // Pre-orders whose Apple Music write PROVED it landed stay in Coming soon (badged) instead of vanishing
    // with the rest of the accepted rows: added as far as Apple can say; the PocketDJ side follows on release day.
    val preAdded = remember(likedState.revision) { LikedReleaseSelection.preAdded(likedState.releases, now, accepted) }
    val outNow = remember(rev, fbState.revision, preAdded) {
        NewReleasesPresentation.sunkLast(NewReleasesPresentation.offered(service.outNow(now), accepted, preAdded), tombstones)
    }
    val soon = remember(rev, fbState.revision, preAdded) {
        NewReleasesPresentation.sunkLast(NewReleasesPresentation.offered(service.comingSoon(now), accepted, preAdded), tombstones)
    }
    // "Liked - not added", from the pure selection. The probes are the feed's own, so a record owned by ANY
    // path drops out with no extra bookkeeping.
    val liked = remember(fbState.revision, likedState.revision, busy, rev, discoverSnap, canWrite) {
        LikedReleaseSelection.likedNotAdded(
            accepted = accepted,
            meta = likedState.releases,
            owns = { service.ownsRelease?.invoke(it) ?: false },
            ownsVersion = { a, n, t -> service.ownsReleaseVersion?.invoke(a, n, t) ?: false },
            writeNeedsRetry = { id ->
                discoverSnap.albums.firstOrNull { it.appleMusicId == id }
                    ?.takeIf { AlbumLibraryWriteRetry.needsRetry(it.libraryWrite, canWrite) }
                    ?.let { it.libraryWrite ?: LikeAddWording.NOT_CONFIRMED }
            },
            inFlight = busy.ids,
            nowMs = now,
        )
    }
    // Rebuild metadata for likes this install has never seen (older likes, another device's), then retry what
    // was waiting on a connection or a release day. Off the render path.
    // On the ADDER's scope: this screen's own scope is cancelled on back, which would abort a half-done add.
    LaunchedEffect(adder) {
        adder?.maintain(feedback.acceptedInScope(NewReleasesPresentation.SCOPE))
    }
    // The LIVE half, computed ONCE and used by both the rows and the transport's enabled state.
    val liveOutNow = remember(outNow, tombstones) { NewReleasesPresentation.live(outNow, tombstones) }
    val canPlay = NewReleasesPresentation.canPlay(starting, liveOutNow)

    fun start(shuffle: Boolean) {
        val ids = ReleaseStreaming.playableReleaseIds(liveOutNow)
        if (ids.isEmpty() || starting) return
        starting = true
        scope.launch {
            val rows = withContext(Dispatchers.IO) {
                ReleaseStreaming.tracks(ids) { id -> expandRelease(graph, id) }
            }
            var queue = ReleaseStreaming.items(rows) { browse.catalogSongIdForAppleMusicId(it) }
            if (shuffle) queue = queue.shuffled()
            starting = false
            if (queue.isEmpty()) {
                startError = ReleaseStreaming.EMPTY_EXPANSION_MESSAGE
                return@launch
            }
            // TAGGED so device mode can explain itself (a New queue is not a collection; nothing resolves
            // this id by design). A verdict on this tile is filed against a RELEASE, so no feedback scope is
            // stamped on the run: tuning is the thumbs on the rows.
            graph.playbackGraph.sequencer.play(queue, sourceSetlistId = ReleaseStreaming.RUN_TAG)
        }
    }

    Column(modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
            IconButton(onClick = onBack, modifier = Modifier.testTag("foryou-new-back")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Text("New", style = MaterialTheme.typography.titleLarge, maxLines = 1, modifier = Modifier.weight(1f))
            IconButton(onClick = { start(false) }, enabled = canPlay, modifier = Modifier.testTag("foryou-new-play")) {
                Icon(Icons.Filled.PlayArrow, contentDescription = "Play")
            }
            IconButton(onClick = { start(true) }, enabled = canPlay, modifier = Modifier.testTag("foryou-new-shuffle")) {
                Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle")
            }
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("foryou-new-more")) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "More")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    // Disabled - never absent - while a pass is in flight or Apple Music is off.
                    DropdownMenuItem(
                        text = { Text("Check for new releases") },
                        leadingIcon = { Icon(Icons.Filled.Refresh, null) },
                        enabled = service.canRecheck,
                        onClick = { menu = false; service.recheckKnownArtists() },
                        modifier = Modifier.testTag("foryou-new-recheck"),
                    )
                }
            }
        }

        // The empty state means "nothing at all" - a liked-but-not-added record is something.
        if (outNow.isEmpty() && soon.isEmpty() && liked.rows.isEmpty()) {
            EmptyState(service.emptyReason())
        } else {
            LazyColumn(Modifier.fillMaxSize().testTag("foryou-new-list")) {
                if (adder != null) likedSection(liked.rows, now, catalog, feedback, adder)
                section(ReleaseStatus.OUT_NOW, outNow, now, catalog, feedback, context, adder, preAdded)
                section(ReleaseStatus.COMING_SOON, soon, now, catalog, feedback, context, adder, preAdded)
            }
        }
    }

    startError?.let { msg ->
        AlertDialog(
            onDismissRequest = { startError = null },
            title = { Text("Couldn’t start these releases") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { startError = null }) { Text("OK") } },
        )
    }
    // DEVICE MODE MUST NOT GO QUIETLY SILENT HERE - these are records he does not own.
    if (seqState.deviceQueueUnplayable && seqState.deviceUnplayableSourceId == ReleaseStreaming.RUN_TAG &&
        dismissedUnplayableFor != seqState.playGeneration
    ) {
        AlertDialog(
            onDismissRequest = { dismissedUnplayableFor = seqState.playGeneration },
            title = { Text("Nothing here is on this device") },
            text = { Text("None of these releases are downloaded. Switch playback to Cloud to stream them.") },
            confirmButton = { TextButton(onClick = { dismissedUnplayableFor = seqState.playGeneration }) { Text("OK") } },
        )
    }
}

/** Expand one release id into tracks via the Apple Music catalog API; empty on any failure. */
private suspend fun expandRelease(graph: AppGraph, releaseId: String): List<ReleaseStreamTrack> =
    when (val r = graph.appleMusicApi.albumTracks(releaseId)) {
        is AmResult.Ok -> r.value.map {
            ReleaseStreamTrack(it.id, it.title, it.artist, it.durationMs?.toLong())
        }
        else -> emptyList()
    }

private fun androidx.compose.foundation.lazy.LazyListScope.section(
    status: ReleaseStatus,
    rows: List<ReleaseFeedItem>,
    now: Double,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    feedback: com.levi.pocketdj.data.recs.RecFeedbackStore,
    context: android.content.Context,
    adder: NewReleaseLikeAdder?,
    preAdded: Set<String>,
) {
    if (rows.isEmpty()) return
    item(key = "h-${status.raw}") {
        Text(
            status.title,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).testTag("new-release-section-${status.raw}"),
        )
    }
    items(rows, key = { "${status.raw}-${it.entry.artistId}" }) { item ->
        ReleaseRow(item, now, catalog, feedback, context, adder, preAdded)
    }
}

/**
 * "Liked - not added": what he thumbed up but that never made it into the library. Android has no album
 * preview screen, so the row tap still opens Apple Music and the Add happens HERE, on the row.
 */
private fun androidx.compose.foundation.lazy.LazyListScope.likedSection(
    rows: List<LikedRow>,
    now: Double,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    feedback: com.levi.pocketdj.data.recs.RecFeedbackStore,
    adder: NewReleaseLikeAdder,
) {
    if (rows.isEmpty()) return
    item(key = "h-liked") {
        val addable = rows.filter { !it.inFlight }
        val addingAll = adder.busy.collectAsState().value.addingAll
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            Text(
                "Liked — not added",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).testTag("new-liked-section"),
            )
            // One at a time: disabled while anything is in flight (Add all itself too).
            TextButton(
                onClick = {
                    val ids = addable.map { it.id }
                    val writeOnly = addable.filter { it.retryWriteOnly }.map { it.id }.toSet()
                    adder.addAll(ids, writeOnly)
                },
                enabled = !addingAll && addable.isNotEmpty() && addable.size == rows.size,
                modifier = Modifier.testTag("new-liked-add-all"),
            ) { Text("Add all (${addable.size})") }
        }
    }
    items(rows, key = { "liked-${it.id}" }) { row ->
        LikedRowItem(row, now, catalog, feedback, adder)
    }
}

@Composable
private fun LikedRowItem(
    row: LikedRow,
    now: Double,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    feedback: com.levi.pocketdj.data.recs.RecFeedbackStore,
    adder: NewReleaseLikeAdder,
) {
    val context = LocalContext.current
    val rel = row.release
    val status = NewReleasesPresentation.likedStatusLine(row, now)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .weight(1f)
                .clickable { openAlbum(context, rel.storeId) }
                .testTag("new-liked-row-${rel.storeId}"),
        ) {
            ReleaseArt(rel.artworkUrl)
            Column(Modifier.padding(start = 10.dp)) {
                Text(rel.title ?: "—", style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    rel.artistName, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (status != null) {
                    Text(
                        status, style = MaterialTheme.typography.labelSmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (row.state == LikeAddState.FAILED || row.retryWriteOnly) MaterialTheme.colorScheme.error
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag("new-liked-status-${rel.storeId}"),
                    )
                }
            }
        }
        if (row.inFlight) {
            CircularProgressIndicator(Modifier.size(20.dp).padding(horizontal = 2.dp).testTag("new-liked-add-${row.id}"), strokeWidth = 2.dp)
        } else {
            OutlinedButton(
                onClick = { adder.add(row.id, writeOnly = row.retryWriteOnly) },
                modifier = Modifier.testTag("new-liked-add-${row.id}"),
            ) { Text(NewReleasesPresentation.likedActionTitle(row)) }
        }
        // The lit thumbs-up stays as the undo. Un-liking never removes anything from the library.
        RecFeedbackButtons("rel:${rel.storeId}", NewReleasesPresentation.SCOPE, feedback, catalog)
    }
}

private val EMPTY_LIKED_STATE = kotlinx.coroutines.flow.MutableStateFlow(com.levi.pocketdj.data.recs.LikedReleasesStore.State())
private val EMPTY_BUSY = kotlinx.coroutines.flow.MutableStateFlow(NewReleaseLikeAdder.Busy())

@Composable
private fun ReleaseArt(template: String?) {
    val art = NewReleasesPresentation.artworkUrl(template, 96)
    if (art != null) {
        AsyncImage(
            model = art, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.size(44.dp).clip(RoundedCornerShape(4.dp)),
        )
    } else {
        Box(
            Modifier.size(44.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Album, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun ReleaseRow(
    item: ReleaseFeedItem,
    now: Double,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    feedback: com.levi.pocketdj.data.recs.RecFeedbackStore,
    context: android.content.Context,
    adder: NewReleaseLikeAdder?,
    preAdded: Set<String>,
) {
    val e = item.entry
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .weight(1f)
                .clickable { openRelease(context, e) }
                .testTag("new-release-${e.artistId}"),
        ) {
            val art = NewReleasesPresentation.artworkUrl(e.releaseArtworkUrl, 96)
            if (art != null) {
                AsyncImage(
                    model = art, contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(4.dp)),
                )
            } else {
                Box(
                    Modifier.size(44.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Album, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Column(Modifier.padding(start = 10.dp)) {
                Text(e.releaseName ?: "—", style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    e.artistName, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    e.releaseKind?.let {
                        Text(it.replaceFirstChar { c -> c.uppercase() }, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                    }
                    e.releaseAtMs?.let {
                        Text(NewReleasesPresentation.relative(it, now), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (e.explicit == true) {
                        Text(
                            "E", style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.clip(RoundedCornerShape(2.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 3.dp),
                        )
                    }
                }
            }
        }
        if (e.releaseId != null && e.releaseId in preAdded) {
            Text(
                "Pre-added ✓", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary,
                modifier = Modifier.padding(end = 4.dp).testTag("new-release-preadded-${e.releaseId}"),
            )
        }
        // A thumbs-up is verdict AND add: the Discover add's own controller (LIBRARY_ONLY), through the
        // app-scoped adder so leaving the screen mid-add cancels nothing. RecFeedbackButtons only fires onAccept
        // for a thumbs-up that landed ACCEPTED, so an undo never adds. A `relartist:` row (no release id) has
        // nothing to add and stays pure feedback - the one case that does.
        RecFeedbackButtons(
            item.feedbackId, NewReleasesPresentation.SCOPE, feedback, catalog,
            onAccept = if (e.releaseId == null || adder == null) null else ({ adder.liked(e) }),
        )
    }
}

/** A release with no store id can't be opened - the row simply doesn't navigate. */
private fun openRelease(context: android.content.Context, e: ArtistReleaseEntry) {
    openAlbum(context, e.releaseId ?: return)
}

private fun openAlbum(context: android.content.Context, id: String) {
    runCatching {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(NewReleasesPresentation.albumUrl(id))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }.onFailure { Toast.makeText(context, "Couldn’t open this release", Toast.LENGTH_SHORT).show() }
}

@Composable
private fun EmptyState(reason: ReleaseEmptyReason) {
    Column(
        Modifier.fillMaxSize().padding(30.dp).testTag("new-releases-empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(NewReleasesPresentation.emptyIcon(reason), null, modifier = Modifier.size(34.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(NewReleasesPresentation.emptyTitle(reason), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
        Text(
            NewReleasesPresentation.emptyDetail(reason), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
    }
}
