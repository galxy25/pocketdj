package com.levi.pocketdj.ui.selection

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore

/**
 * The pure, unit-testable semantics behind [SelectionBar] (iOS `SelectionBar.add(to:)` and
 * friends) — kept out of Compose so the contracts have JVM tests.
 */
object SelectionBarSemantics {
    /** Quick "Add to" rows shown above the Pockets / Playlists submenus (iOS: prefix(3)). */
    const val RECENT_LIMIT = 3

    fun countLabel(count: Int): String = "$count selected"

    /**
     * Add-to from the bar: ONE [addSongs] call with the display-ordered song ids. A stale
     * selection whose payload resolves to nothing CLEARS the selection instead of advertising a
     * count that can't act (returns [AddResult.StaleCleared]).
     */
    fun addTo(
        selection: RowSelection,
        target: AddTarget,
        addSongs: (List<String>, AddTarget) -> Int,
    ): AddResult {
        val ids = selection.currentPayload()?.songIds
        if (ids.isNullOrEmpty()) {
            selection.clearAndExit()
            return AddResult.StaleCleared
        }
        return AddResult.Added(requested = ids.size, added = addSongs(ids, target))
    }

    /** Copy is live only for a selection owned by the active list. */
    fun copyEnabled(state: SelectionState): Boolean = state.canCopy

    /** Recent MRU rows that STILL resolve to a live collection, with their labels. */
    fun recentRows(store: CollectionsStore): List<Pair<AddTarget, String>> =
        store.recentAddTargets.mapNotNull { t -> store.lastTargetLabel(t)?.let { t to it } }.take(RECENT_LIMIT)

    /** Collections A–Z (case-insensitive) for the Pockets / Playlists submenus. */
    fun <T> sortedAZ(items: List<T>, name: (T) -> String): List<T> = items.sortedBy { name(it).lowercase() }

    /** Clipboard items: plain text FIRST (what other apps paste), then the typed JSON. */
    fun clipTexts(t: SongTransfer): List<String> = listOf(t.plainTextExport, t.toJson())

    sealed interface AddResult {
        data object StaleCleared : AddResult
        data class Added(val requested: Int, val added: Int) : AddResult
    }
}

/** Put [t] on the system clipboard: text fallback + SongTransfer JSON (label `com.pocketdj.songlist`). */
fun writeSongTransfer(context: Context, t: SongTransfer) {
    if (t.songIds.isEmpty()) return
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    val (text, json) = SelectionBarSemantics.clipTexts(t)
    val clip = ClipData.newPlainText(SongTransfer.CLIP_LABEL, text)
    clip.addItem(ClipData.Item(json))
    cm.setPrimaryClip(clip)
}

/** Read a SongTransfer back (item 1 JSON, byte-capped); null when the clip isn't ours. */
fun readSongTransfer(context: Context): SongTransfer? {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return null
    val clip = cm.primaryClip ?: return null
    if (clip.description?.label != SongTransfer.CLIP_LABEL || clip.itemCount < 2) return null
    return SongTransfer.decode(clip.getItemAt(1).text?.toString().orEmpty())
}

/**
 * Makes a song row multi-selectable. Replaces the row's tap handler: a plain tap still runs
 * [onOpen] UNLESS select mode is armed in THIS [scope] (a mode armed in another list is
 * invisible here — the swallowed-first-tap bug). Long-press arms select mode in the scope.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.selectableRow(
    selection: RowSelection,
    id: String,
    scope: String,
    onOpen: (() -> Unit)?,
): Modifier {
    val openLatest by rememberUpdatedState(onOpen)
    return this
        .selectionDecor(selection, id, scope)
        .combinedClickable(
            onClick = { selectionTap(selection, id, scope) { openLatest?.invoke() } },
            onLongClick = { selection.handleLongPress(id, scope) },
        )
}

/** Tap routing for rows that own their own click handler: [open] runs unless select mode eats the tap. */
fun selectionTap(selection: RowSelection, id: String, scope: String, open: () -> Unit) {
    if (selection.handleTap(id, scope) == RowSelection.TapOutcome.NAVIGATE) open()
}

/** Visuals only: selected highlight + (while armed in [scope]) the check badge. */
@Composable
fun Modifier.selectionDecor(selection: RowSelection, id: String, scope: String): Modifier {
    val state by selection.state.collectAsState()
    val selected = state.isSelected(id, scope)
    val armed = state.isSelectMode(scope)
    val accent = MaterialTheme.colorScheme.primary
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    return this
        .let { if (selected) it.background(accent.copy(alpha = 0.26f), RoundedCornerShape(6.dp)) else it }
        .drawWithContent {
            drawContent()
            if (armed) {
                val c = Offset(10.dp.toPx(), 10.dp.toPx())
                if (selected) drawCircle(accent, radius = 5.dp.toPx(), center = c)
                drawCircle(if (selected) accent else dim, radius = 6.5.dp.toPx(), center = c, style = Stroke(1.5.dp.toPx()))
            }
        }
        .semantics { if (selected) contentDescription = "selected" }
}

