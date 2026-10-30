package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.StudioItemInfo
import com.levi.pocketdj.di.AppGraph

/**
 * The studio display info for [id] (null for a catalog / unknown id). Computed OFF-main and re-derived on every
 * studio-document change (rename, bounce length, detected key, delete), so a row never goes stale.
 */
@Composable
fun rememberStudioInfo(id: String?): StudioItemInfo? {
    if (id == null || !com.levi.pocketdj.data.rips.PlayResolver.isStudioId(id)) return null
    val context = LocalContext.current
    val info by produceState<StudioItemInfo?>(initialValue = null, id) {
        val graph = AppGraph.get(context)
        val flow = withContext(Dispatchers.IO) { graph.studioGraph.studioStore.state }
        flow.collect { withContext(Dispatchers.IO) { value = graph.collections.studioInfo(id) } }
    }
    return info
}

/** The studio-row artist label (Q50): the profile name, fallback "Pocket DJ". Recomposes when the profile changes. */
@Composable
fun rememberStudioArtist(): String {
    val context = LocalContext.current
    val name by produceState(initialValue = "Pocket DJ") {
        val graph = AppGraph.get(context)
        graph.servicesGraph.profile.state.collect { value = com.levi.pocketdj.data.collections.studioArtistFor(it.name) }
    }
    return name
}

/**
 * A collection row for a Studio item (sample / loop / sequence / instrumental): title, the "Studio"
 * performer label, bpm + key when known, the REAL length, and a kind badge. Tapping plays the item (the
 * caller wires onClick to playNow); a studio id has no catalog song sheet.
 */
@Composable
fun StudioItemRow(
    info: StudioItemInfo,
    modifier: Modifier = Modifier,
    artist: String = "Pocket DJ",
    onClick: (() -> Unit)? = null,
    badges: (@Composable RowScope.() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    CollectionTrackRow(
        title = info.title,
        subtitle = artist,
        album = null,
        bpm = info.bpm,
        camelot = info.camelot,
        lengthMs = info.lengthMs.toLong().takeIf { it > 0 },
        dimmed = false,
        modifier = modifier,
        onClick = onClick,
        badges = {
            if (info.kindLabel.isNotEmpty()) {
                Spacer(Modifier.width(6.dp))
                CapsuleBadge(info.kindLabel)
            }
            badges?.invoke(this)
        },
        trailing = trailing,
    )
}
