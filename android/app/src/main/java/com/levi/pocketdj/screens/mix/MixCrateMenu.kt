package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.mix.model.MixSource

/** One pickable crate (iOS `MixCrateEntry`). */
@Immutable
data class MixCrateEntry(val section: String, val name: String, val source: MixSource) {
    val id: String get() = "$section|$name|${source.id}"
}

/** The entry list as ONE stable value, so the menu composable is skippable while it is open. */
@Immutable
data class MixCrateEntries(val list: List<MixCrateEntry>) {
    val isEmpty: Boolean get() = list.isEmpty()
}

/** Pure construction + section grouping for the crate menu. */
object MixCrateMenuState {
    const val POCKETS = "Pockets"
    const val PLAYLISTS = "Playlists"
    const val SETLISTS = "Set lists"
    const val EMPTY_TEXT = "No pockets, playlists, or set lists yet"
    const val SAME_AS_A = "Same as Crate A"

    private val az = compareBy<MixCrateEntry, String>(String.CASE_INSENSITIVE_ORDER) { it.name }

    /** Every crate the Mix can pull from, A–Z within Pockets · Playlists · Set lists. */
    fun entries(pockets: List<Pocket>, playlists: List<Playlist>, setlists: List<Setlist>): List<MixCrateEntry> =
        pockets.map { MixCrateEntry(POCKETS, it.name, MixSource.Pocket(it.id)) }.sortedWith(az) +
            playlists.map { MixCrateEntry(PLAYLISTS, it.name, MixSource.Playlist(it.id)) }.sortedWith(az) +
            setlists.filter { it.id != NOW_PLAYING_SETLIST_ID }
                .map { MixCrateEntry(SETLISTS, it.name ?: "Set list", MixSource.Setlist(it.id)) }.sortedWith(az)

    /** Section titles in first-appearance order. */
    fun sections(entries: List<MixCrateEntry>): List<String> {
        val seen = ArrayList<String>()
        for (e in entries) if (e.section !in seen) seen += e.section
        return seen
    }

    /** The menu's row model, top to bottom (reset row first when [resetTitle] is set). */
    fun rows(entries: List<MixCrateEntry>, resetTitle: String?): List<MenuRow> {
        val out = ArrayList<MenuRow>()
        if (resetTitle != null) out += MenuRow.Reset(resetTitle)
        if (entries.isEmpty()) out += MenuRow.Empty
        for (s in sections(entries)) {
            out += MenuRow.Header(s)
            entries.filter { it.section == s }.forEach { out += MenuRow.Pick(it) }
        }
        return out
    }

    /** "A · <name>" label text; [name] null ⇒ [fallback]. */
    fun label(prefix: String, name: String?, fallback: String) = "$prefix · ${name ?: fallback}"

    sealed interface MenuRow {
        data class Reset(val title: String) : MenuRow
        data object Empty : MenuRow
        data class Header(val title: String) : MenuRow
        data class Pick(val entry: MixCrateEntry) : MenuRow
    }
}

/**
 * The Mix crate picker (Auto Crate A / Crate B, a deck's source menu, the loader sheet).
 *
 * SKIPPABLE ON PURPOSE (iOS Equatable `MixCrateMenu`). Picking a crate starts its download run
 * whose progress ticks several times a second; if this composable's inputs changed with it, the
 * open menu's list would be rebuilt and snap back to the top, so the NEXT crate could never be
 * scrolled to. Every parameter is stable and equals-comparable ([MixCrateEntries], strings); the
 * pick callback is read through [rememberUpdatedState] and is deliberately NOT part of identity;
 * the scroll position is hoisted into this composable's own state.
 */
@Composable
fun MixCrateMenu(
    entries: MixCrateEntries,
    labelText: String,
    icon: ImageVector,
    onPick: (MixSource?) -> Unit,
    modifier: Modifier = Modifier,
    resetTitle: String? = null,
    tag: String = "mix-crate-menu",
) {
    val pick by rememberUpdatedState(onPick)
    var open by rememberSaveable { mutableStateOf(false) }
    val scroll = rememberScrollState()
    val rows = remember(entries, resetTitle) { MixCrateMenuState.rows(entries.list, resetTitle) }
    Box(modifier) {
        Surface(
            shape = RoundedCornerShape(10.dp), color = DeckColors.overlay,
            border = BorderStroke(1.dp, DeckColors.border),
            modifier = Modifier.clickable { open = true }.testTag(tag),
        ) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = DeckColors.accent, modifier = Modifier.size(18.dp))
                Text(
                    labelText, color = DeckColors.fg, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 6.dp).weight(1f, fill = false),
                )
                Icon(Icons.Filled.ArrowDropDown, null, tint = DeckColors.dim)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, scrollState = scroll) {
            for (row in rows) when (row) {
                is MixCrateMenuState.MenuRow.Reset -> DropdownMenuItem(
                    text = { Text(row.title) },
                    onClick = { open = false; pick(null) },
                    modifier = Modifier.testTag("$tag-reset"),
                )
                MixCrateMenuState.MenuRow.Empty -> Text(
                    MixCrateMenuState.EMPTY_TEXT, color = DeckColors.dim, fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
                is MixCrateMenuState.MenuRow.Header -> Text(
                    row.title, color = DeckColors.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                )
                is MixCrateMenuState.MenuRow.Pick -> DropdownMenuItem(
                    text = { Text(row.entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    onClick = { open = false; pick(row.entry.source) },
                    modifier = Modifier.testTag("$tag-${row.entry.source.id}"),
                )
            }
        }
    }
}
