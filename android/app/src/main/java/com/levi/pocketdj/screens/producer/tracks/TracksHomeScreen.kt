package com.levi.pocketdj.screens.producer.tracks

import android.content.Context
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.ViewTimeline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.studio.engine.ArrangerClipBaker
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.store.ArrangerMath
import com.levi.pocketdj.studio.store.ArtifactSampleConverter
import com.levi.pocketdj.studio.store.StudioFolderKind
import com.levi.pocketdj.studio.store.arrangementFoldersOrdered
import com.levi.pocketdj.studio.store.artifact
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Shared nav state: an open arrangement hides the Producer sub-tab row (iOS `arrangerFullscreen`). */
object TracksNav {
    var arrangerFullscreen by mutableStateOf(false)
}

/** Tiny per-viewer UI prefs (folder collapse, transport collapse); SharedPreferences, failure-tolerant. */
class TracksPrefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("pocketdj-tracks-ui", Context.MODE_PRIVATE)
    fun collapsedFolders(): Set<String> = runCatching { sp.getStringSet(KEY_COLLAPSED, emptySet())!!.toSet() }.getOrDefault(emptySet())
    fun setCollapsedFolders(s: Set<String>) { runCatching { sp.edit().putStringSet(KEY_COLLAPSED, s).apply() } }
    var transportCollapsed: Boolean
        get() = runCatching { sp.getBoolean(KEY_TRANSPORT, false) }.getOrDefault(false)
        set(v) { runCatching { sp.edit().putBoolean(KEY_TRANSPORT, v).apply() } }
    private companion object { const val KEY_COLLAPSED = "arrangementFolders.collapsed"; const val KEY_TRANSPORT = "tracks.transportCollapsed" }
}

/** The arranger's side effects: baking clips, artifact conversion, audition parking. Busy state drives an overlay. */
class TracksActions(
    private val graph: AppGraph,
    private val ctx: Context,
    private val scope: CoroutineScope,
    /** Wired by the stems package (STU-14/15); null until then, which hides the picker's Stems section. */
    val stemSource: TracksStemSource? = null,
) {
    private val studio get() = graph.studioGraph
    val store get() = studio.studioStore
    var busy by mutableStateOf<String?>(null)
        private set

    private val baker by lazy {
        ArrangerClipBaker(
            studio.studioRoots, studio.studioRender,
            prepare = { id -> studio.studioPlayback.prepare(id) },
            materialize = { ref -> ref.file ?: withContext(Dispatchers.IO) { copyUriToCache(ref.uri) } },
            release = { ref, f -> if (ref.file == null) f.delete() },
        )
    }
    private val converter by lazy { ArtifactSampleConverter(studio.studioRoots, store, studio.studioRender) }

    private fun copyUriToCache(uri: String): File? = runCatching {
        val tmp = File.createTempFile("clip-src-", ".audio", ctx.cacheDir)
        ctx.contentResolver.openInputStream(Uri.parse(uri))?.use { i -> tmp.outputStream().use { i.copyTo(it) } } ?: return null
        tmp
    }.getOrNull()

    /** Park Now Playing before an artifact audition (one audible owner). */
    fun parkNowPlaying() { scope.launch { runCatching { graph.playbackController.pause() } } }

    private fun busyTask(message: String, block: suspend () -> Unit) {
        busy = message
        scope.launch {
            try { block() } catch (e: CancellationException) { throw e } catch (_: Exception) {
                Toast.makeText(ctx, "That didn’t work.", Toast.LENGTH_SHORT).show()
            } finally { busy = null }
        }
    }

    fun addClip(arrangementId: String, trackId: String, pick: ClipPick) {
        when (pick) {
            is ClipPick.Source -> busyTask("Adding clip…") {
                val start = ArrangerMath.appendStartMs(store.arrangement(arrangementId)?.tracks?.firstOrNull { it.id == trackId })
                val clip = baker.bake(pick.id, pick.kind, start)
                if (clip != null) store.addClip(arrangementId, trackId, clip)
                else Toast.makeText(ctx, "Couldn’t add that source (is it rendered?).", Toast.LENGTH_SHORT).show()
            }
            is ClipPick.Artifact -> busyTask("Adding clip…") {
                val art = store.artifact(pick.id) ?: return@busyTask
                val file = store.artifactFile(art.fileName) ?: return@busyTask
                val start = ArrangerMath.appendStartMs(store.arrangement(arrangementId)?.tracks?.firstOrNull { it.id == trackId })
                baker.bakeFromFile(file, art.name, start)?.let { store.addClip(arrangementId, trackId, it) }
            }
            is ClipPick.Stems -> importStems(arrangementId, pick.songId)
        }
    }

    fun addArtifactAsTrack(arrangementId: String, art: StudioArrangementArtifact) = busyTask("Adding track…") {
        val file = store.artifactFile(art.fileName) ?: return@busyTask
        val clip = baker.bakeFromFile(file, art.name, 0) ?: return@busyTask
        val track = store.addTrack(arrangementId, art.name) ?: kotlin.run { File(studio.studioRoots.arrangementsDir(), clip.fileName).delete(); return@busyTask }
        store.addClip(arrangementId, track.id, clip)
    }

    fun convertArtifactToSample(art: StudioArrangementArtifact) = busyTask("Making sample…") {
        val s = converter.createSampleFromArtifact(art)
        Toast.makeText(ctx, if (s != null) "Sample “${s.name}” created." else "Couldn’t make a sample from that.", Toast.LENGTH_SHORT).show()
    }

    /** Drums, bass, other, vocals as four new tracks aligned at 0:00 (palette maps yellow/red/green/purple). */
    private fun importStems(arrangementId: String, songId: String) = busyTask("Importing stems…") {
        val src = stemSource ?: return@busyTask
        val files = src.stemFiles(songId) ?: kotlin.run { Toast.makeText(ctx, "That song’s stems aren’t on this device.", Toast.LENGTH_SHORT).show(); return@busyTask }
        val songName = src.songs().firstOrNull { it.id == songId }?.name ?: "Stems"
        for (stem in ClipPickerModel.STEM_ORDER) {
            val f = files[stem] ?: continue
            val track = store.addTrack(arrangementId, stem.replaceFirstChar { it.uppercase() }) ?: continue
            baker.bakeFromFile(f, "$songName — $stem", 0, StudioClipSource.STEM)?.let { store.addClip(arrangementId, track.id, it) }
        }
    }

    fun deleteArtifact(id: String) = store.deleteArrangementArtifact(id)
}

