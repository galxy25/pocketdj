package com.levi.pocketdj.screens.discover

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.discover.DiscoverAddsStore

/**
 * Whether a provisional Discover album offers "Add to Apple Music again" (iOS `AlbumLibraryWriteRetry`).
 * PURE: owed whenever the stored write token doesn't PROVE the write landed - a recorded failure/skip, or a LEGACY
 * entry (null) from before outcomes were tracked - and only where the device can actually write the library now
 * (a button that can only re-skip is a dead control).
 */
object AlbumLibraryWriteRetry {
    const val LABEL = "Add to Apple Music again"
    const val BUSY_LABEL = "Adding to Apple Music…"

    fun needsRetry(token: String?, canAddToLibrary: Boolean): Boolean =
        canAddToLibrary && !DiscoverAddsStore.provenByToken(token)

    /** Album ids (of [albums]) that owe a retry. */
    fun albumIdsNeedingRetry(albums: List<DiscoverAddsStore.AlbumEntry>, canAddToLibrary: Boolean): Set<String> =
        albums.filter { needsRetry(it.libraryWrite, canAddToLibrary) }.map { it.albumId }.toSet()

    /** Album id -> stored write token (null = legacy) for every album owing a retry. */
    fun retryTokens(albums: List<DiscoverAddsStore.AlbumEntry>, canAddToLibrary: Boolean): Map<String, String?> =
        albums.filter { needsRetry(it.libraryWrite, canAddToLibrary) }.associate { it.albumId to it.libraryWrite }

    /**
     * Live retry map: re-emits when EITHER the store snapshot or the can-write flag changes (a one-shot read of
     * canAdd inside a store map goes stale: DataStore delivers hasAppleMusic after the first snapshot).
     */
    fun retryTokensFlow(
        snapshots: kotlinx.coroutines.flow.Flow<DiscoverAddsStore.Snapshot>,
        canAdd: kotlinx.coroutines.flow.Flow<Boolean>,
    ): kotlinx.coroutines.flow.Flow<Map<String, String?>> =
        kotlinx.coroutines.flow.combine(snapshots, canAdd) { snap, can -> retryTokens(snap.albums, can) }

    /** User-facing message for a retry/add whose write didn't land (iOS `libraryWriteNotice`); null = it landed. */
    fun notice(token: String, noun: String = "album"): String? = when {
        DiscoverAddsStore.provenByToken(token) -> null
        token == LibraryWrite.SKIPPED_NO_CONNECTION ->
            "Added to PocketDJ only — Apple Music isn’t connected."
        token.startsWith("Apple Music write failed: ") ->
            "Added to PocketDJ, but the Apple Music library add failed: ${token.removePrefix("Apple Music write failed: ")}"
        else -> "Added to PocketDJ, but the $noun hasn’t appeared in your Apple Music library yet — " +
            "use “$LABEL” if it doesn’t show up."
    }
}

/** The retry affordance under a recorded album row. */
@Composable
fun DiscoverRetryRow(
    retrying: Boolean,
    notice: String?,
    onRetry: () -> Unit,
    /** Stored failure/skip reason shown above the button (iOS parity); null for legacy entries. */
    reason: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().padding(start = 80.dp, end = 16.dp)) {
        if (!reason.isNullOrBlank()) {
            Text(reason, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(
                onClick = onRetry, enabled = !retrying,
                modifier = Modifier.semantics { contentDescription = AlbumLibraryWriteRetry.LABEL },
            ) { Text(if (retrying) AlbumLibraryWriteRetry.BUSY_LABEL else AlbumLibraryWriteRetry.LABEL) }
            if (retrying) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
        }
        if (notice != null) {
            Text(notice, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
        }
    }
}
