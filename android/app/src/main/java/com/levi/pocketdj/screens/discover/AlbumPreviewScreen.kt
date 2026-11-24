package com.levi.pocketdj.screens.discover

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.applemusic.AmResult
import com.levi.pocketdj.data.applemusic.AppleMusicAlbumRef
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.discover.DiscoverAddState
import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.shazam.AppleMusicRecognition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus
import kotlinx.coroutines.withContext

/** Process-wide holder: the controller is app-scoped so a Download survives the screen closing. */
object AlbumPreviewHolder {
    @Volatile private var instance: AlbumPreviewController? = null

    fun get(graph: AppGraph): AlbumPreviewController =
        instance ?: synchronized(this) { instance ?: build(graph).also { instance = it } }

    private fun build(graph: AppGraph): AlbumPreviewController =
        AlbumPreviewController(graph.appScope + Dispatchers.IO, ProductionAlbumPort(graph), ProductionDownloadPort(graph))
}

private class ProductionAlbumPort(private val graph: AppGraph) : AlbumPreviewPort {
    @Volatile private var storefront: String? = null
    private suspend fun sf(): String {
        storefront?.let { return it }
        return ((graph.appleMusicApi.userStorefront() as? AmResult.Ok)?.value ?: "us").also { storefront = it }
    }

    override suspend fun hasServer() = graph.ripServerClient.isConfigured()
    override suspend fun canAddToLibrary() = graph.settings.current().hasAppleMusic
    override suspend fun isOffline(): Boolean {
        val cm = graph.appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return true
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    override suspend fun catalogTracks(albumStoreId: String): List<DiscoverAlbumTrack> =
        (graph.appleMusicApi.albumTracks(albumStoreId, sf()) as? AmResult.Ok)?.value.orEmpty()

    override suspend fun expansion(albumStoreId: String): DiscoverAlbumExpansion =
        graph.ripServerClient.albumTracks(albumStoreId)

    override suspend fun addAlbum(hit: DiscoverAlbumHit): DiscoverAddOutcome =
        graph.browseGraph.discoverController.addAlbum(hit, AlbumAddIntent.LIBRARY_ONLY)
}

private class ProductionDownloadPort(private val graph: AppGraph) : AlbumDownloadPort {
    private val songByJob = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val burns get() = graph.servicesGraph.burnStore

    override suspend fun configured() = graph.ripServerClient.isConfigured()

    override suspend fun request(track: DownloadTrack): RipJob? {
        if (!configured()) return null
        // Intent first: whichever path sees the rip land finishes the burn.
        burns.burnWhenRipped(track.songId, track.title, track.artist)
        if (graph.ripsRepository.entry(track.songId) != null) return RipJob(phase = RipJob.PHASE_READY, url = "local")
        val job = graph.ripServerClient.requestRip(track.songId, track.title, track.artist, track.storeId, track.lengthMs)
        graph.ripJobTracker.adopt(track.songId, job)
        job.jobId?.let { songByJob[it] = track.songId }
        return job
    }

    override suspend fun fetchJob(jobId: String): RipJob? {
        val job = graph.ripServerClient.job(jobId)
        songByJob[jobId]?.let { graph.ripJobTracker.adopt(it, job) }
        return job
    }

    override suspend fun ripsLanded(songIds: List<String>) {
        runCatching { graph.ripsRepository.refresh() }
        burns.drainPendingAfterRip()
    }

    override fun onDevice(songId: String) = burns.items.value[songId]?.state == BurnState.READY