/**
 * Registers a list as the window's selectable list while composed, prunes the selection when
 * [pruneKey] changes (the rendered id set changed under it), and optionally registers a paste
 * target. Disposal unregisters (and disarms select mode this list owned).
 */
@Composable
fun SelectionScope(
    selection: RowSelection,
    scope: String,
    pruneKey: Any?,
    allIds: () -> List<String>,
    payload: () -> SongTransfer?,
    onPaste: ((SongTransfer) -> Unit)? = null,
) {
    val allIdsL by rememberUpdatedState(allIds)
    val payloadL by rememberUpdatedState(payload)
    val pasteL by rememberUpdatedState(onPaste)
    DisposableEffect(selection, scope, onPaste != null) {
        selection.registerActiveList(scope, { allIdsL() }, { payloadL() })
        if (pasteL != null) selection.registerPasteTarget(scope) { pasteL?.invoke(it) }
        onDispose {
            selection.unregisterActiveList(scope)
            selection.unregisterPasteTarget(scope)
        }
    }
    LaunchedEffect(pruneKey) {
        val s = selection.state.value
        if (s.scopeId == scope && s.hasSelection) selection.prune(allIdsL().toHashSet())
    }
}

private enum class AddMenuPage { ROOT, POCKETS, PLAYLISTS }

/**
 * The header shown while a selection (or select mode) is active in [scope]:
 * count · Select all · Add to ▾ [Recent · Pockets A–Z · Playlists A–Z] · Copy · Clear.
 */
@Composable
fun SelectionBar(
    selection: RowSelection,
    scope: String,
    store: CollectionsStore,
    modifier: Modifier = Modifier,
) {
    val state by selection.state.collectAsState()
    if (!state.isActive(scope)) return
    val coll by store.state.collectAsState()
    val context = LocalContext.current
    var menuOpen by remember { mutableStateOf(false) }
    var page by remember { mutableStateOf(AddMenuPage.ROOT) }

    fun add(target: AddTarget) {
        menuOpen = false
        when (val r = SelectionBarSemantics.addTo(selection, target) { ids, t -> store.addSongs(ids, t) }) {
            SelectionBarSemantics.AddResult.StaleCleared -> Unit
            is SelectionBarSemantics.AddResult.Added -> {
                val label = store.lastTargetLabel(target) ?: "collection"
                val msg = if (r.added > 0) "Added ${r.added} to $label" else "Already in $label"
                Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
            }
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 12.dp, vertical = 2.dp)
            .testTag("selection-bar"),
    ) {
        Text(
            SelectionBarSemantics.countLabel(state.count),
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier
                .weight(1f)
                .testTag("selection-count"),
        )
        TextButton(onClick = { selection.selectAll() }, enabled = state.canSelectAll) { Text("Select all") }
        TextButton(
            onClick = { page = AddMenuPage.ROOT; menuOpen = true },
            enabled = state.canCopy,
        ) {
            Text("Add to")
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                when (page) {
                    AddMenuPage.ROOT -> {
                        val recents = SelectionBarSemantics.recentRows(store)
                        recents.forEach { (t, label) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { add(t) })
                        }
                        if (recents.isNotEmpty()) HorizontalDivider()
                        if (coll.pockets.isNotEmpty()) {
                            DropdownMenuItem(text = { Text("Pockets ▸") }, onClick = { page = AddMenuPage.POCKETS })
                        }
                        if (coll.playlists.isNotEmpty()) {
                            DropdownMenuItem(text = { Text("Playlists ▸") }, onClick = { page = AddMenuPage.PLAYLISTS })
                        }
                        if (coll.pockets.isEmpty() && coll.playlists.isEmpty()) {
                            DropdownMenuItem(text = { Text("No collections yet") }, enabled = false, onClick = {})
                        }
                    }
                    AddMenuPage.POCKETS ->
                        SelectionBarSemantics.sortedAZ(coll.pockets) { it.name }.forEach { p ->
                            DropdownMenuItem(
                                text = { Text(p.name) },
                                onClick = { add(AddTarget(AddTarget.Kind.POCKET, p.id)) },
                            )
                        }
                    AddMenuPage.PLAYLISTS ->
                        SelectionBarSemantics.sortedAZ(coll.playlists) { it.name }.forEach { pl ->
                            DropdownMenuItem(
                                text = { Text(pl.name) },
                                onClick = { add(AddTarget(AddTarget.Kind.PLAYLIST, pl.id)) },
                            )
                        }
                }
            }
        }
        IconButton(
            onClick = { selection.currentPayload()?.let { writeSongTransfer(context, it) } },
            enabled = SelectionBarSemantics.copyEnabled(state),
        ) { Icon(Icons.Filled.ContentCopy, contentDescription = "Copy selected songs") }
        IconButton(onClick = { selection.clearAndExit() }) {
            Icon(Icons.Filled.Close, contentDescription = "Clear selection")
        }
    }
}
