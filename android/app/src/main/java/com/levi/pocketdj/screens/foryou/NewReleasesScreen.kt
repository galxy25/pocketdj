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
import androidx.compose.material.icons.filled.Check
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
import androidx.compose.material3.HorizontalDivider
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

    // ---- albums / singles filter copy (iOS `NewReleasesView.kindEmptyDetail` etc.) ----

    /** The filter emptied the screen: "No new albums" / "No new singles". */
    fun kindEmptyTitle(mode: NewReleaseKindFilter): String = "No new ${NewReleaseKinds.shownNoun(mode)}"

    fun kindEmptyDetail(mode: NewReleaseKindFilter, hiddenNote: String?): String {
        val setting = "Your New filter is set to ${mode.label}."
        return if (hiddenNote == null) setting else "${hiddenNote.replaceFirstChar { it.uppercase() }}. $setting"
    }

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
    // Per section: offered -> arrange (the albums/singles choice, rejected sinking INSIDE each group) -> render.
    // The filter comes AFTER `offered`, so a thumbed-up release still leaves Out now and moves to Liked.
    val mode by remember { graph.settings.settings.map { NewReleaseKindFilter.from(it.newReleaseKind) } }
        .collectAsState(remember { NewReleaseKindFilter.initial(graph.settings.settings) })
    val offeredOut = remember(rev, fbState.revision, preAdded) {
        NewReleasesPresentation.offered(service.outNow(now), accepted, preAdded)
    }
    val offeredSoon = remember(rev, fbState.revision, preAdded) {
        NewReleasesPresentation.offered(service.comingSoon(now), accepted, preAdded)
    }
    val outNowA = remember(offeredOut, mode, tombstones) {
        NewReleaseKinds.arrange(offeredOut, mode, { it.entry.kindClass }, { NewReleasesPresentation.sunkLast(it, tombstones) })
    }
    val soonA = remember(offeredSoon, mode, tombstones) {
        NewReleaseKinds.arrange(offeredSoon, mode, { it.entry.kindClass }, { NewReleasesPresentation.sunkLast(it, tombstones) })
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
    val likedA = remember(liked, mode) { NewReleaseKinds.arrange(liked.rows, mode, { it.release.kindClass }) }
    // Hidden counts cover every section (Liked included) and count rows that WOULD render under Everything.
    val hiddenAlbums = outNowA.hiddenAlbums + soonA.hiddenAlbums + likedA.hiddenAlbums
    val hiddenEPs = outNowA.hiddenEPs + soonA.hiddenEPs + likedA.hiddenEPs
    val hiddenSingles = outNowA.hiddenSingles + soonA.hiddenSingles + likedA.hiddenSingles
    val hiddenNote = NewReleaseKinds.hiddenNote(hiddenAlbums, hiddenEPs, hiddenSingles)
    // Rebuild metadata for likes this install has never seen (older likes, another device's), then retry what
    // was waiting on a connection or a release day. Off the render path.
    // On the ADDER's scope: this screen's own scope is cancelled on back, which would abort a half-done add.
    LaunchedEffect(adder) {
        adder?.maintain(feedback.acceptedInScope(NewReleasesPresentation.SCOPE))
    }
    // The LIVE half, computed ONCE and used by both the rows and the transport's enabled state. It reads the
    // ARRANGED list, so play queues albums then singles and shuffle shuffles all of it (the 25-release cap
    // applies after this ordering, so singles are what get cut).
    val liveOutNow = remember(offeredOut, mode, tombstones) { NewReleaseKinds.liveOutNow(offeredOut, mode, tombstones) }
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
                    HorizontalDivider()
                    // Show: albums vs singles. A disabled caption heads the group (`…-kind-menu`), a check marks
                    // the current choice, and the footnote says where EPs go.
                    DropdownMenuItem(
                        text = { Text("Show", style = MaterialTheme.typography.labelMedium) },
                        enabled = false, onClick = {},
                        modifier = Modifier.testTag("foryou-new-kind-menu"),
                    )
                    for (m in NewReleaseKindFilter.entries) {
                        DropdownMenuItem(
                            text = { Text(m.label) },
                            trailingIcon = { if (m == mode) Icon(Icons.Filled.Check, contentDescription = "Selected") },
                            onClick = { menu = false; scope.launch { graph.settings.setNewReleaseKind(m.raw) } },
                            modifier = Modifier.testTag("foryou-new-kind-${m.raw}"),
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("EPs count as albums", style = MaterialTheme.typography.labelSmall) },
                        enabled = false, onClick = {},
                    )
                }
            }
        }

        // Three different empties: nothing at all (the reason-based state; the filter is not the cause),
        // everything hidden by the filter (says so, offers Show all), or a partial hide (a footer under the
        // rows). A liked-but-not-added record is something.
        if (offeredOut.isEmpty() && offeredSoon.isEmpty() && liked.rows.isEmpty()) {
            EmptyState(service.emptyReason())
        } else if (outNowA.flat.isEmpty() && soonA.flat.isEmpty() && likedA.flat.isEmpty()) {
            KindEmptyState(mode, hiddenNote) { scope.launch { graph.settings.setNewReleaseKind(NewReleaseKindFilter.ALL.raw) } }
        } else {
            LazyColumn(Modifier.fillMaxSize().testTag("foryou-new-list")) {
                if (adder != null) likedSection(likedA.flat, now, catalog, feedback, adder)
                section(ReleaseStatus.OUT_NOW, outNowA, now, catalog, feedback, context, adder, preAdded)
                section(ReleaseStatus.COMING_SOON, soonA, now, catalog, feedback, context, adder, preAdded)
                if (hiddenNote != null) {
                    item(key = "kind-hidden-footer") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    hiddenNote, style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.testTag("new-kind-hidden-footer"),
                                )
                            }
                            TextButton(
                                onClick = { scope.launch { graph.settings.setNewReleaseKind(NewReleaseKindFilter.ALL.raw) } },
                                modifier = Modifier.testTag("new-kind-show-all"),
                            ) { Text("Show all") }
                        }
                    }
                }
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
    arranged: NewReleaseKinds.Arranged<ReleaseFeedItem>,
    now: Double,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    feedback: com.levi.pocketdj.data.recs.RecFeedbackStore,
    context: android.content.Context,
    adder: NewReleaseLikeAdder?,
    preAdded: Set<String>,
) {
    if (arranged.flat.isEmpty()) return
    item(key = "h-${status.raw}") {
        Text(
            status.title,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).testTag("new-release-section-${status.raw}"),
        )
    }
    // Albums/Singles sub-headers only when BOTH groups exist - a lone "Albums" over the whole section is noise.
    if (arranged.grouped && arranged.albums.isNotEmpty() && arranged.singles.isNotEmpty()) {
        item(key = "g-albums-${status.raw}") { GroupHeader("Albums", "new-release-group-albums-${status.raw}") }
        items(arranged.albums, key = { "${status.raw}-${it.feedbackId}" }) { item ->
            ReleaseRow(item, now, catalog, feedback, context, adder, preAdded)
        }
        item(key = "g-singles-${status.raw}") { GroupHeader("Singles", "new-release-group-singles-${status.raw}") }
        items(arranged.singles, key = { "${status.raw}-${it.feedbackId}" }) { item ->
            ReleaseRow(item, now, catalog, feedback, context, adder, preAdded)
        }
    } else {
        items(arranged.flat, key = { "${status.raw}-${it.feedbackId}" }) { item ->
            ReleaseRow(item, now, catalog, feedback, context, adder, preAdded)
        }
    }
}

