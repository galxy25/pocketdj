package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.favorites.FavoriteFilter
import java.text.DateFormat
import java.util.Date

/**
 * Filter sheet — the iOS clause editor (`FilterSheet.swift`): a list of AND-composed clauses
 * (field -> operator -> value editor), per-clause remove, Add filter, then the song-mode
 * Favorites tri-state, History-only Hide skips, and the song-mode membership SHOW/HIDE section.
 * Opens fully expanded (full width/height) so long editors never clip.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BrowseFilterSheet(
    kind: BrowseKind,
    filters: BrowseFilters,
    /** Distinct values for an options-backed field (genre, key, source...). */
    optionsFor: (String) -> List<String>,
    /** Song mode only (iOS): the heart tri-state is meaningless for albums/artists. */
    showFavorite: Boolean = false,
    /** History mode adds the Last played field and the Hide skips toggle, drops membership. */
    historyMode: Boolean = false,
    playlists: List<CollectionRef> = emptyList(),
    pockets: List<CollectionRef> = emptyList(),
    onFilters: (BrowseFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    val fields = Fields.forKind(kind, includeHistory = historyMode)
    val showMembership = kind == BrowseKind.SONGS && !historyMode && (playlists.isNotEmpty() || pockets.isNotEmpty())

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    "Filters",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { onFilters(filters.clearedAll()) },
                    enabled = filters.clauses.isNotEmpty() || filters.favoriteActive || filters.hideSkips,
                    modifier = Modifier.testTag("filter-clear-all"),
                ) { Text("Clear all") }
                TextButton(onClick = onDismiss, modifier = Modifier.testTag("filter-done")) { Text("Done") }
            }

            if (filters.clauses.isEmpty()) {
                Text(
                    "No filters. Add one to narrow the ${if (kind == BrowseKind.ALBUMS) "albums" else if (kind == BrowseKind.ARTISTS) "artists" else "songs"}.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }

            filters.clauses.forEach { clause ->
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                ClauseEditorRow(
                    clause = clause,
                    fields = fields,
                    options = optionsFor,
                    onChange = { updated ->
                        onFilters(filters.copy(clauses = filters.clauses.map { if (it.id == clause.id) updated else it }))
                    },
                    onRemove = { onFilters(filters.copy(clauses = filters.clauses.filterNot { it.id == clause.id })) },
                )
            }

            OutlinedButton(
                onClick = {
                    ClauseReducer.newClause(fields)?.let { onFilters(filters.copy(clauses = filters.clauses + it)) }
                },
                modifier = Modifier.padding(top = 12.dp).testTag("add-filter"),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Add filter")
            }

            if (showFavorite && !historyMode) {
                SectionLabel("Favorites")
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    val opts = listOf(
                        FavoriteFilter.ANY to "Any",
                        FavoriteFilter.FAVORITE to "Favorites",
                        FavoriteFilter.NOT to "Not favorites",
                    )
                    opts.forEachIndexed { i, (v, label) ->
                        SegmentedButton(
                            selected = filters.favorite == v,
                            onClick = { onFilters(filters.withFavorite(v)) },
                            shape = SegmentedButtonDefaults.itemShape(i, opts.size),
                            modifier = Modifier.testTag("favorite-filter-${v.name.lowercase()}"),
                        ) { Text(label) }
                    }
                }
            }

            if (historyMode) {
                SectionLabel("Playback")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("Hide skips", modifier = Modifier.weight(1f))
                    Switch(
                        checked = filters.hideSkips,
                        onCheckedChange = { onFilters(filters.withHideSkips(it)) },
                        modifier = Modifier.testTag("filter-hide-skips"),
                    )
                }
            }

            if (showMembership) {
                SectionLabel("Collection membership")
                MembershipSection(
                    membership = filters.membership,
                    playlists = playlists,
                    pockets = pockets,
                    onChange = { onFilters(filters.withMembership(it)) },
                )
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Spacer(Modifier.height(20.dp))
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(Modifier.height(6.dp))
}