    override fun burnError(songId: String): String? =
        if (burns.items.value[songId]?.state == BurnState.ERROR) "Couldn’t save to this device" else null
}

/** The three id sets (+ burn-id lookup) for [tracks], scanned off-main. */
internal fun ownedSetsFor(tracks: List<AlbumTrackRow>, catalog: MergedCatalog?, manifestIds: Set<String>): OwnedSets {
    if (tracks.isEmpty()) return OwnedSets()
    val ids = tracks.map { it.storeId }.toSet()
    val adHoc = ids.associateBy { "amrec_$it" }
    val provisional = adHoc.filterKeys { catalog?.songsById?.containsKey(it) == true }.keys
    val appleIds = HashSet<String>()
    val songByStore = HashMap<String, String>()
    if (catalog != null) {
        for (s in catalog.songs) {
            for (a in sequenceOf(s.appleMusicId, s.appleMusicIdExplicit, s.appleMusicIdClean)) {
                if (a != null && a in ids) { appleIds += a; songByStore.putIfAbsent(a, s.id) }
            }
        }
    }
    return OwnedSets(
        catalogSongIds = provisional.toSet(),
        catalogAppleMusicIds = appleIds,
        rippedSongIds = adHoc.keys.filter { it in manifestIds }.toSet(),
        catalogSongIdByStoreId = songByStore,
    )
}

/**
 * The in-app store album page (iOS `AlbumPreviewView`): cover + tracklist, ownership-aware add, Download, "Open album"
 * when the catalog already has it, artist hotlink, retry. Reached from the recognizer, the For You release rows and
 * Discover album taps through [StoreAlbumRouter].
 */
@Composable
fun AlbumPreviewScreen(
    ref: AppleMusicAlbumRef,
    onBack: () -> Unit,
    onOpenArtist: (String) -> Unit,
    onOpenAlbum: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val controller = remember { AlbumPreviewHolder.get(graph) }
    val scope = rememberCoroutineScope()
    var attempt by remember { mutableIntStateOf(0) }

    val load by produceState<AlbumPreviewLoad?>(null, ref.storeId, attempt) {
        value = null
        value = withContext(Dispatchers.IO) { controller.load(ref) }
    }
    val catalog = graph.catalogRepository.state.collectAsState().value.catalog
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val addsSnap by graph.browseGraph.discoverAdds.state.collectAsState()
    val jobs by graph.ripJobTracker.jobs.collectAsState()
    val downloads by controller.downloads.collectAsState()
    val addUis by controller.adds.collectAsState()
    val hasAppleMusic by remember { graph.settings.settings }.collectAsState(initial = null)
    val serverOn by produceState(false) { value = graph.ripServerClient.isConfigured() }
    val canAdd = hasAppleMusic?.hasAppleMusic == true

    val loaded = load
    val tracks = loaded?.tracks.orEmpty()
    val album = loaded?.album ?: ref
    val ownedOrNull by produceState<OwnedSets?>(null, tracks, catalog, manifest.keys) {
        value = withContext(Dispatchers.Default) { ownedSetsFor(tracks, catalog, manifest.keys) }
    }
    // Ownership is unknown until the first computation lands AND the catalog is loaded: no add action before that.
    val ownershipKnown = ownedOrNull != null && catalog != null
    val owned = ownedOrNull ?: OwnedSets()
    val ownership = owned.ownershipOf(tracks)

    val catalogAlbumId = remember(catalog, ref.storeId) {
        catalog?.albums?.firstOrNull { it.appleMusicId == ref.storeId }?.id
            ?: "amrec_album_${ref.storeId}".takeIf { catalog?.albumsById?.containsKey(it) == true }
    }
    val entry = addsSnap.albums.firstOrNull { it.albumId == "amrec_album_${ref.storeId}" }
    val recorded = entry?.let {
        DiscoverAddState.of(
            it,
            readyIds = (it.trackIds ?: emptyList()).filter { id -> manifest.containsKey(id) }.toSet(),
            erroredIds = (it.trackIds ?: emptyList()).filter { id -> jobs[id]?.phase == RipJob.PHASE_ERROR }.toSet(),
        )
    }
    val mode = AlbumPreviewPresentation.addMode(ownership, recorded, catalogAlbumId != null, tracks.isEmpty())
    val addUi = addUis[ref.storeId] ?: AlbumAddUi()
    val dlState = downloads[ref.storeId] ?: AlbumDownloadState.Idle
    var retrying by remember { mutableStateOf(false) }
    var retryNotice by remember { mutableStateOf<String?>(null) }

    fun hit() = DiscoverAlbumHit(
        appleMusicId = ref.storeId, title = album.title, artist = album.artist, artworkUrl = album.artworkUrl,
        trackCount = tracks.size.takeIf { it > 0 }, year = album.year, url = album.url,
    )

    Surface(modifier.fillMaxSize().testTag("album-preview"), color = MaterialTheme.colorScheme.background) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp)) {
            item(key = "header") {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    DiscoverArt(album.artworkUrl, 220, Modifier.testTag("album-preview-art"))
                    Text(album.title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                    if (album.artist.isNotBlank()) {
                        Text(
                            album.artist, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.clickable { onOpenArtist(album.artist) }.testTag("artist-hotlink"),
                        )
                    }
                    val total = tracks.sumOf { (it.durationMs ?: 0).toLong() } / 1000.0
                    val subtitle = listOfNotNull(
                        album.year?.toString(),
                        tracks.takeIf { it.isNotEmpty() }?.let { Fmt.count(it.size, "track") },
                        AlbumPreviewPresentation.runtime(total).ifEmpty { null },
                    ).joinToString(" · ").ifEmpty { "Apple Music" }
                    Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("album-preview-subtitle"))
                }
            }
            item(key = "add") {
                Column(Modifier.fillMaxWidth().padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (mode) {
                        is AlbumAddMode.Add -> Capsule(
                            enabled = !addUi.adding && ownershipKnown,
                            onClick = { controller.addAlbum(hit()) },
                            tag = "album-preview-add",
                        ) {
                            if (addUi.adding) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            else Icon(Icons.Filled.Add, null)
                            Spacer(Modifier.width(8.dp))
                            Text(if (addUi.adding) "Adding…" else mode.title, style = MaterialTheme.typography.titleMedium)
                        }
                        AlbumAddMode.Owned -> Capsule(enabled = false, onClick = {}, tag = "album-preview-add") {
                            Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.width(8.dp))
                            Text("In your library", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                        }
                        is AlbumAddMode.Recorded -> Capsule(enabled = false, onClick = {}, tag = "album-preview-add") {
                            when (val st = mode.state) {
                                is DiscoverAddState.Added -> {
                                    Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary)
                                    Spacer(Modifier.width(8.dp))
                                    Text("In your library", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                                }
                                is DiscoverAddState.Partial -> {
                                    Icon(Icons.Filled.ErrorOutline, null, tint = MaterialTheme.colorScheme.tertiary)
                                    Spacer(Modifier.width(8.dp))
                                    Text("${st.ready} of ${st.total} ready — the rest couldn’t be prepared", style = MaterialTheme.typography.titleSmall)
                                }
                                is DiscoverAddState.Adding -> {
                                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("Adding… ${st.ready}/${st.total}", style = MaterialTheme.typography.titleMedium)
                                }
                            }
                        }
                    }
                    addUi.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("album-preview-error")) }
                    if (catalogAlbumId != null && (mode is AlbumAddMode.Owned || mode is AlbumAddMode.Recorded)) {
                        TextButton(onClick = { onOpenAlbum(catalogAlbumId) }, modifier = Modifier.testTag("album-preview-open")) {
                            Text("Open album"); Icon(Icons.Filled.ChevronRight, null)
                        }
                    }
                    if (entry != null && AlbumLibraryWriteRetry.needsRetry(entry.libraryWrite, canAdd)) {
                        DiscoverRetryRow(
                            retrying, retryNotice, reason = entry.libraryWrite, modifier = Modifier.testTag("album-preview-am-retry"),
                            onRetry = {
                                retrying = true; retryNotice = null
                                scope.launch {
                                    try {
                                        retryNotice = AlbumLibraryWriteRetry.notice(graph.browseGraph.retryAlbumLibraryWrite(hit()))
                                    } finally { retrying = false }
                                }
                            },
                        )
                    }
                    // Download is a SEPARATE intent from adding; gated on the RIP SERVER (preparing a copy is its job).
                    if (serverOn && tracks.isNotEmpty()) {
                        TextButton(
                            enabled = dlState.isTappable,
                            onClick = {
                                controller.download(
                                    ref.storeId,
                                    tracks.map { t ->
                                        DownloadTrack(
                                            songId = AppleMusicRecognition.burnSongId(owned.catalogSongIdByStoreId[t.storeId], t.storeId),
                                            title = t.title, artist = t.artist, storeId = t.storeId, lengthMs = t.durationMs,
                                        )
                                    },
                                )
                            },
                            modifier = Modifier.testTag("album-preview-download"),
                        ) {
                            if (dlState is AlbumDownloadState.Working) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            else Icon(Icons.Filled.Download, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(dlState.label)
                        }
                    }
                }
            }
            when {
                load == null -> item(key = "loading") {
                    Row(Modifier.padding(top = 16.dp).testTag("album-preview-loading"), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Loading tracks…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                tracks.isEmpty() -> item(key = "empty") {
                    val reason = loaded?.unavailable ?: AlbumPreviewUnavailable.NotFound
                    Column(Modifier.fillMaxWidth().padding(top = 24.dp).testTag("album-preview-empty"), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(reason.title, style = MaterialTheme.typography.titleSmall)
                        Text(reason.message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                        TextButton(onClick = { attempt++ }, modifier = Modifier.testTag("album-preview-retry")) { Text("Retry") }
                    }
                }
                else -> itemsIndexed(tracks, key = { i, t -> "${t.storeId}-$i" }) { i, t ->
                    Column(Modifier.testTag("album-preview-track-$i")) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${t.trackNumber ?: (i + 1)}", style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(28.dp),
                            )
                            Column(Modifier.weight(1f)) {
                                Text(t.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(t.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            t.durationMs?.let { Text(Fmt.duration(it.toLong()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            if (owned.owns(t.storeId)) {
                                Icon(
                                    Icons.Filled.CheckCircle, "In your library", Modifier.padding(start = 8.dp).size(16.dp),
                                    tint = MaterialTheme.colorScheme.primary,
                                )
                            }
                        }
                        if (i < tracks.size - 1) HorizontalDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun Capsule(enabled: Boolean, onClick: () -> Unit, tag: String, content: @Composable () -> Unit) {
    Surface(
        shape = CircleShape, color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth().testTag(tag).let { if (enabled) it.clickable(onClick = onClick) else it },
    ) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 14.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            content()
        }
    }
}