/** The Tracks tab: lands on a home browser of arrangements + folders; opening one goes fullscreen. */
@Composable
fun TracksHomeScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val store = graph.studioGraph.studioStore
    val doc by produceState(store.state.value, store) { store.state.collect { value = it } }
    val actions = remember { TracksActions(graph, ctx, scope) }
    val audition = rememberArtifactAudition { actions.parkNowPlaying() }
    val prefs = remember { TracksPrefs(ctx) }
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    // The open arrangement vanished (deleted elsewhere): fall back home.
    val current = openId?.let { id -> doc.arrangements.firstOrNull { it.id == id } }
    LaunchedEffect(current == null, openId) { if (openId != null && current == null) openId = null }
    TracksNav.arrangerFullscreen = current != null
    DisposableEffect(Unit) { onDispose { TracksNav.arrangerFullscreen = false } }

    Box(modifier.fillMaxSize().testTag("tracks-screen")) {
        if (current != null) {
            ArrangementScreen(graph, actions, current.id, onBack = { openId = null })
        } else {
            TracksHome(store, actions, audition, prefs, onOpen = { openId = it })
        }
        actions.busy?.let { msg ->
            AlertDialog(onDismissRequest = {}, confirmButton = {}, text = {
                Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.padding(end = 16.dp)); Text(msg) }
            }, modifier = Modifier.testTag("tracks-busy"))
        }
    }
}

