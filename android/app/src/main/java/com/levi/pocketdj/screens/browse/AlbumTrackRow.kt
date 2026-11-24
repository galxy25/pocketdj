package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.ui.FavoriteToggle

/**
 * Pure layout rules for the album track row (iOS `TrackRowInfo`, 1.0.5): phones (Material
 * `WindowWidthSizeClass.Compact`, width < 600 dp) get a two-line row; tablets/foldables keep columns.
 */
internal object AlbumTrackRowLayout {
    /** Material width-size-class boundary: Compact < 600 dp. */
    const val COMPACT_MAX_DP = 600

    /** Keywords shown on the compact line 2 (they give way first), vs the column layout's three. */
    const val COMPACT_KEYWORDS = 2
    const val WIDE_KEYWORDS = 3

    /** Title line cap: compact rows wrap to two lines, wide rows stay on one. */
    const val COMPACT_TITLE_LINES = 2
    const val WIDE_TITLE_LINES = 1

    fun isCompact(widthDp: Int): Boolean = widthDp < COMPACT_MAX_DP

    fun titleLines(compact: Boolean): Int = if (compact) COMPACT_TITLE_LINES else WIDE_TITLE_LINES

    /** Keywords for the row: at most [COMPACT_KEYWORDS] (compact) / [WIDE_KEYWORDS], blanks dropped. */
    fun keywords(song: IndexSong, compact: Boolean): List<String> =
        song.sentimentKeywords.orEmpty().filter { it.isNotBlank() }
            .take(if (compact) COMPACT_KEYWORDS else WIDE_KEYWORDS)

    /** "a · b" keywords caption, or null when there are none. */
    fun keywordText(song: IndexSong, compact: Boolean): String? =
        keywords(song, compact).takeIf { it.isNotEmpty() }?.joinToString(" · ")

    /** The fixed (never-shrinking) segments of line 2 in order: "128 BPM" then the time. The key chip sits between. */
    fun bpmText(song: IndexSong): String = Fmt.bpm(song.bpm) + " BPM"

    fun timeText(song: IndexSong): String = Fmt.duration(song.length)

    /**
     * Line 2 as plain text in iOS order (BPM · key · time · keywords) for accessibility / tests. The key part is
     * the chip's label ("Key · Camelot", Camelot or key alone) and is omitted when the song has neither.
     */
    fun line2(song: IndexSong): List<String> = buildList {
        add(bpmText(song))
        keyLabel(song)?.let { add(it) }
        add(timeText(song))
        keywordText(song, compact = true)?.let { add(it) }
    }

    fun keyLabel(song: IndexSong): String? = when {
        !song.camelot.isNullOrBlank() && !song.key.isNullOrBlank() -> "${song.key} · ${song.camelot}"
        !song.camelot.isNullOrBlank() -> song.camelot
        !song.key.isNullOrBlank() -> song.key
        else -> null
    }
}

/**
 * Track row (§8): # (trackNumber ?? position), title (+E), BPM, key chip, time, play control. Phones render two
 * lines; tablets keep the columns. Tap opens the song sheet, long-press the track menu. Metadata-only rows dim.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun AlbumTrackRow(
    position: Int,
    song: IndexSong,
    playable: Playability,
    isPreparing: Boolean,
    zebra: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onPlay: () -> Unit,
) {
    val compact = AlbumTrackRowLayout.isCompact(LocalConfiguration.current.screenWidthDp)
    val contentAlpha = if (playable == Playability.NONE) 0.45f else 1f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .fillMaxWidth()
            .let { base ->
                if (zebra) base.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)) else base
            }
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(
            (song.trackNumber ?: position).toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(26.dp),
        )
        if (compact) {
            Column(Modifier.weight(1f)) {
                TitleLine(song, contentAlpha, AlbumTrackRowLayout.titleLines(true))
                // BPM, key chip and time keep their natural size; the keywords (weight, last) give way first.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        AlbumTrackRowLayout.bpmText(song),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
                        maxLines = 1,
                        softWrap = false,
                    )
                    Spacer(Modifier.width(8.dp))
                    KeyChip(song.key, song.camelot)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        AlbumTrackRowLayout.timeText(song),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        softWrap = false,
                    )
                    AlbumTrackRowLayout.keywordText(song, compact = true)?.let {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            it,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                }
            }
        } else {
            Column(Modifier.weight(1f)) {
                TitleLine(song, contentAlpha, AlbumTrackRowLayout.titleLines(false))
                AlbumTrackRowLayout.keywordText(song, compact = false)?.let { MetaTag(it) }
            }
            Spacer(Modifier.width(8.dp))
            Text(
                Fmt.bpm(song.bpm),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.width(30.dp),
            )
            // Same fixed columns as the Browse song row (unplayable rows keep the time aligned).
            Box(Modifier.width(SongRowColumns.KEY), contentAlignment = Alignment.Center) {
                KeyChip(song.key?.takeIf { song.camelot == null }, song.camelot)
            }
            Spacer(Modifier.width(4.dp))
            Text(
                Fmt.duration(song.length),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.End,
                maxLines = 1,
                modifier = Modifier.width(SongRowColumns.TIME),
            )
        }
        if (compact) Spacer(Modifier.width(4.dp))
        FavoriteToggle(songId = song.id, appleMusicId = song.appleMusicId, iconSize = 18.dp)
        when {
            isPreparing -> Box(Modifier.size(SongRowColumns.PLAY), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            }

            playable != Playability.NONE -> IconButton(onClick = onPlay) {
                Icon(
                    Icons.Filled.PlayArrow,
                    contentDescription = "Play ${song.name}",
                    tint = if (playable == Playability.STREAM) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }

            else -> Spacer(Modifier.width(SongRowColumns.PLAY))
        }
    }
}

@Composable
private fun TitleLine(song: IndexSong, contentAlpha: Float, maxLines: Int) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            song.name,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (song.explicit == true) {
            Spacer(Modifier.width(6.dp))
            ExplicitBadge()
        }
    }
}
