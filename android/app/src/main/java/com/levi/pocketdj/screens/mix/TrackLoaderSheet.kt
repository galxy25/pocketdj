package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import com.levi.pocketdj.screens.browse.AlbumArt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The loader's list rules (iOS `TrackLoaderSheet`), pure. The query filters title / artist /
 * album name; auto-hide drops already-played rows unless [showPlayed]; the "Show N played" count
 * is taken from the SAME query-filtered set the list is, so flipping it reveals exactly N.
 */
object TrackLoaderFilter {
    class Result(val rows: List<MixLoadable>, val hiddenPlayed: Int, val queried: List<MixLoadable>)

    /** Search only (post-search, pre-played-drop). Blank query ⇒ everything. */
    fun queried(all: List<MixLoadable>, query: String, albumName: (String?) -> String): List<MixLoadable> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return all
        return all.filter { item ->
            item.title.lowercase().contains(q) ||
                item.artist.lowercase().contains(q) ||
                albumName(item.albumId).lowercase().contains(q)
        }
    }

    fun visible(queried: List<MixLoadable>, autoHidePlayed: Boolean, showPlayed: Boolean, hasPlayed: (String) -> Boolean): List<MixLoadable> =
        if (!autoHidePlayed || showPlayed) queried else queried.filter { !hasPlayed(it.songId) }

    fun hiddenPlayedCount(queried: List<MixLoadable>, autoHidePlayed: Boolean, hasPlayed: (String) -> Boolean): Int =
        if (!autoHidePlayed) 0 else queried.count { hasPlayed(it.songId) }

    fun apply(
        all: List<MixLoadable>, query: String, autoHidePlayed: Boolean, showPlayed: Boolean,
        albumName: (String?) -> String, hasPlayed: (String) -> Boolean,
    ): Result {
        val q = queried(all, query, albumName)
        return Result(
            rows = visible(q, autoHidePlayed, showPlayed, hasPlayed),
            hiddenPlayed = hiddenPlayedCount(q, autoHidePlayed, hasPlayed),
            queried = q,
        )
    }

    /** Whether the Show-played toggle row appears. */
    fun showToggle(hiddenPlayed: Int, showPlayed: Boolean) = hiddenPlayed > 0 || showPlayed

    fun toggleLabel(hiddenPlayed: Int, showPlayed: Boolean) =
        if (showPlayed) "Showing played" else "Show $hiddenPlayed played"
}

/** What the loader needs from the app (kept narrow so the sheet has no graph dependency). */
class TrackLoaderEnv(
    val entries: MixCrateEntries,
    val crateName: (MixSource?) -> String?,
    val loadables: (MixSource?) -> List<MixLoadable>,
    val album: (String?) -> IndexAlbum?,
    val hasPlayed: (String) -> Boolean,
    /** Bumped when a track becomes played so the list refreshes. */
    val playedRevision: kotlinx.coroutines.flow.StateFlow<Int>,
    val autoHidePlayed: Boolean,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrackLoaderSheet(
    deck: Deck,
    source: MixSource?,
    env: TrackLoaderEnv,
    onPickSource: (MixSource?) -> Unit,
    onLoad: (MixLoadable) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var showPlayed by rememberSaveable { mutableStateOf(false) }
    val playedRev by env.playedRevision.collectAsState()
    // Resolved ONCE per source (it stats every candidate file), off the main thread.
    val resolved by produceState(emptyList<MixLoadable>(), source) {
        value = withContext(Dispatchers.IO) { env.loadables(source) }
    }
    val result = remember(resolved, query, showPlayed, playedRev, env.autoHidePlayed) {
        TrackLoaderFilter.apply(
            all = resolved, query = query, autoHidePlayed = env.autoHidePlayed, showPlayed = showPlayed,
            albumName = { id -> env.album(id)?.name.orEmpty() }, hasPlayed = env.hasPlayed,
        )
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = DeckColors.raised,
        // Full-height sheet: keep it below the status bar (it ran under the clock).
        modifier = Modifier.statusBarsPadding().testTag("mix-loader"),
    ) {
        Column(Modifier.fillMaxSize().navigationBarsPadding().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Load Deck ${deck.label}", color = DeckColors.fg, fontSize = 18.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss, modifier = Modifier.testTag("mix-loader-done")) { Text("Done") }
            }
            MixCrateMenu(
                entries = env.entries,
                labelText = env.crateName(source) ?: "Pick a source",
                icon = Icons.Filled.Layers,
                onPick = { s -> if (s != null) onPickSource(s) },
                modifier = Modifier.fillMaxWidth(),
                tag = "mix-loader-source",
            )
            OutlinedTextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                placeholder = { Text("Search artist, title, album") },
                modifier = Modifier.fillMaxWidth().testTag("mix-loader-search"),
            )
            if (TrackLoaderFilter.showToggle(result.hiddenPlayed, showPlayed)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        TrackLoaderFilter.toggleLabel(result.hiddenPlayed, showPlayed),
                        color = DeckColors.dim, fontSize = 12.sp, modifier = Modifier.weight(1f),
                    )
                    Switch(checked = showPlayed, onCheckedChange = { showPlayed = it }, modifier = Modifier.testTag("mix-loader-show-played"))
                }
            }
            when {
                source == null -> Empty("Pick a source", "Choose a pocket, playlist, or set list to load tracks from.")
                result.rows.isEmpty() -> Empty(
                    "No loadable tracks",
                    "Only burned (on-device) or streamable songs can be mixed. Burn this collection first.",
                )
                else -> LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                    items(result.rows, key = { it.songId }) { item ->
                        LoaderRow(item, env, played = env.hasPlayed(item.songId)) { onLoad(item); onDismiss() }
                    }
                }
            }
        }
    }
}

@Composable
private fun Empty(title: String, caption: String) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, color = DeckColors.fg, fontSize = 16.sp)
        Text(caption, color = DeckColors.dim, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun LoaderRow(item: MixLoadable, env: TrackLoaderEnv, played: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 6.dp).testTag("mix-loader-row-${item.songId}"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(40.dp)) { AlbumArt(env.album(item.albumId), Modifier.size(40.dp)) }
        Column(Modifier.weight(1f)) {
            Text(item.title, color = DeckColors.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(item.artist, color = DeckColors.dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (played) Icon(
            Icons.Filled.CheckCircle, null, tint = DeckColors.gold,
            modifier = Modifier.size(18.dp).semantics { contentDescription = "Played" },
        )
        val cam = item.camelot
        if (!cam.isNullOrEmpty()) Text(cam, color = DeckColors.accent, fontSize = 12.sp)
        else item.bpm?.let { Text("${Math.round(it)}", color = DeckColors.dim, fontSize = 12.sp) }
    }
}
