package com.levi.pocketdj.screens.games

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.puzzle.PuzzleSampler
import com.levi.pocketdj.data.games.puzzle.PuzzleSettings

/** Pure, JVM-testable logic behind the Gem Collector screens (no Compose types). */
object PuzzleScreenLogic {
    const val MAX_TARGETS = 3
    val ROUND_LENGTHS: List<Pair<Int, String>> = listOf(60 to "1:00", 120 to "2:00", 180 to "3:00", 300 to "5:00")

    /** "N songs match", plus "N match - M similar" when the similarity ranker is shortlisting. */
    fun poolCountText(stats: PuzzleSampler.PoolStats?): String {
        if (stats == null) return "… songs match"
        val similar = stats.similar ?: return "${stats.matched} songs match"
        return "${stats.matched} match · $similar similar"
    }

    /** Start is disabled only when a COMPUTED count is zero (null = still counting = enabled). */
    fun startEnabled(stats: PuzzleSampler.PoolStats?): Boolean = stats?.matched != 0

    /** m:ss, never negative. */
    fun timerText(remainingSeconds: Int): String {
        val r = remainingSeconds.coerceAtLeast(0)
        return java.lang.String.format(java.util.Locale.ROOT, "%d:%02d", r / 60, r % 60)
    }

    fun timerUrgent(remainingSeconds: Int): Boolean = remainingSeconds < 10

    /** Blank/garbage -> null (the "Any" state); surrounding whitespace trimmed. */
    fun parseYear(text: String): Int? = text.trim().toIntOrNull()

    fun yearText(year: Int?): String = year?.toString() ?: ""

    /** Toggle a target: present -> removed, absent -> appended (order kept) while under the cap. */
    fun toggleTarget(targets: List<String>, id: String): List<String> = when {
        id in targets -> targets - id
        targets.size < MAX_TARGETS -> targets + id
        else -> targets
    }

    /** New Pocket... auto-targets the created pocket when there is room. */
    fun appendTargetIfRoom(targets: List<String>, id: String): List<String> =
        if (targets.size < MAX_TARGETS && id !in targets) targets + id else targets

    fun <T> toggleIn(set: Set<T>, v: T): Set<T> = if (v in set) set - v else set + v

    fun genresLabel(selected: Set<String>): String = if (selected.isEmpty()) "All genres" else selected.size.toString()

    fun setupFooter(hasTargets: Boolean): String =
        if (!hasTargets) {
            "No targets: every card opens the full Add-to picker, so you can file it into any collection. Cards come from your whole catalog."
        } else {
            "One-tap buttons during the round — plus “Other…” for anything else. Combine with the “Not in” collection filter to hunt songs LIKE these crates that aren’t in them yet."
        }

    /** "File into…" is the prominent sole control with no targets; "Other…" beside targets. */
    fun fileButtonLabel(hasTargets: Boolean): String = if (hasTargets) "Other…" else "File into…"

    /** The summary row trailing text. */
    fun filedRowLabel(collectionName: String): String = "→ $collectionName"

    val NEW_HIGH_SCORE = "New high score! 🏆"
}

/** A single-choice segmented row of (value, label). */
@Composable
fun <T> PuzzleSegmented(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    tag: String,
    modifier: Modifier = Modifier,
) {
    SingleChoiceSegmentedButtonRow(modifier = modifier.fillMaxWidth().testTag(tag)) {
        options.forEachIndexed { i, (v, label) ->
            SegmentedButton(
                selected = v == selected,
                onClick = { onSelect(v) },
                shape = SegmentedButtonDefaults.itemShape(i, options.size),
            ) { Text(label, maxLines = 1) }
        }
    }
}

/** A labelled picker row: label on top, segmented choices below. */
@Composable
fun <T> PuzzlePickerRow(
    label: String,
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    tag: String,
) {
    androidx.compose.foundation.layout.Column(Modifier.padding(vertical = 6.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        PuzzleSegmented(options, selected, onSelect, tag, Modifier.padding(top = 4.dp))
    }
}

/** A checklist row (name + trailing check). */
@Composable
fun PuzzleCheckRow(name: String, checked: Boolean, onClick: () -> Unit, tag: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(name, modifier = Modifier.weight(1f), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        if (checked) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = MaterialTheme.colorScheme.primary)
    }
}
