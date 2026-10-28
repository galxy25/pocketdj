package com.levi.pocketdj.screens.games

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.InThePocketStats
import com.levi.pocketdj.data.games.inthepocket.InThePocketMode
import com.levi.pocketdj.data.games.inthepocket.InThePocketOutcome
import com.levi.pocketdj.data.games.inthepocket.InThePocketRound
import com.levi.pocketdj.data.games.inthepocket.InThePocketSong
import com.levi.pocketdj.data.games.inthepocket.InThePocketSongState

/** Pure strings/decisions of the In the Pocket screen (JVM-testable; mirrors InThePocketView statics). */
object InThePocketScreenLogic {
    fun modeNote(mode: InThePocketMode): String = when (mode) {
        InThePocketMode.CLOUD -> "Built from your listening pockets for this moment."
        InThePocketMode.HISTORY ->
            "No pocket results for this moment yet - built from what you've played through at this time of day."
        InThePocketMode.COLD ->
            "No pocket results yet - built from everything you've played through. Play more and the bets get sharper."
    }

    fun outcomeText(o: InThePocketOutcome): String = when (o) {
        InThePocketOutcome.Pocket -> "In the pocket!"
        is InThePocketOutcome.Broke -> "Broke at song ${o.at}"
        InThePocketOutcome.Abandoned -> "Round ended early"
    }

    fun progressLabel(round: InThePocketRound): String {
        val done = round.songs.count { it.state == InThePocketSongState.COMPLETED }
        return "$done of ${round.songs.size} songs played through"
    }

    /** The three stats-row cells: (value, label). The rate is a dash until a round is decided. */
    fun statCells(s: InThePocketStats): List<Pair<String, String>> = listOf(
        s.rounds.toString() to "rounds",
        (s.pocketRate?.let { "${Math.round(it * 100)}%" } ?: "–") to "in the pocket",
        s.bestStreak.toString() to "best streak",
    )

    /** The Games-home / header summary line. */
    fun inThePocketSummary(s: InThePocketStats): String = s.summary()

    /** At most three why-terms joined with " · "; null when there are none. */
    fun whyLine(song: InThePocketSong): String? =
        song.why.take(3).takeIf { it.isNotEmpty() }?.joinToString(" · ")

    fun chipsLine(chips: List<String>): String = chips.joinToString(" · ")

    fun buildButtonLabel(building: Boolean) = if (building) "Finding your pocket…" else "Build a round"

    const val BUILD_BLURB =
        "PocketDJ reads the time, the day and - if places & trips is on - where you are, then bets on songs " +
            "you'll play straight through. Skip one and the pocket breaks. Pausing is fine."
    const val PLAYING_NOTE = "Play straight through - skipping breaks the pocket. Pausing doesn't."
    const val PRIVACY_NOTE =
        "Rounds upload with your listening pockets as training data. Spoken feedback is transcribed on this " +
            "device - the audio never leaves it; only the text you write or dictate is sent."
    const val FEEDBACK_HINT = "How does this pocket feel? Is the algorithm getting you?"

    /** The live cap: over-long input (typed, pasted or dictated) is cut without splitting a surrogate pair. */
    fun clampDraft(new: String): String {
        if (new.length <= InThePocketRound.MAX_FEEDBACK_CHARS) return new
        var end = InThePocketRound.MAX_FEEDBACK_CHARS
        if (end > 0 && Character.isHighSurrogate(new[end - 1])) end -= 1
        return new.substring(0, end)
    }

    fun counterText(draft: String) = "${draft.length}/${InThePocketRound.MAX_FEEDBACK_CHARS}"

    /** Save reads "Saved" (disabled) when the capped draft + rating already equal the round's. */
    fun feedbackSaved(round: InThePocketRound, draft: String, rating: Int?): Boolean =
        InThePocketRound.capFeedback(draft) == round.feedback && rating == round.rating

    /** Tapping the star that is already the rating clears it. */
    fun toggledRating(current: Int?, tapped: Int): Int? = if (current == tapped) null else tapped

    /** Mic is shown only when the engine reports available; disabled once denied/unavailable. */
    fun micVisible(engineAvailable: Boolean) = engineAvailable
    fun micEnabled(denied: Boolean, unavailable: Boolean) = !(denied || unavailable)
}

@Composable
fun StatsRow(stats: InThePocketStats, modifier: Modifier = Modifier) {
    val cells = InThePocketScreenLogic.statCells(stats)
    val tags = listOf("itp-stat-rounds", "itp-stat-rate", "itp-stat-streak")
    Row(modifier.fillMaxWidth()) {
        cells.forEachIndexed { i, (value, label) ->
            Column(
                Modifier.weight(1f).testTag(tags[i]),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** One dot per song: hollow = to come, half = playing, filled = played through, X = skipped, dim = not played. */
@Composable
fun ProgressDots(round: InThePocketRound, modifier: Modifier = Modifier) {
    val label = InThePocketScreenLogic.progressLabel(round)
    val accent = MaterialTheme.colorScheme.primary
    val border = MaterialTheme.colorScheme.outline
    Row(
        modifier.semantics { contentDescription = label }.testTag("itp-dots"),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        round.songs.forEach { s ->
            Box(Modifier.size(22.dp).border(2.dp, border, CircleShape), contentAlignment = Alignment.Center) {
                when (s.state) {
                    InThePocketSongState.COMPLETED -> Box(Modifier.size(22.dp).background(accent, CircleShape))
                    InThePocketSongState.PLAYING -> Box(Modifier.size(11.dp).background(accent.copy(alpha = 0.7f), CircleShape))
                    InThePocketSongState.SKIPPED -> Icon(Icons.Filled.Close, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.error)
                    InThePocketSongState.NOT_PLAYED -> Box(Modifier.size(22.dp).background(border.copy(alpha = 0.4f), CircleShape))
                    InThePocketSongState.PENDING -> Unit
                }
            }
        }
    }
}

private fun stateIcon(s: InThePocketSongState): ImageVector = when (s) {
    InThePocketSongState.PENDING -> Icons.Filled.RadioButtonUnchecked
    InThePocketSongState.PLAYING -> Icons.Filled.GraphicEq
    InThePocketSongState.COMPLETED -> Icons.Filled.Check
    InThePocketSongState.SKIPPED -> Icons.Filled.SkipNext
    InThePocketSongState.NOT_PLAYED -> Icons.Filled.Remove
}

@Composable
fun SongRow(song: InThePocketSong, index: Int, isCurrent: Boolean, modifier: Modifier = Modifier) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier.fillMaxWidth().testTag("itp-song-$index"), verticalAlignment = Alignment.CenterVertically) {
        Text("${index + 1}", style = MaterialTheme.typography.labelMedium, color = dim, modifier = Modifier.width(20.dp))
        Column(Modifier.weight(1f)) {
            Text(song.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal)
            Text(song.artist, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall, color = dim)
            InThePocketScreenLogic.whyLine(song)?.let {
                Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.labelSmall, color = dim)
            }
        }
        val tint: Color = when (song.state) {
            InThePocketSongState.SKIPPED -> MaterialTheme.colorScheme.error
            InThePocketSongState.COMPLETED -> MaterialTheme.colorScheme.primary
            else -> dim
        }
        Icon(stateIcon(song.state), null, tint = tint)
    }
}