@Composable
private fun TracksHome(
    store: com.levi.pocketdj.studio.store.StudioStore,
    actions: TracksActions,
    audition: ArtifactAuditionPlayer,
    prefs: TracksPrefs,
    onOpen: (String) -> Unit,
) {
    val doc by produceState(store.state.value, store) { store.state.collect { value = it } }
    var collapsed by remember { mutableStateOf(prefs.collapsedFolders()) }
    val expandedGroups = remember { mutableStateListOf<String>() }
    var newFolder by remember { mutableStateOf(false) }
    var moveNewFolderFor by remember { mutableStateOf<String?>(null) }
    var renameArr by remember { mutableStateOf<StudioArrangement?>(null) }
    var deleteArr by remember { mutableStateOf<StudioArrangement?>(null) }
    var renameFolder by remember { mutableStateOf<String?>(null) }
    var deleteFolder by remember { mutableStateOf<String?>(null) }

    fun newArrangement() { onOpen(store.createArrangement("Arrangement ${store.arrangements.size + 1}").id) }
    val folders = remember(doc) { store.arrangementFoldersOrdered() }
    val loose = remember(doc) { store.arrangements(null) }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.ViewTimeline, null, tint = MaterialTheme.colorScheme.primary)
            Text("Multitrack", Modifier.weight(1f).padding(start = 12.dp), style = MaterialTheme.typography.titleMedium)
            IconButton(onClick = { newFolder = true }, modifier = Modifier.testTag("tracks-new-folder")) { Icon(Icons.Filled.CreateNewFolder, "New folder") }
            Button(onClick = { newArrangement() }, modifier = Modifier.testTag("tracks-new-arrangement")) { Icon(Icons.Filled.Add, null); Text("New") }
        }
        HorizontalDivider()
        if (doc.arrangements.isEmpty() && doc.arrangementFolders.isEmpty()) {
            Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.ViewTimeline, null, Modifier.padding(bottom = 12.dp), tint = MaterialTheme.colorScheme.primary)
                Text("Make a multitrack", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Arrange samples, sequences, loops, instrumentals — or a song's stems — into layered tracks. Create one to begin; group them into folders as your set grows.",
                    Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Button(onClick = { newArrangement() }, modifier = Modifier.testTag("tracks-empty-new-arrangement")) { Text("New arrangement") }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                item(key = "loose-h") {
                    Text(
                        if (folders.isEmpty()) "Arrangements" else "No folder", Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (loose.isEmpty()) item(key = "loose-empty") {
                    Text("No loose arrangements.", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                items(loose, key = { "a-${it.id}" }) { a ->
                    ArrangementBlock(a, folders, store, actions, audition, expandedGroups, onOpen,
                        onRename = { renameArr = a }, onDelete = { deleteArr = a }, onNewFolder = { moveNewFolderFor = a.id })
                }
                for (f in folders) {
                    val members = store.arrangements(f.id)
                    val isOpen = f.id !in collapsed
                    item(key = "f-${f.id}") {
                        var menu by remember { mutableStateOf(false) }
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                collapsed = if (isOpen) collapsed + f.id else collapsed - f.id
                                prefs.setCollapsedFolders(collapsed)
                            }.padding(horizontal = 16.dp, vertical = 10.dp).testTag("tracks-folder-${f.id}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.Folder, null, tint = MaterialTheme.colorScheme.primary)
                            Text(f.name.ifEmpty { "Folder" }, Modifier.weight(1f).padding(start = 12.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${members.size}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(if (isOpen) "v" else ">", Modifier.padding(start = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Box {
                                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "Folder actions") }
                                DropdownMenu(menu, { menu = false }) {
                                    DropdownMenuItem(text = { Text("Rename folder") }, onClick = { menu = false; renameFolder = f.id })
                                    DropdownMenuItem(text = { Text("Delete folder") }, onClick = { menu = false; deleteFolder = f.id })
                                }
                            }
                        }
                    }
                    if (isOpen) {
                        if (members.isEmpty()) item(key = "f-${f.id}-empty") {
                            Text("Empty folder — move an arrangement in with its ⋮ menu.", Modifier.padding(horizontal = 32.dp, vertical = 4.dp),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        items(members, key = { "a-${it.id}" }) { a ->
                            ArrangementBlock(a, folders, store, actions, audition, expandedGroups, onOpen,
                                onRename = { renameArr = a }, onDelete = { deleteArr = a }, onNewFolder = { moveNewFolderFor = a.id })
                        }
                    }
                }
            }
        }
    }

    if (newFolder) NameDialog("New folder", "", "Create", { newFolder = false }) { store.createFolder(StudioFolderKind.ARRANGEMENT, it); newFolder = false }
    moveNewFolderFor?.let { aid ->
        NameDialog("New folder", "", "Create & move", { moveNewFolderFor = null }) {
            val f = store.createFolder(StudioFolderKind.ARRANGEMENT, it); store.setItemFolder(StudioFolderKind.ARRANGEMENT, aid, f.id); moveNewFolderFor = null
        }
    }
    renameArr?.let { a -> NameDialog("Rename arrangement", a.name, "Rename", { renameArr = null }) { store.renameArrangement(a.id, it); renameArr = null } }
    renameFolder?.let { fid ->
        NameDialog("Rename folder", store.folder(StudioFolderKind.ARRANGEMENT, fid)?.name ?: "", "Rename", { renameFolder = null }) {
            store.renameFolder(StudioFolderKind.ARRANGEMENT, fid, it); renameFolder = null
        }
    }
    deleteArr?.let { a ->
        AlertDialog(
            onDismissRequest = { deleteArr = null }, title = { Text("Delete this arrangement?") },
            text = { Text("Its tracks and clips are removed.") },
            confirmButton = { TextButton(onClick = { if (audition.playingId != null) audition.stop(); store.deleteArrangement(a.id); deleteArr = null }, modifier = Modifier.testTag("tracks-delete-confirm")) { Text("Delete arrangement") } },
            dismissButton = { TextButton(onClick = { deleteArr = null }) { Text("Cancel") } },
        )
    }
    deleteFolder?.let { fid ->
        AlertDialog(
            onDismissRequest = { deleteFolder = null }, title = { Text("Delete this folder?") },
            text = { Text("Its arrangements move to “No folder” (nothing is deleted).") },
            confirmButton = { TextButton(onClick = { store.deleteFolder(StudioFolderKind.ARRANGEMENT, fid); deleteFolder = null }) { Text("Delete folder") } },
            dismissButton = { TextButton(onClick = { deleteFolder = null }) { Text("Cancel") } },
        )
    }
}

/** An arrangement row plus its collapsible Bounces / Recordings groups. */
@Composable
private fun ArrangementBlock(
    a: StudioArrangement,
    folders: List<com.levi.pocketdj.studio.model.StudioFolder>,
    store: com.levi.pocketdj.studio.store.StudioStore,
    actions: TracksActions,
    audition: ArtifactAuditionPlayer,
    expanded: androidx.compose.runtime.snapshots.SnapshotStateList<String>,
    onOpen: (String) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onNewFolder: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable { onOpen(a.id) }.padding(start = 16.dp).testTag("tracks-arr-row-${a.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.ViewTimeline, null, tint = trackColor(0))
        Column(Modifier.weight(1f).padding(start = 12.dp, top = 8.dp, bottom = 8.dp)) {
            Text(a.name.ifEmpty { "Untitled" }, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(ArrangerMath.summary(a), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.testTag("tracks-arr-menu-${a.id}")) { Icon(Icons.Filled.MoreVert, "Arrangement actions") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Open") }, onClick = { menu = false; onOpen(a.id) })
                DropdownMenuItem(text = { Text("Rename…") }, onClick = { menu = false; onRename() })
                DropdownMenuItem(text = { Text("No folder") }, enabled = a.folderId != null, onClick = { menu = false; store.setItemFolder(StudioFolderKind.ARRANGEMENT, a.id, null) })
                folders.forEach { f ->
                    DropdownMenuItem(text = { Text("Move to ${f.name.ifEmpty { "Folder" }}") }, enabled = a.folderId != f.id,
                        onClick = { menu = false; store.setItemFolder(StudioFolderKind.ARRANGEMENT, a.id, f.id) })
                }
                DropdownMenuItem(text = { Text("New folder…") }, onClick = { menu = false; onNewFolder() }, modifier = Modifier.testTag("tracks-move-new-folder"))
                DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
            }
        }
        Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 12.dp))
    }
    for (kind in StudioArrangementArtifact.Kind.entries) {
        val arts = store.artifacts(a.id, kind)
        if (arts.isEmpty()) continue
        val key = "${a.id}-${kind.raw}"
        ArtifactGroup(
            a.id, kind, arts, expanded = key in expanded,
            onToggle = { if (key in expanded) expanded.remove(key) else expanded.add(key) },
            audition = audition, fileFor = { store.artifactFile(it.fileName) },
            onConvert = actions::convertArtifactToSample,
            onAddAsTrack = { actions.addArtifactAsTrack(a.id, it) },
            onDelete = { if (audition.playingId == it.id) audition.stop(); actions.deleteArtifact(it.id) },
        )
    }
    HorizontalDivider()
}
