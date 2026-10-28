package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.StudioItemInfo
import com.levi.pocketdj.di.AppGraph

/** The studio display info for [id] (null for a catalog / unknown id). Remembered per id. */
@Composable
fun rememberStudioInfo(id: String?): StudioItemInfo? {
    if (id == null || !com.levi.pocketdj.data.rips.PlayResolver.isStudioId(id)) return null
    val context = LocalContext.current
    return remember(id) { AppGraph.get(context).collections.studioInfo(id) }
}

/**
 * A collection row for a Studio item (sample / loop / sequence / instrumental): title, the "Studio"
 * performer label, bpm + key when known, the REAL length, and a kind badge. Not tappable into the
 * catalog song sheet (a studio id has no catalog entry).
 */
@Composable
fun StudioItemRow(
    info: StudioItemInfo,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    badges: (@Composable RowScope.() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    CollectionTrackRow(
        title = info.title,
        subtitle = "Studio",
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
