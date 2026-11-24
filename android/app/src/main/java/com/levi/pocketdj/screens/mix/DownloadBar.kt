package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.mix.download.CatalogShortfall
import com.levi.pocketdj.mix.download.CollectionMixDownloader
import com.levi.pocketdj.mix.download.LaneIssue
import com.levi.pocketdj.mix.download.MixDownloadState
import kotlinx.coroutines.flow.StateFlow

/** What the bottom bar shows for a downloader state (iOS `MixView.downloadBar`), pure. */
object DownloadBarModel {
    sealed interface Ui {
        /** "N of M downloaded · ~ETA left [· K ripping]" + progress + ✕. */
        data class Progress(
            val headline: String, val eta: String, val ripping: String?,
            val fraction: Float, val shortfall: String?,
            /** Why the lanes can't fetch (token rejected / no server / ...); null when healthy. */
            val issue: String? = null,
            /** Offer "Play in Now Playing" (zero dead air): the lanes can't fetch audio without the user fixing Settings. */
            val offerNowPlaying: Boolean = false,
        ) : Ui

        /** No run in flight, but the catalog is still short of what the crates declared. */
        data class ShortfallOnly(val caption: String) : Ui
    }

    fun shortfallCaption(s: CatalogShortfall, stillLoading: Boolean = true) =
        LaneIssue.shortfallCaption(s.declared, s.total, stillLoading)

    /** The copy line naming WHY nothing is moving, or null. A rejected token also shows with zero ripping songs. */
    fun issueLine(issue: LaneIssue?): String? = when (issue) {
        LaneIssue.TokenRejected -> LaneIssue.TOKEN_REJECTED_COPY
        else -> null
    }

    fun of(st: MixDownloadState): Ui? {
        if (st.isActive && st.downloadedCount < st.totalCount) {
            return Ui.Progress(
                headline = "${st.downloadedCount} of ${st.totalCount} downloaded",
                eta = "· ~${CollectionMixDownloader.etaLabel(st.etaSeconds)} left",
                ripping = LaneIssue.rippingLabel(st.rippingCount, st.laneIssue),
                fraction = (st.downloadedCount.toFloat() / maxOf(st.totalCount, 1)).coerceIn(0f, 1f),
                shortfall = st.catalogShortfall?.let { shortfallCaption(it, st.catalogStillLoading) },
                issue = issueLine(st.laneIssue),
                offerNowPlaying = st.laneIssue?.offersNowPlayingFallback == true,
            )
        }
        return st.catalogShortfall?.let { Ui.ShortfallOnly(shortfallCaption(it, st.catalogStillLoading)) }
    }
}

/**
 * The bottom-pinned collection download bar. It is the ONLY collector of the downloader's state
 * flow: progress ticks recompose this composable and nothing above it (an open crate menu keeps
 * its scroll position).
 */
@Composable
fun DownloadBar(
    state: StateFlow<MixDownloadState>,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    /** "Play in Now Playing" (zero-dead-air fallback); the button only shows when the lanes can't fetch audio. */
    onPlayInNowPlaying: (() -> Unit)? = null,
) {
    val st by state.collectAsState()
    when (val ui = DownloadBarModel.of(st)) {
        null -> Unit
        is DownloadBarModel.Ui.Progress -> Surface(
            modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 6.dp),
            shape = RoundedCornerShape(12.dp), color = DeckColors.raised,
            border = BorderStroke(1.dp, DeckColors.accent.copy(alpha = 0.5f)),
        ) {
            Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(
                    Modifier.weight(1f).testTag("mix-dl-bar").semantics(mergeDescendants = true) {},
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(ui.headline, color = DeckColors.fg, fontSize = 12.sp, maxLines = 1)
                        Text(ui.eta, color = DeckColors.dim, fontSize = 12.sp, maxLines = 1)
                        ui.ripping?.let { Text(it, color = DeckColors.dim, fontSize = 12.sp, maxLines = 1) }
                    }
                    LinearProgressIndicator(
                        progress = { ui.fraction }, modifier = Modifier.fillMaxWidth(),
                        color = DeckColors.accent, trackColor = DeckColors.overlay,
                    )
                    ui.issue?.let { Text(it, color = DeckColors.danger, fontSize = 12.sp, maxLines = 3, modifier = Modifier.testTag("mix-dl-issue")) }
                    ui.shortfall?.let { Text(it, color = DeckColors.dim, fontSize = 12.sp, maxLines = 2) }
                }
                if (ui.offerNowPlaying && onPlayInNowPlaying != null) {
                    OutlinedButton(
                        onClick = onPlayInNowPlaying,
                        modifier = Modifier.testTag("mix-dl-fallback-nowplaying")
                            .semantics { contentDescription = "Play in Now Playing" },
                    ) { Text("Play in Now Playing", fontSize = 12.sp) }
                }
                IconButton(
                    onClick = onCancel,
                    modifier = Modifier.testTag("mix-dl-cancel").semantics { contentDescription = "Stop collection download" },
                ) { Icon(Icons.Filled.Close, null, tint = DeckColors.accent, modifier = Modifier.size(18.dp)) }
            }
        }
        is DownloadBarModel.Ui.ShortfallOnly -> Surface(
            modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 6.dp).testTag("mix-catalog-shortfall"),
            shape = RoundedCornerShape(12.dp), color = DeckColors.raised,
        ) {
            Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.Sync, null, tint = DeckColors.dim, modifier = Modifier.size(16.dp))
                Text(ui.caption, color = DeckColors.dim, fontSize = 12.sp, maxLines = 2)
            }
        }
    }
}