@Composable
private fun GroupHeader(title: String, tag: String) {
    Text(
        title.uppercase(), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).testTag(tag),
    )
}

/** The filter emptied the screen and the unfiltered list has rows - "Nothing new" would be a false claim. */
@Composable
private fun KindEmptyState(mode: NewReleaseKindFilter, hiddenNote: String?, onShowAll: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(30.dp).testTag("new-kind-empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(NewReleasesPresentation.kindEmptyTitle(mode), style = MaterialTheme.typography.titleSmall)
        Text(
            NewReleasesPresentation.kindEmptyDetail(mode, hiddenNote), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
        OutlinedButton(onClick = onShowAll, modifier = Modifier.padding(top = 12.dp).testTag("new-kind-show-all")) { Text("Show all") }
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
                .clickable { openAlbum(context, rel.storeId, rel.title, rel.artistName, rel.artworkUrl) }
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
                .testTag("new-release-${e.releaseId ?: "artist-${e.artistId}"}"),
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
                    // The CLASSIFIED kind, not Apple's raw `releaseKind` (a 2-track "album" under Singles only).
                    val cls = e.kindClass
                    Text(
                        NewReleaseKinds.badge(e.releaseKind, cls), style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("new-release-kind-${e.releaseId ?: "artist-${e.artistId}"}"),
                    )
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

/** A release with no store id can't be opened - the row simply doesn't navigate. Otherwise: the in-app store album page. */
private fun openRelease(context: android.content.Context, e: ArtistReleaseEntry) {
    val id = e.releaseId ?: return
    openAlbum(context, id, e.releaseName, e.artistName, e.releaseArtworkUrl)
}

/** The in-app store album page; the Apple Music link only if the router can't take it. */
private fun openAlbum(context: android.content.Context, id: String, title: String?, artist: String, artworkUrl: String?) {
    val ref = com.levi.pocketdj.data.applemusic.AppleMusicAlbumRef(
        storeId = id, title = title.orEmpty(), artist = artist,
        year = null, artworkUrl = NewReleasesPresentation.artworkUrl(artworkUrl, 300),
        url = NewReleasesPresentation.albumUrl(id),
    )
    if (com.levi.pocketdj.screens.discover.StoreAlbumRouter.open(ref)) return
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
