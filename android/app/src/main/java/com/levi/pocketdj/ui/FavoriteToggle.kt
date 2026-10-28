package com.levi.pocketdj.ui

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.favorites.FavoritesStore
import com.levi.pocketdj.di.AppGraph

/**
 * ♥ — the ONE favorite control shared by every song surface (rows, album track table, song
 * detail). Filled + accent when on, outline + dim when off. One tap = one
 * [FavoritesStore.toggle]; the store owns tombstones, persistence and the activity row.
 * Pass [appleMusicId] when the song has one (vinyl/digital/studio pass null: local-only).
 */
@Composable
fun FavoriteToggle(
    songId: String,
    modifier: Modifier = Modifier,
    appleMusicId: String? = null,
    iconSize: Dp = 20.dp,
    store: FavoritesStore = AppGraph.get(LocalContext.current).collectionsGraph.favorites,
) {
    val state by store.state.collectAsState()
    FavoriteToggleButton(
        on = songId in state.favoriteIds,
        onToggle = { store.toggle(songId, appleMusicId) },
        modifier = modifier.testTag("favorite-toggle-$songId"),
        iconSize = iconSize,
    )
}

/** Stateless ♥ glyph button (previews / tests / callers that own the state). */
@Composable
fun FavoriteToggleButton(
    on: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    iconSize: Dp = 20.dp,
) {
    val label = if (on) "Unfavorite" else "Favorite"
    IconButton(onClick = onToggle, modifier = modifier.semantics { contentDescription = label }) {
        Icon(
            imageVector = if (on) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder,
            contentDescription = null,
            tint = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(iconSize),
        )
    }
}
