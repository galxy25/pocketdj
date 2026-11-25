package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
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
import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.share.ShareText
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.ui.FavoriteToggle
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import androidx.compose.material3.TextButton
import com.levi.pocketdj.screens.collections.AddToPlaylistMenu
import com.levi.pocketdj.screens.nowplaying.QueueAdd
import com.levi.pocketdj.screens.playlists.CollectionBurnDialogs
import com.levi.pocketdj.screens.playlists.rememberCollectionBurnController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Album detail (specs/browse.md §8): header (cover 168dp, name, artist, tags,
 * source, track count) + track table. Track order comes from `trackList`; ids
 * missing from the catalog are silently dropped. Tap a row → song detail sheet;
 * tap ▶ → [com.levi.pocketdj.playback.PlaybackController.play] (album-context
 * queue). Playable vs metadata-only rows are visually distinct.
 *
 * The integrator navigates here with the album id.
 */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun AlbumDetailScreen(
    albumId: String,
    modifier: Modifier = Modifier,
    /** Opens a setlist in Now Playing (shell nav); null disables Shuffle (no destination). */
    onOpenSetlist: ((setlistId: String, autoplay: Boolean) -> Unit)? = null,
    /** Direct push to the artist page; the album stays underneath for Back. Null renders the artist as plain text. */
    onOpenArtist: ((artistName: String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    var detailSongId by remember { mutableStateOf<String?>(null) }
    var showAddSheet by remember { mutableStateOf(false) }
    var showEditAlbum by remember { mutableStateOf(false) }
    var showEditAudio by remember { mutableStateOf(false) }
    var trackMenuSongId by remember { mutableStateOf<String?>(null) }
    var trackAddSheet by remember { mutableStateOf(false) }
    val stemController = rememberCollectionBurnController(albumId)
    val stemState by stemController.state.collectAsState()
    val discoverSnap by graph.browseGraph.discoverAdds.state.collectAsState()
    var retryingLibraryWrite by remember { mutableStateOf(false) }

    // Resolve the latest album by id from the catalog on every render (§8).
    val catalog = catalogState.catalog
    val album = catalog?.albumsById?.get(albumId)

    Box(modifier = modifier.fillMaxSize()) {
        when {
            catalog == null -> {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            }

            album == null -> {
                Text(
                    "Album not found",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            else -> {
                val tracks = catalog.tracks(album)
                val hasServer = settings?.hasRipServer == true
                val anyPlayable = tracks.any {
                    playability(it.id, manifest, hasServer, it.appleMusicId, graph.studioGraph.profileAudio.hasLocalAsset(it.id)) != Playability.NONE
                }

                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    item(key = "header") {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                        ) {
                            AlbumArt(album, modifier = Modifier.size(168.dp), cornerRadius = 10)
                            Spacer(Modifier.height(12.dp))
                            Text(
                                album.name,
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                album.artist,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .let { m -> if (onOpenArtist != null) m.clickable { onOpenArtist(album.artist) } else m }
                                    .testTag("artist-hotlink"),
                            )
                            Spacer(Modifier.height(6.dp))
                            MetaTag(
                                listOfNotNull(
                                    Genre.category(album.genre),
                                    album.year?.toString(),
                                    album.country,
                                    catalog.sourceOfAlbum[album.id],
                                ).joinToString(" · "),
                            )
                            val discoverEntry = discoverSnap.albums.firstOrNull { it.albumId == album.id }
                            val canAddToLibrary = settings?.hasAppleMusic == true
                            when (AlbumLibraryState.of(discoverEntry, canAddToLibrary)) {
                                AlbumLibraryState.Kind.RETRY -> {
                                    val entry = discoverEntry!!
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        if (!entry.libraryWrite.isNullOrBlank()) {
                                            Text(
                                                entry.libraryWrite.orEmpty(),
                                                style = MaterialTheme.typography.labelSmall,
                                                color = MaterialTheme.colorScheme.error,
                                                modifier = Modifier.testTag("album-am-note"),
                                            )
                                        }
                                        TextButton(
                                            onClick = {
                                                retryingLibraryWrite = true
                                                // appScope, not the composable scope: leaving the page mid-write must not drop it (iOS: unstructured Task).
                                                graph.appScope.launch {
                                                    try {
                                                        withContext(Dispatchers.IO) {
                                                            graph.browseGraph.discoverController
                                                                .retryAlbumLibraryWrite(entry.albumId, entry.appleMusicId)
                                                        }
                                                    } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                                                        throw e
                                                    } catch (_: Exception) {
                                                    } finally {
                                                        retryingLibraryWrite = false
                                                    }
                                                }
                                            },
                                            enabled = !retryingLibraryWrite,
                                            modifier = Modifier.testTag("album-am-retry"),
                                        ) {
                                            Text(
                                                if (retryingLibraryWrite) {
                                                    com.levi.pocketdj.screens.discover.AlbumLibraryWriteRetry.BUSY_LABEL
                                                } else {
                                                    com.levi.pocketdj.screens.discover.AlbumLibraryWriteRetry.LABEL
                                                },
                                            )
                                        }
                                    }
                                }

                                AlbumLibraryState.Kind.CONFIRMED -> Text(
                                    "In your Apple Music library",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.tertiary,
                                    modifier = Modifier.testTag("album-am-confirmed"),
                                )

                                AlbumLibraryState.Kind.NONE -> Unit
                            }
                            // Whole-album queueing sits beside the track count (iOS), always present.
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    Fmt.count(tracks.size, "track"),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                AlbumQueueMenuButton(
                                    songs = tracks,
                                    onAdd = { items, next ->
                                        graph.appScope.launch { QueueAdd.add(graph, items, next) }
                                    },
                                    onAddToPlaylist = { showAddSheet = true },
                                )
                            }
                            Spacer(Modifier.height(12.dp))
                            androidx.compose.foundation.layout.FlowRow(
                                verticalArrangement = Arrangement.spacedBy(4.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                            ) {
                                if (anyPlayable) {
                                    Button(
                                        onClick = {
                                            // Same path as Shuffle (iOS play(shuffle: false)): the album in track order through the
                                            // sequencer, so an in-order vinyl side plays as ONE engine item (album run).
                                            val set = graph.collections.playNow(
                                                songIds = tracks.map { it.id },
                                                name = album.name,
                                                shuffle = false,
                                                sourceToken = PlayContext.SOURCE_ALBUM,
                                                originId = album.id,
                                            )
                                            if (set != null) {
                                                onOpenSetlist?.invoke(NOW_PLAYING_SETLIST_ID, true)
                                            } else {
                                                scope.launch { snackbar.showSnackbar("Catalog isn't ready yet") }
                                            }
                                        },
                                        modifier = Modifier.testTag("album-play"),
                                    ) {
                                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                                        Spacer(Modifier.width(6.dp))
                                        Text("Play")
                                    }
                                }
                                if (onOpenSetlist != null && tracks.isNotEmpty() && anyPlayable) {
                                    OutlinedButton(
                                        onClick = {
                                            // Literal ids shuffled into the reserved Now Playing setlist,
                                            // attributed source=album / contextName=album name (History).
                                            val set = graph.collections.playNow(
                                                songIds = tracks.map { it.id },
                                                name = album.name,
                                                shuffle = true,
                                                sourceToken = PlayContext.SOURCE_ALBUM,
                                                originId = album.id,
                                            )
                                            if (set != null) {
                                                onOpenSetlist(NOW_PLAYING_SETLIST_ID, true)
                                            } else {
                                                scope.launch { snackbar.showSnackbar("Catalog isn't ready yet") }
                                            }
                                        },
                                        modifier = Modifier.testTag("album-shuffle"),
                                    ) {
                                        Icon(Icons.Filled.Shuffle, contentDescription = null, modifier = Modifier.size(18.dp))
                                        Spacer(Modifier.width(6.dp))
                                        Text("Shuffle")
                                    }
                                }
                                // Add-to-Collection launch point (specs/playlists-ui.md §8.1).
                                FilledTonalIconButton(
                                    onClick = { showAddSheet = true },
                                    modifier = Modifier.testTag("album-add-to-collection"),
                                ) {
                                    Icon(
                                        Icons.Filled.AddCircleOutline,
                                        contentDescription = "Add album to collection",
                                    )
                                }
                                // Album-level Stemify (progress pill + over-cap confirm via the shared controller); per-track
                                // Stemify stays on each row's transport. Needs a rip server.
                                OutlinedButton(
                                    onClick = { stemController.stemify(tracks.map { it.id }) },
                                    enabled = hasServer && tracks.isNotEmpty() && !stemState.working,
                                    modifier = Modifier.testTag("album-stemify"),
                                ) { Text("Stemify") }
                                OutlinedButton(
                                    onClick = { showEditAlbum = true },
                                    modifier = Modifier.testTag("edit-album"),
                                ) { Text("Edit") }
                                FilledTonalIconButton(
                                    onClick = { ShareText.send(context, ShareText.forAlbum(album), "${album.name} — ${album.artist}") },
                                    modifier = Modifier.testTag("album-share"),
                                ) {
                                    Icon(Icons.Filled.Share, contentDescription = "Share album")
                                }
                            }
                            (stemState.stemProgress)?.let {
                                Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        HorizontalDivider()
                    }

                    run {
                        item(key = "waveform") {
                            AlbumWaveformEditor(
                                album = album,
                                songsById = catalog.songsById,
                                manifest = manifest,
                                playFrom = { index, _ ->
                                    // Start the album at track `index` through the sequencer (like Play); the one-shot
                                    // cueNextStart armed by the editor makes the first song begin mid-track.
                                    val set = graph.collections.playNow(
                                        songIds = tracks.map { it.id },
                                        name = album.name,
                                        shuffle = false,
                                        sourceToken = PlayContext.SOURCE_ALBUM,
                                        originId = album.id,
                                    )
                                    if (set != null) {
                                        // Whole album queued (previous-track / setlist match iOS), started at `index`.
                                        val want = tracks.getOrNull(index)?.id
                                        val entry = set.tracks.indexOfFirst { it.songId == want }.coerceAtLeast(0)
                                        scope.launch { graph.playbackController.playSetlist(set, startEntryIndex = entry) }
                                        onOpenSetlist?.invoke(NOW_PLAYING_SETLIST_ID, false)
                                    } else {
                                        scope.launch { snackbar.showSnackbar("Catalog isn't ready yet") }
                                    }
                                },
                            )
                        }
                    }

                    itemsIndexed(tracks, key = { _, song -> song.id }) { index, song ->
                      Column {
                        AlbumTrackRow(
                            position = index + 1,
                            song = song,
                            playable = playability(song.id, manifest, hasServer, song.appleMusicId, graph.studioGraph.profileAudio.hasLocalAsset(song.id)),
                            isPreparing = preparingId == song.id,
                            zebra = index % 2 == 1,
                            onClick = { detailSongId = song.id },
                            onLongClick = { trackMenuSongId = song.id },
                            onPlay = {
                                scope.launch {
                                    playAndReport(graph.playbackController, song.id, snackbar)
                                }
                            },
                        )
                        InlinePlayerSlot(song, album)
                      }
                    }

                    if (!album.audioTracks.isNullOrEmpty()) {
                        item(key = "audio-analysis") { AudioAnalysisSection(album, onEdit = { showEditAudio = true }) }
                    }
                }
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    detailSongId?.let { songId ->
        SongDetailSheet(
            songId = songId,
            onDismiss = { detailSongId = null },
            snackbar = snackbar,
        )
    }

    CollectionBurnDialogs(stemController, noun = "album")

    // Track long-press: Play next / Play last above the Add-to-Playlist targets (iOS contextMenu).
    trackMenuSongId?.let { songId ->
        val song = catalogState.catalog?.songsById?.get(songId)
        if (trackAddSheet) {
            AddToCollectionSheet(
                item = AddToItem.Song(songId),
                searchFirst = true,
                onDismiss = { trackMenuSongId = null; trackAddSheet = false },
            )
        } else if (song != null) {
            AddToPlaylistMenu(
                item = AddToItem.Song(songId),
                onDismiss = { trackMenuSongId = null },
                onMore = { trackAddSheet = true },
                header = com.levi.pocketdj.screens.collections.ContextHeader(
                    song.name, song.artist, catalogState.catalog?.albumsById?.get(albumId),
                ),
                leadingActions = AlbumQueueMenu.trackActions(song) { items, next ->
                    graph.appScope.launch { QueueAdd.add(graph, items, next) }
                },
            )
        } else {
            trackMenuSongId = null
        }
    }

    if (showEditAlbum) {
        catalogState.catalog?.albumsById?.get(albumId)?.let { EditAlbumSheet(it, onDismiss = { showEditAlbum = false }) }
    }
    if (showEditAudio) {
        catalogState.catalog?.albumsById?.get(albumId)?.let { EditAudioAnalysisSheet(it, onDismiss = { showEditAudio = false }) }
    }

    if (showAddSheet) {
        AddToCollectionSheet(
            item = AddToItem.Album(albumId),
            onDismiss = { showAddSheet = false },
        )
    }
}

/** What the album header shows about the Apple Music library write of a provisional (amrec_album_) album. */
internal object AlbumLibraryState {
    enum class Kind { NONE, RETRY, CONFIRMED }

    /** [entry] = the Discover entry backing this album (null = not a provisional album). */
    fun of(entry: com.levi.pocketdj.data.discover.DiscoverAddsStore.AlbumEntry?, canAddToLibrary: Boolean): Kind = when {
        entry == null -> Kind.NONE
        com.levi.pocketdj.screens.discover.AlbumLibraryWriteRetry.needsRetry(entry.libraryWrite, canAddToLibrary) -> Kind.RETRY
        com.levi.pocketdj.data.discover.DiscoverAddsStore.provenByToken(entry.libraryWrite) -> Kind.CONFIRMED
        else -> Kind.NONE
    }
}

/** Pure formatting for the audio-analysis rows (iOS `AudioSegmentRow`). */
internal object AudioAnalysisFmt {
    /** Row index: the segment's own track number, else its 1-based position. */
    fun index(seg: AudioTrack, position: Int): Int = seg.trackNumber ?: position

    fun range(seg: AudioTrack): String = "${Fmt.duration(seg.startMs)} – ${Fmt.duration(seg.endMs)}"

    /** keyStrength 0..1 as a truncated whole percent, or an en dash. */
    fun strength(seg: AudioTrack): String = seg.keyStrength?.let { "${(it * 100).toInt()}%" } ?: "–"

    /** "m:ss total" from the album's audioDurationSec (truncated), or null when absent. */
    fun total(durationSec: Double?): String? = durationSec?.let {
        val s = it.toInt()
        "%d:%02d total".format(s / 60, s % 60)
    }
}

@Composable
private fun AudioAnalysisSection(album: IndexAlbum, onEdit: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp).testTag("album-audio-analysis")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Audio analysis",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            AudioAnalysisFmt.total(album.audioDurationSec)?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onEdit, modifier = Modifier.testTag("edit-audio")) { Text("Edit") }
        }
        Spacer(Modifier.height(6.dp))
        album.audioTracks.orEmpty().forEachIndexed { i, seg ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .let { if (i % 2 == 1) it.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)) else it }
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            ) {
                Text(
                    AudioAnalysisFmt.index(seg, i + 1).toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(26.dp),
                )
                Text(
                    AudioAnalysisFmt.range(seg),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(Fmt.bpm(seg.bpm), style = MaterialTheme.typography.labelMedium, modifier = Modifier.width(36.dp))
                Box(Modifier.width(84.dp)) { KeyChip(seg.key?.takeIf { seg.camelot == null }, seg.camelot) }
                Text(
                    AudioAnalysisFmt.strength(seg),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(40.dp),
                )
            }
        }
    }
}
