package com.levi.pocketdj.screens.foryou

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.outlined.ThumbDown
import androidx.compose.material.icons.outlined.ThumbUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import com.levi.pocketdj.data.recs.RecFeedbackStore
import com.levi.pocketdj.data.recs.SimilarityFamilies

/**
 * Pure side of the 👍/👎 pair (iOS `RecFeedbackButtons`): which verdict a tap files and whether the
 * 👍 also runs the Add. Tapping a lit 👍 is an UNDO and must never add the song a second time.
 */
object RecFeedbackActions {
    /** The accessibility label, matching iOS wording. */
    fun label(verdict: RecFeedbackStore.Verdict, lit: Boolean): String = when (verdict) {
        RecFeedbackStore.Verdict.ACCEPTED -> if (lit) "Undo more like this" else "More like this"
        else -> if (lit) "Undo not for me" else "Not for me"
    }

    /** The Add rides a tap only when it LANDED as accepted. */
    fun shouldAdd(landed: RecFeedbackStore.Verdict?): Boolean = landed == RecFeedbackStore.Verdict.ACCEPTED

    /**
     * File the tap. Denormalizes artistKey/genre exactly as iOS so the taste half can learn without
     * the catalog. Returns what landed (null = cleared / nothing recorded).
     */
    fun record(
        feedback: RecFeedbackStore,
        catalog: MergedCatalog?,
        songId: String,
        scope: String,
        surface: RecFeedbackStore.Surface,
        verdict: RecFeedbackStore.Verdict,
    ): RecFeedbackStore.Verdict? {
        val song = catalog?.songsById?.get(songId)
        val genre = song?.albumId?.let { catalog.albumsById[it] }?.genre
        return feedback.toggle(
            songId = songId,
            to = verdict,
            scope = scope,
            surface = surface,
            artistKey = song?.let { PuzzleSimilarity.artistKey(it.artist) },
            genre = SimilarityFamilies.canonicalGenre(genre),
        )
    }
}

/** 👍 (more like this; ALSO the add) and 👎 (not for me) for one row in one scope. */
@Composable
fun RecFeedbackButtons(
    songId: String,
    scope: String,
    feedback: RecFeedbackStore?,
    catalog: MergedCatalog?,
    modifier: Modifier = Modifier,
    surface: RecFeedbackStore.Surface = RecFeedbackStore.Surface.TILE,
    onAccept: (() -> Unit)? = null,
) {
    if (feedback == null) return
    // Re-read on every store revision so a verdict from another surface lights this one.
    val rev by feedback.state.collectAsState()
    val verdict = remember(rev, songId, scope) { feedback.verdict(songId, scope) }
    Row(horizontalArrangement = Arrangement.spacedBy(0.dp), modifier = modifier) {
        for (v in listOf(RecFeedbackStore.Verdict.ACCEPTED, RecFeedbackStore.Verdict.REJECTED)) {
            val accept = v == RecFeedbackStore.Verdict.ACCEPTED
            val on = verdict == v
            val desc = RecFeedbackActions.label(v, on)
            IconButton(
                onClick = {
                    val landed = RecFeedbackActions.record(feedback, catalog, songId, scope, surface, v)
                    if (RecFeedbackActions.shouldAdd(landed)) onAccept?.invoke()
                },
                modifier = Modifier
                    .size(40.dp)
                    .testTag("rec-${if (accept) "accept" else "reject"}-$songId")
                    .semantics { contentDescription = desc },
            ) {
                Icon(
                    imageVector = when {
                        accept && on -> Icons.Filled.ThumbUp
                        accept -> Icons.Outlined.ThumbUp
                        on -> Icons.Filled.ThumbDown
                        else -> Icons.Outlined.ThumbDown
                    },
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = if (on && accept) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
